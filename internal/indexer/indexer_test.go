package indexer_test

import (
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
