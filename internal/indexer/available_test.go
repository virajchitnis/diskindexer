package indexer_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/viraj/diskindexer/internal/indexer"
)

func TestCheckAvailable(t *testing.T) {
	root := t.TempDir()
	full := filepath.Join(root, "full")
	require.NoError(t, os.MkdirAll(filepath.Join(full, "Photos"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(full, "Photos", "a.jpg"), []byte("a"), 0o644))
	empty := filepath.Join(root, "empty")
	require.NoError(t, os.Mkdir(empty, 0o755))
	file := filepath.Join(root, "file")
	require.NoError(t, os.WriteFile(file, []byte("x"), 0o644))

	assert.NoError(t, indexer.CheckAvailable(full, ""))
	for path, want := range map[string]string{
		filepath.Join(root, "missing"): "isn’t there",
		empty:                          "is empty",
		file:                           "isn’t a folder",
	} {
		err := indexer.CheckAvailable(path, "")
		assert.ErrorIs(t, err, indexer.ErrUnavailable)
		assert.ErrorContains(t, err, want)
	}

	// A folder that was a mount point when the schedule was saved, but is
	// now just a folder on its parent's filesystem: the disk is unplugged.
	err := indexer.CheckAvailable(filepath.Join(full, "Photos"), full)
	assert.ErrorIs(t, err, indexer.ErrUnavailable)
	assert.ErrorContains(t, err, "nothing is mounted at")
	// The mount point of an unrelated path doesn't matter.
	assert.NoError(t, indexer.CheckAvailable(full, "/somewhere/else"))
}

func TestFindMountPoint(t *testing.T) {
	assert.Empty(t, indexer.FindMountPoint(filepath.Join(t.TempDir(), "missing")))
	// The root filesystem has no mount point to check.
	assert.Empty(t, indexer.FindMountPoint("/"))
	// Whatever a temp folder is on, its mount point contains it.
	dir := t.TempDir()
	resolved, err := filepath.EvalSymlinks(dir)
	require.NoError(t, err)
	if mp := indexer.FindMountPoint(dir); mp != "" {
		assert.True(t, resolved == mp || len(resolved) > len(mp) && resolved[:len(mp)+1] == mp+"/", "%s on %s", resolved, mp)
		assert.NoError(t, indexer.CheckAvailable(filepath.Dir(dir), mp))
	}
}
