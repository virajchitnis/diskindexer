package indexer_test

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/viraj/diskindexer/internal/db"
	"github.com/viraj/diskindexer/internal/indexer"
)

func openTestDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "test.diskindex"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return d
}

// makeDisk creates a fake disk directory tree and returns its path.
func makeDisk(t *testing.T, structure map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for relPath, content := range structure {
		absPath := filepath.Join(root, relPath)
		if err := os.MkdirAll(filepath.Dir(absPath), 0755); err != nil {
			t.Fatal(err)
		}
		if content == "" {
			// directory
			if err := os.MkdirAll(absPath, 0755); err != nil {
				t.Fatal(err)
			}
		} else {
			if err := os.WriteFile(absPath, []byte(content), 0644); err != nil {
				t.Fatal(err)
			}
		}
	}
	return root
}

func TestRun_FullIndex(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Vacation/":         "",
		"Vacation/beach.jpg": "fake jpeg content",
		"Vacation/hotel.jpg": "more fake content",
		"Work/":             "",
		"Work/report.pdf":   "report content",
	})

	stats, err := indexer.Run(d, indexer.Options{
		DiskLabel: "Test Disk",
		MountPath: root,
	})
	require.NoError(t, err)
	// 5 entries: Vacation/ dir, beach.jpg, hotel.jpg, Work/ dir, report.pdf
	assert.Equal(t, 5, stats.Added)
	assert.Equal(t, 0, stats.Updated)
	assert.Equal(t, 0, stats.Deleted)
}

func TestRun_AutoDetectsCollections(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Alpha/":      "",
		"Alpha/a.jpg": "x",
		"Beta/":       "",
		"Beta/b.jpg":  "y",
	})

	_, err := indexer.Run(d, indexer.Options{
		DiskLabel: "Test Disk",
		MountPath: root,
	})
	require.NoError(t, err)

	disk, err := d.GetDiskByLabel("Test Disk")
	require.NoError(t, err)

	colls, err := d.ListCollections(disk.ID)
	require.NoError(t, err)
	require.Len(t, colls, 2)

	labels := []string{colls[0].Label, colls[1].Label}
	assert.Contains(t, labels, "Alpha")
	assert.Contains(t, labels, "Beta")
}

func TestRun_IncrementalSkipsUnchanged(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Photos/":          "",
		"Photos/img001.jpg": "original",
	})

	_, err := indexer.Run(d, indexer.Options{DiskLabel: "Test Disk", MountPath: root})
	require.NoError(t, err)

	stats, err := indexer.Run(d, indexer.Options{DiskLabel: "Test Disk", MountPath: root})
	require.NoError(t, err)
	assert.Equal(t, 0, stats.Added)
	assert.Equal(t, 0, stats.Updated)
	assert.Greater(t, stats.Skipped, 0)
}

func TestRun_IncrementalDetectsNewFile(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Photos/":          "",
		"Photos/img001.jpg": "original",
	})

	_, err := indexer.Run(d, indexer.Options{DiskLabel: "Test Disk", MountPath: root})
	require.NoError(t, err)

	// Add a new file.
	require.NoError(t, os.WriteFile(filepath.Join(root, "Photos", "img002.jpg"), []byte("new"), 0644))

	stats, err := indexer.Run(d, indexer.Options{DiskLabel: "Test Disk", MountPath: root})
	require.NoError(t, err)
	assert.Equal(t, 1, stats.Added)
}

func TestRun_IncrementalDetectsModifiedFile(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Photos/":          "",
		"Photos/img001.jpg": "original content",
	})

	_, err := indexer.Run(d, indexer.Options{DiskLabel: "Test Disk", MountPath: root})
	require.NoError(t, err)

	// Modify file: change size and bump mtime.
	filePath := filepath.Join(root, "Photos", "img001.jpg")
	require.NoError(t, os.WriteFile(filePath, []byte("modified content is longer"), 0644))
	future := time.Now().Add(2 * time.Second)
	require.NoError(t, os.Chtimes(filePath, future, future))

	stats, err := indexer.Run(d, indexer.Options{DiskLabel: "Test Disk", MountPath: root})
	require.NoError(t, err)
	assert.Equal(t, 1, stats.Updated)
}

