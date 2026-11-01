package cmd

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// resetFlags restores every flag to its default before a run. Cobra commands
// are package globals, so values (and StringArray accumulation) would
// otherwise leak from one test run into the next.
func resetFlags(c *cobra.Command) {
	reset := func(f *pflag.Flag) {
		if sv, ok := f.Value.(pflag.SliceValue); ok {
			_ = sv.Replace(nil)
		} else {
			_ = f.Value.Set(f.DefValue)
		}
		f.Changed = false
	}
	c.Flags().VisitAll(reset)
	c.PersistentFlags().VisitAll(reset)
	for _, sub := range c.Commands() {
		resetFlags(sub)
	}
}

// run executes the CLI in-process with a scratch HOME (so the real config and
// index are never touched) and returns what it printed to stdout.
func run(t *testing.T, args ...string) (string, error) {
	t.Helper()
	resetFlags(rootCmd)

	r, w, err := os.Pipe()
	require.NoError(t, err)
	origStdout := os.Stdout
	os.Stdout = w
	out := make(chan string)
	go func() {
		b, _ := io.ReadAll(r)
		out <- string(b)
	}()

	rootCmd.SetArgs(args)
	rootCmd.SetErr(io.Discard)
	runErr := rootCmd.Execute()

	w.Close()
	os.Stdout = origStdout
	return <-out, runErr
}

// setupHome points HOME at a temp dir and returns a disk tree to index:
// Photos (2 files, one nested), Music (1 file), a root-level file, and a
// .snapshots folder to exclude.
func setupHome(t *testing.T) (disk string) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	disk = t.TempDir()
	for rel, content := range map[string]string{
		"Photos/beach.jpg":           "beach!",
		"Photos/2019/party.jpg":      "party party",
		"Music/song.flac":            "la",
		"readme.txt":                 "hello",
		"Photos/.snapshots/old.jpg":  "old",
		"Photos/cache.tmp/thumb.jpg": "t",
	} {
		p := filepath.Join(disk, rel)
		require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o755))
		require.NoError(t, os.WriteFile(p, []byte(content), 0o644))
	}
	return disk
}

func TestIndexAndListCommands(t *testing.T) {
	disk := setupHome(t)

	out, err := run(t, "index", disk, "--disk", "Disk One", "--description", "test disk", "--exclude", "*.tmp")
	require.NoError(t, err)
	assert.Contains(t, out, `Indexing "Disk One"`)
	assert.Contains(t, out, "Added:")

	// The default index lives under the scratch HOME.
	_, err = os.Stat(filepath.Join(os.Getenv("HOME"), ".config", "diskindexer", "global.diskindex"))
	require.NoError(t, err)

	out, err = run(t, "disks")
	require.NoError(t, err)
	assert.Contains(t, out, "Disk One")

	out, err = run(t, "collections")
	require.NoError(t, err)
	assert.Contains(t, out, "Photos")
	assert.Contains(t, out, "Music")

	out, err = run(t, "collections", "--disk", "Disk One")
	require.NoError(t, err)
	assert.Contains(t, out, "Music")

	_, err = run(t, "collections", "--disk", "Nope")
	require.Error(t, err)

	// Reindex is the same operation; nothing changed.
	out, err = run(t, "reindex", disk, "--disk", "Disk One", "--exclude", "*.tmp")
	require.NoError(t, err)
	assert.Contains(t, out, "Added: 0")
}

func TestIndexArgumentErrors(t *testing.T) {
	disk := setupHome(t)

	_, err := run(t, "index", "--disk", "D")
	require.ErrorContains(t, err, "mount path is required")

	_, err = run(t, "index", filepath.Join(disk, "missing"), "--disk", "D")
	require.ErrorContains(t, err, "mount path")

	_, err = run(t, "index", filepath.Join(disk, "readme.txt"), "--disk", "D")
	require.ErrorContains(t, err, "is a file")

	_, err = run(t, "index", disk, "--disk", "D", "--collection", "no-colon")
	require.ErrorContains(t, err, "invalid collection spec")

	_, err = run(t, "index", disk)
	require.Error(t, err, "--disk is required")
}

func TestIndexReportsUnreadablePaths(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read anything")
	}
	disk := setupHome(t)
	_, err := run(t, "index", disk, "--disk", "D")
	require.NoError(t, err)

	locked := filepath.Join(disk, "Photos", "2019")
	require.NoError(t, os.Chmod(locked, 0))
	t.Cleanup(func() { os.Chmod(locked, 0o755) })

	out, err := run(t, "index", disk, "--disk", "D")
	require.NoError(t, err)
	assert.Contains(t, out, "Couldn't read 1 path")
	assert.Contains(t, out, locked)
}

