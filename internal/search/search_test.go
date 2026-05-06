package search_test

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/viraj/diskindexer/internal/db"
	"github.com/viraj/diskindexer/internal/search"
)

func openTestDB(t *testing.T, name string) *db.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), name+".diskindex"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return d
}

func seedDB(t *testing.T, d *db.DB, diskLabel string, files []string) {
	t.Helper()
	disk, err := d.UpsertDisk(diskLabel, "")
	require.NoError(t, err)
	for _, path := range files {
		name := filepath.Base(path)
		ext := filepath.Ext(name)
		if len(ext) > 0 {
			ext = ext[1:]
		}
		f := &db.File{
			DiskID:     disk.ID,
			Name:       name,
			Path:       path,
			Size:       1024,
			ModifiedAt: time.Now().UTC().Truncate(time.Second),
			Extension:  ext,
			IsDir:      false,
		}
		require.NoError(t, d.UpsertFile(f))
	}
}

func TestAcross_SingleDB(t *testing.T) {
	d := openTestDB(t, "single")
	seedDB(t, d, "Disk A", []string{
		"vacation/beach.jpg",
		"vacation/sunset.jpg",
		"work/report.pdf",
	})

	results, err := search.Across([]*db.DB{d}, db.SearchParams{Query: "beach"})
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.Equal(t, "beach.jpg", results[0].File.Name)
}

func TestAcross_MultipleDBs_MergesResults(t *testing.T) {
	d1 := openTestDB(t, "db1")
	d2 := openTestDB(t, "db2")

	seedDB(t, d1, "Disk One", []string{"photos/alpha.jpg"})
	seedDB(t, d2, "Disk Two", []string{"photos/beta.jpg"})

	results, err := search.Across([]*db.DB{d1, d2}, db.SearchParams{Extension: "jpg", Limit: 50})
	require.NoError(t, err)
	require.Len(t, results, 2)

	names := []string{results[0].File.Name, results[1].File.Name}
	assert.Contains(t, names, "alpha.jpg")
	assert.Contains(t, names, "beta.jpg")
}

func TestAcross_MultipleDBs_ResultsAreSortedByName(t *testing.T) {
	d1 := openTestDB(t, "db1")
	d2 := openTestDB(t, "db2")

	seedDB(t, d1, "Disk One", []string{"photos/zebra.jpg"})
	seedDB(t, d2, "Disk Two", []string{"photos/apple.jpg"})

	results, err := search.Across([]*db.DB{d1, d2}, db.SearchParams{Extension: "jpg", Limit: 50})
	require.NoError(t, err)
	require.Len(t, results, 2)
	assert.Equal(t, "apple.jpg", results[0].File.Name)
	assert.Equal(t, "zebra.jpg", results[1].File.Name)
}

func TestAcross_ResultIncludesDBPath(t *testing.T) {
	d := openTestDB(t, "mydb")
	seedDB(t, d, "Disk A", []string{"file.jpg"})

	results, err := search.Across([]*db.DB{d}, db.SearchParams{Extension: "jpg", Limit: 50})
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.Equal(t, d.Path, results[0].DBPath)
}

func TestAcross_EmptyDBs_ReturnsEmpty(t *testing.T) {
	d := openTestDB(t, "empty")
	results, err := search.Across([]*db.DB{d}, db.SearchParams{Query: "anything"})
	require.NoError(t, err)
	assert.Empty(t, results)
}