func TestRun_IncrementalDetectsDeletedFile(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Photos/":          "",
		"Photos/img001.jpg": "keep",
		"Photos/img002.jpg": "delete me",
	})

	_, err := indexer.Run(d, indexer.Options{DiskLabel: "Test Disk", MountPath: root})
	require.NoError(t, err)

	require.NoError(t, os.Remove(filepath.Join(root, "Photos", "img002.jpg")))

	stats, err := indexer.Run(d, indexer.Options{DiskLabel: "Test Disk", MountPath: root})
	require.NoError(t, err)
	assert.Equal(t, 1, stats.Deleted)
}

func TestRun_ForceWipesAndRebuild(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Photos/":    "",
		"Photos/a.jpg": "a",
		"Photos/b.jpg": "b",
	})

	_, err := indexer.Run(d, indexer.Options{DiskLabel: "Test Disk", MountPath: root})
	require.NoError(t, err)

	stats, err := indexer.Run(d, indexer.Options{
		DiskLabel: "Test Disk",
		MountPath: root,
		Force:     true,
	})
	require.NoError(t, err)
	assert.Greater(t, stats.Added, 0)
	assert.Equal(t, 0, stats.Skipped)
}

func TestRun_ManualCollection(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"nested/deep/Photos/":          "",
		"nested/deep/Photos/img001.jpg": "x",
	})

	photoPath := filepath.Join(root, "nested", "deep", "Photos")
	_, err := indexer.Run(d, indexer.Options{
		DiskLabel: "Test Disk",
		MountPath: root,
		Collections: []indexer.CollectionSpec{
			{Label: "My Photos", RootPath: photoPath},
		},
	})
	require.NoError(t, err)

	disk, err := d.GetDiskByLabel("Test Disk")
	require.NoError(t, err)

	colls, err := d.ListCollections(disk.ID)
	require.NoError(t, err)
	require.Len(t, colls, 1)
	assert.Equal(t, "My Photos", colls[0].Label)
}

func TestRun_ManualCollectionPathNotExist(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{})

	_, err := indexer.Run(d, indexer.Options{
		DiskLabel: "Test Disk",
		MountPath: root,
		Collections: []indexer.CollectionSpec{
			{Label: "Ghost", RootPath: "/nonexistent/path/that/does/not/exist"},
		},
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "Ghost")
}

func TestRun_ManualCollectionPathIsFile(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"myfile.txt": "hello",
	})

	filePath := filepath.Join(root, "myfile.txt")
	_, err := indexer.Run(d, indexer.Options{
		DiskLabel: "Test Disk",
		MountPath: root,
		Collections: []indexer.CollectionSpec{
			{Label: "NotADir", RootPath: filePath},
		},
	})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "NotADir")
	assert.Contains(t, err.Error(), "not a directory")
}

func TestRun_ExcludeByName(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Photos/":                          "",
		"Photos/img001.jpg":                "x",
		"Photos/.snapshots/":               "",
		"Photos/.snapshots/snap001.jpg":    "snap",
		"Photos/sub/.snapshots/":           "",
		"Photos/sub/.snapshots/deep.jpg":   "deep",
	})

	_, err := indexer.Run(d, indexer.Options{
		DiskLabel: "Test Disk",
		MountPath: root,
		Excludes:  []string{".snapshots"},
	})
	require.NoError(t, err)

	fileMap, err := d.GetFileMapForDisk(1)
	require.NoError(t, err)

	// The regular file should be indexed.
	assert.Contains(t, fileMap, "Test Disk/Photos/img001.jpg")
	// Nothing inside .snapshots at any depth should be indexed.
	for p := range fileMap {
		assert.NotContains(t, p, ".snapshots", "excluded path leaked into index: %s", p)
	}
}