func TestCollectionCommands(t *testing.T) {
	disk := setupHome(t)
	_, err := run(t, "index", disk, "--disk", "A")
	require.NoError(t, err)
	other := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(other, "Docs"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(other, "Docs", "d.txt"), []byte("d"), 0o644))
	_, err = run(t, "index", other, "--disk", "B")
	require.NoError(t, err)

	out, err := run(t, "rename-collection", "Pictures", "--collection", "Photos")
	require.NoError(t, err)
	assert.Contains(t, out, `renamed to "Pictures"`)

	_, err = run(t, "rename-collection", "  ", "--collection", "Pictures")
	require.ErrorContains(t, err, "must not be empty")

	_, err = run(t, "rename-collection", "X", "--collection", "Nope")
	require.ErrorContains(t, err, "not found")

	_, err = run(t, "rename-collection", "X", "--collection", "Nope", "--disk", "A")
	require.ErrorContains(t, err, `not found on disk "A"`)

	out, err = run(t, "move-collection", "--collection", "Music", "--to", "B")
	require.NoError(t, err)
	assert.Contains(t, out, `moved from disk "A" to "B"`)

	out, err = run(t, "move-collection", "--collection", "Music", "--to", "B")
	require.NoError(t, err)
	assert.Contains(t, out, "already on disk")

	_, err = run(t, "move-collection", "--collection", "Music", "--to", "Nope")
	require.ErrorContains(t, err, `disk "Nope" not found`)

	// Same name on both disks: ambiguous without --disk.
	_, err = run(t, "rename-collection", "Docs", "--collection", "Pictures")
	require.NoError(t, err)
	_, err = run(t, "delete-collection", "--collection", "Docs")
	require.ErrorContains(t, err, "multiple disks")

	out, err = run(t, "delete-collection", "--collection", "Docs", "--disk", "B")
	require.NoError(t, err)
	assert.Contains(t, out, "removed from the index")

	_, err = run(t, "delete-collection", "--collection", "Nope")
	require.ErrorContains(t, err, "not found")
}

func TestDeleteDisk(t *testing.T) {
	disk := setupHome(t)
	_, err := run(t, "index", disk, "--disk", "A")
	require.NoError(t, err)

	out, err := run(t, "delete-disk", "--disk", "A")
	require.NoError(t, err)
	assert.Contains(t, out, "A")

	out, err = run(t, "disks")
	require.NoError(t, err)
	assert.Contains(t, out, "No disks")

	_, err = run(t, "delete-disk", "--disk", "A")
	require.Error(t, err)
}

func TestTextSearch(t *testing.T) {
	disk := setupHome(t)
	_, err := run(t, "index", disk, "--disk", "Disk One")
	require.NoError(t, err)

	out, err := run(t, "search", "beach", "--no-tui")
	require.NoError(t, err)
	assert.Contains(t, out, "Disk One/Photos/beach.jpg")
	assert.Contains(t, out, "1 result(s)")

	out, err = run(t, "search", "--no-tui", "--ext", ".JPG", "--files-only", "--disk", "Disk One")
	require.NoError(t, err)
	assert.Contains(t, out, "beach.jpg")
	assert.Contains(t, out, "party.jpg")
	assert.NotContains(t, out, "song.flac")

	out, err = run(t, "search", "--no-tui", "--dirs-only")
	require.NoError(t, err)
	assert.Contains(t, out, "Photos/")
	assert.NotContains(t, out, "beach.jpg")

	out, err = run(t, "search", "--no-tui", "--min-size", "8B", "--max-size", "1KB", "--files-only")
	require.NoError(t, err)
	assert.Contains(t, out, "party.jpg")
	assert.NotContains(t, out, "song.flac")

	today := time.Now().Format("2006-01-02")
	out, err = run(t, "search", "--no-tui", "--after", "2000-01-01", "--before", today, "--limit", "1")
	require.NoError(t, err)
	assert.Contains(t, out, "limit reached")

	out, err = run(t, "search", "nothing-matches-this", "--no-tui")
	require.NoError(t, err)
	assert.Contains(t, out, "No results")

	for _, bad := range [][]string{
		{"--dirs-only", "--files-only"},
		{"--min-size", "huge"},
		{"--max-size", "huge"},
		{"--after", "yesterday"},
		{"--before", "tomorrow"},
		{"--min-size", "2MB", "--max-size", "1MB"},
		{"--after", "2020-02-01", "--before", "2020-01-01"},
	} {
		_, err := run(t, append([]string{"search", "--no-tui"}, bad...)...)
		assert.Error(t, err, "%v", bad)
	}
}