func TestRun_ExcludeGlobPattern(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Photos/":                "",
		"Photos/img001.jpg":      "x",
		"Photos/tmp_cache/":      "",
		"Photos/tmp_cache/a.jpg": "y",
		"Photos/tmp_data/":       "",
		"Photos/tmp_data/b.jpg":  "z",
	})

	_, err := indexer.Run(d, indexer.Options{
		DiskLabel: "Test Disk",
		MountPath: root,
		Excludes:  []string{"tmp_*"},
	})
	require.NoError(t, err)

	fileMap, err := d.GetFileMapForDisk(1)
	require.NoError(t, err)

	assert.Contains(t, fileMap, "Test Disk/Photos/img001.jpg")
	for p := range fileMap {
		assert.NotContains(t, p, "tmp_", "glob-excluded path leaked into index: %s", p)
	}
}

func TestRun_ExcludeTopLevelCollection(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Photos/":               "",
		"Photos/img001.jpg":     "x",
		".snapshots/":           "",
		".snapshots/backup.jpg": "snap",
	})

	_, err := indexer.Run(d, indexer.Options{
		DiskLabel: "Test Disk",
		MountPath: root,
		Excludes:  []string{".snapshots"},
	})
	require.NoError(t, err)

	fileMap, err := d.GetFileMapForDisk(1)
	require.NoError(t, err)

	assert.Contains(t, fileMap, "Test Disk/Photos/img001.jpg")
	for p := range fileMap {
		assert.NotContains(t, p, ".snapshots", "excluded top-level collection leaked: %s", p)
	}
}

func TestRun_ProgressUpdateCarriesTotal(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Photos/img001.jpg": "x",
		"Photos/img002.jpg": "y",
	})

	// First run seeds the file map.
	_, err := indexer.Run(d, indexer.Options{DiskLabel: "Test Disk", MountPath: root})
	require.NoError(t, err)

	// Second run: fileMap will be populated, so Total > 0 in indexing updates.
	var updates []indexer.ProgressUpdate
	_, err = indexer.Run(d, indexer.Options{
		DiskLabel:  "Test Disk",
		MountPath:  root,
		ProgressFn: func(u indexer.ProgressUpdate) { updates = append(updates, u) },
	})
	require.NoError(t, err)

	// At least one indexing-phase update should carry a non-zero Total.
	var foundIndexing bool
	for _, u := range updates {
		if u.Phase == "indexing" && u.Total > 0 {
			foundIndexing = true
			break
		}
	}
	assert.True(t, foundIndexing, "expected an indexing update with Total > 0")

	// Sizes phase should carry DirsTotal > 0 (Photos/ is one directory).
	var foundSizes bool
	for _, u := range updates {
		if u.Phase == "sizes" && u.DirsTotal > 0 {
			foundSizes = true
			break
		}
	}
	assert.True(t, foundSizes, "expected a sizes update with DirsTotal > 0")
}

func TestParseCollectionSpec(t *testing.T) {
	tests := []struct {
		input   string
		label   string
		path    string
		wantErr bool
	}{
		{"My Photos:/mnt/disk/photos", "My Photos", "/mnt/disk/photos", false},
		{"Label:/path/with spaces", "Label", "/path/with spaces", false},
		{"/no-label", "", "", true},
		{"", "", "", true},
	}
	for _, tc := range tests {
		spec, err := indexer.ParseCollectionSpec(tc.input)
		if tc.wantErr {
			assert.Error(t, err, "input: %q", tc.input)
		} else {
			require.NoError(t, err, "input: %q", tc.input)
			assert.Equal(t, tc.label, spec.Label)
			assert.Equal(t, tc.path, spec.RootPath)
		}
	}
}

func TestRunContext_Cancelled(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Photos/a.jpg": "a",
		"Photos/b.jpg": "b",
	})

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := indexer.RunContext(ctx, d, indexer.Options{DiskLabel: "Test Disk", MountPath: root})
	require.ErrorIs(t, err, context.Canceled)

	files, err := d.Search(db.SearchParams{Query: "jpg"})
	require.NoError(t, err)
	assert.Empty(t, files)
}