func TestSearchHelpers(t *testing.T) {
	disk := setupHome(t)
	_, err := run(t, "index", disk, "--disk", "Disk One")
	require.NoError(t, err)

	dbs := openDBs([]string{filepath.Join(os.Getenv("HOME"), ".config", "diskindexer", "global.diskindex"), filepath.Join(t.TempDir(), "missing", "x.diskindex")})
	defer closeDBs(dbs)
	require.Len(t, dbs, 2)

	assert.Equal(t, []string{"Disk One"}, collectDiskNames(dbs))
	colls := collectCollectionsByDisk(dbs)
	assert.Equal(t, []string{"Music", "Photos"}, colls["Disk One"])
}

func TestServeCommand(t *testing.T) {
	setupHome(t)

	// --stdin-watch makes serve exit when stdin closes, which stops the test
	// server without signals.
	stdinR, stdinW, err := os.Pipe()
	require.NoError(t, err)
	origStdin := os.Stdin
	os.Stdin = stdinR
	defer func() { os.Stdin = origStdin }()

	outR, outW, err := os.Pipe()
	require.NoError(t, err)
	origStdout := os.Stdout
	os.Stdout = outW
	defer func() { os.Stdout = origStdout }()

	resetFlags(rootCmd)
	rootCmd.SetArgs([]string{"serve", "--listen", "127.0.0.1:0", "--stdin-watch", "--token", "tok"})
	rootCmd.SetErr(io.Discard)
	done := make(chan error, 1)
	go func() { done <- rootCmd.Execute() }()

	line, err := bufio.NewReader(outR).ReadString('\n')
	require.NoError(t, err)
	var announced map[string]string
	require.NoError(t, json.Unmarshal([]byte(line), &announced))
	addr := announced["listen"]
	require.NotEmpty(t, addr)

	req, _ := http.NewRequest("GET", "http://"+addr+"/v1/info", nil)
	req.Header.Set("Authorization", "Bearer tok")
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	resp.Body.Close()
	assert.Equal(t, http.StatusOK, resp.StatusCode)

	stdinW.Close()
	select {
	case err := <-done:
		require.NoError(t, err)
	case <-time.After(10 * time.Second):
		t.Fatal("serve did not exit when stdin closed")
	}
	outW.Close()
}

func TestListen(t *testing.T) {
	_, err := listen("0.0.0.0:0", "")
	require.ErrorContains(t, err, "reachable from the network")

	l, err := listen("0.0.0.0:0", "tok")
	require.NoError(t, err)
	l.Close()

	_, err = listen("not an address", "")
	require.Error(t, err)

	l, err = listen("localhost:0", "")
	require.NoError(t, err)
	assert.NotContains(t, listenerAddr(l), "unix:")
	l.Close()

	// Unix sockets: private permissions, stale sockets replaced, live ones kept.
	// Kept short: macOS limits socket paths to 104 bytes.
	dir, err := os.MkdirTemp("/tmp", "di")
	require.NoError(t, err)
	defer os.RemoveAll(dir)
	sock := filepath.Join(dir, "s.sock")

	l, err = listen("unix:"+sock, "")
	require.NoError(t, err)
	info, err := os.Stat(sock)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
	assert.Equal(t, "unix:"+sock, listenerAddr(l))

	_, err = listen("unix:"+sock, "")
	require.ErrorContains(t, err, "already listening")
	l.Close()

	// A socket file left behind with nothing listening is cleaned up.
	stale, err := net.Listen("unix", sock)
	require.NoError(t, err)
	stale.(*net.UnixListener).SetUnlinkOnClose(false)
	stale.Close()
	l, err = listen("unix:"+sock, "")
	require.NoError(t, err)
	l.Close()
}

func TestPathHelpers(t *testing.T) {
	t.Setenv("HOME", "/home/someone")
	assert.Equal(t, "/home/someone/x/y", expandHome("~/x/y"))
	assert.Equal(t, "/abs", expandHome("/abs"))
	assert.True(t, strings.HasPrefix(defaultSocketPath(), "/home/someone/.config/diskindexer/"))
}