// Adding a copy of a collection that lives elsewhere to a disk that isn't
// plugged in: no mount path, so the disk's root files and other collections
// must survive.
func TestRun_AddCollectionWithoutMountPath(t *testing.T) {
	d := openTestDB(t)
	disk := makeDisk(t, map[string]string{
		"readme.txt":      "root file",
		"Photos/a.jpg":    "a",
		"Videos/clip.mp4": "clip",
	})
	_, err := indexer.Run(d, indexer.Options{DiskLabel: "Test Disk", MountPath: disk})
	require.NoError(t, err)

	copyRoot := makeDisk(t, map[string]string{
		"Music/song.flac": "song",
		"loose.txt":       "not part of the disk",
	})
	stats, err := indexer.Run(d, indexer.Options{
		DiskLabel:   "Test Disk",
		Collections: []indexer.CollectionSpec{{Label: "Music", RootPath: filepath.Join(copyRoot, "Music")}},
	})
	require.NoError(t, err)
	assert.Equal(t, 0, stats.Deleted)

	fileMap, err := d.GetFileMapForDisk(1)
	require.NoError(t, err)
	for _, p := range []string{
		"Test Disk/readme.txt",
		"Test Disk/Photos/a.jpg",
		"Test Disk/Videos/clip.mp4",
		"Test Disk/Music/song.flac",
	} {
		assert.Contains(t, fileMap, p)
	}
	assert.NotContains(t, fileMap, "Test Disk/loose.txt")

	colls, err := d.ListCollections(1)
	require.NoError(t, err)
	assert.Len(t, colls, 3)
}

func TestRun_NoMountPathNoCollections(t *testing.T) {
	d := openTestDB(t)
	_, err := indexer.Run(d, indexer.Options{DiskLabel: "Test Disk"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "mount path is required")
	disks, err := d.ListDisks()
	require.NoError(t, err)
	assert.Empty(t, disks, "a rejected run must not create the disk")
}

// Move a collection to another disk in the index, then reindex that disk
// from its real mount: the moved collection is updated in place, not
// duplicated, and nothing is re-added.
func TestRun_ReindexAfterMoveDoesNotDuplicate(t *testing.T) {
	d := openTestDB(t)
	diskA := makeDisk(t, map[string]string{"Photos/a.jpg": "a", "Photos/b.jpg": "b"})
	diskB := makeDisk(t, map[string]string{"Music/song.flac": "s"})
	_, err := indexer.Run(d, indexer.Options{DiskLabel: "A", MountPath: diskA})
	require.NoError(t, err)
	_, err = indexer.Run(d, indexer.Options{DiskLabel: "B", MountPath: diskB})
	require.NoError(t, err)

	// The folder physically moves from A to B...
	require.NoError(t, os.Rename(filepath.Join(diskA, "Photos"), filepath.Join(diskB, "Photos")))
	// ...and is moved in the index without reading it again.
	photos, err := d.GetCollectionsByLabel("Photos", "A")
	require.NoError(t, err)
	b, err := d.GetDiskByLabel("B")
	require.NoError(t, err)
	_, err = d.MoveCollection(photos[0].ID, b.ID)
	require.NoError(t, err)

	stats, err := indexer.Run(d, indexer.Options{DiskLabel: "B", MountPath: diskB})
	require.NoError(t, err)
	assert.Zero(t, stats.Added)
	assert.Zero(t, stats.Deleted)

	colls, err := d.ListCollections(b.ID)
	require.NoError(t, err)
	assert.Len(t, colls, 2)
}

// Two manual collections with the same name would share "<disk>/<label>/..."
// paths and overwrite each other in the index, so the run is refused before
// anything is written.
func TestRun_RejectsDuplicateCollections(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{"x/same.txt": "1", "y/same.txt": "22"})
	x, y := filepath.Join(root, "x"), filepath.Join(root, "y")

	_, err := indexer.Run(d, indexer.Options{DiskLabel: "D", Collections: []indexer.CollectionSpec{
		{Label: "A", RootPath: x}, {Label: "A", RootPath: y},
	}})
	require.Error(t, err)
	assert.Contains(t, err.Error(), `collection "A" is listed twice`)

	_, err = indexer.Run(d, indexer.Options{DiskLabel: "D", Collections: []indexer.CollectionSpec{
		{Label: "A", RootPath: x}, {Label: "B", RootPath: x + "/"},
	}})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "is listed twice")

	disks, err := d.ListDisks()
	require.NoError(t, err)
	assert.Empty(t, disks, "nothing is written for a rejected run")
}

// A folder that can't be read is reported, and what was indexed under it
// before is kept: an I/O or permission error doesn't mean the files are gone.
func TestRun_UnreadableFolderIsReportedAndKept(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read anything")
	}
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{
		"Photos/ok.jpg":          "ok",
		"Photos/locked/a.jpg":    "a",
		"Photos/locked/sub/b.jp": "b",
	})
	_, err := indexer.Run(d, indexer.Options{DiskLabel: "D", MountPath: root})
	require.NoError(t, err)

	locked := filepath.Join(root, "Photos", "locked")
	require.NoError(t, os.Chmod(locked, 0))
	t.Cleanup(func() { os.Chmod(locked, 0o755) })

	stats, err := indexer.Run(d, indexer.Options{DiskLabel: "D", MountPath: root})
	require.NoError(t, err)
	assert.Equal(t, 1, stats.ErrorCount)
	require.Len(t, stats.Errors, 1)
	assert.Equal(t, locked, stats.Errors[0].Path)
	assert.Contains(t, stats.Errors[0].Err, "permission denied")
	assert.Zero(t, stats.Deleted, "nothing under the unreadable folder is treated as deleted")

	files, err := d.GetFileMapForDisk(1)
	require.NoError(t, err)
	assert.Contains(t, files, "D/Photos/locked/a.jpg")
	assert.Contains(t, files, "D/Photos/locked/sub/b.jp")

	// Once readable again, a real deletion inside it is picked up.
	require.NoError(t, os.Chmod(locked, 0o755))
	require.NoError(t, os.Remove(filepath.Join(locked, "a.jpg")))
	stats, err = indexer.Run(d, indexer.Options{DiskLabel: "D", MountPath: root})
	require.NoError(t, err)
	assert.Zero(t, stats.ErrorCount)
	assert.Equal(t, 1, stats.Deleted)
}

func TestRun_ReportsEveryPhase(t *testing.T) {
	d := openTestDB(t)
	root := makeDisk(t, map[string]string{"Photos/a.jpg": "a", "root.txt": "r"})
	var phases []string
	_, err := indexer.Run(d, indexer.Options{
		DiskLabel: "D", MountPath: root, Force: true,
		ProgressFn: func(u indexer.ProgressUpdate) {
			if len(phases) == 0 || phases[len(phases)-1] != u.Phase {
				phases = append(phases, u.Phase)
			}
		},
	})
	require.NoError(t, err)
	assert.Equal(t, []string{"clearing", "loading", "indexing", "root", "deleting", "sizes"}, phases)
}

// An incremental run over unchanged files used to report nothing until the
// end of each collection; progress now arrives as files are walked.
func TestRun_ProgressDuringUnchangedFiles(t *testing.T) {
	defer indexer.SetProgressInterval(0)()
	d := openTestDB(t)
	files := map[string]string{}
	for i := 0; i < 50; i++ {
		files[filepath.Join("Photos", fmt.Sprintf("f%02d.jpg", i))] = "x"
	}
	root := makeDisk(t, files)
	_, err := indexer.Run(d, indexer.Options{DiskLabel: "D", MountPath: root})
	require.NoError(t, err)

	var skippedSeen []int
	stats, err := indexer.Run(d, indexer.Options{
		DiskLabel: "D", MountPath: root,
		ProgressFn: func(u indexer.ProgressUpdate) {
			if u.Phase == "indexing" {
				skippedSeen = append(skippedSeen, u.Skipped)
			}
		},
	})
	require.NoError(t, err)
	assert.Zero(t, stats.Added+stats.Updated)
	assert.Greater(t, len(skippedSeen), 40, "a report per unchanged file when unthrottled")
	assert.Equal(t, stats.Skipped, skippedSeen[len(skippedSeen)-1])
}
