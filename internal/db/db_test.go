package db_test

import (
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/viraj/diskindexer/internal/db"
)

func openTestDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "test.diskindex"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	return d
}

// ── Disk tests ────────────────────────────────────────────────────────────────

func TestUpsertAndGetDisk(t *testing.T) {
	d := openTestDB(t)

	disk, err := d.UpsertDisk("My Disk", "External SSD")
	require.NoError(t, err)
	require.NotNil(t, disk)
	assert.Equal(t, "My Disk", disk.Label)
	assert.Equal(t, "External SSD", disk.Description)
	assert.NotZero(t, disk.ID)
	assert.Nil(t, disk.LastIndexedAt)
}

func TestUpsertDisk_Idempotent(t *testing.T) {
	d := openTestDB(t)

	first, err := d.UpsertDisk("My Disk", "desc")
	require.NoError(t, err)

	second, err := d.UpsertDisk("My Disk", "different desc")
	require.NoError(t, err)

	assert.Equal(t, first.ID, second.ID)
}

func TestListDisks(t *testing.T) {
	d := openTestDB(t)

	_, err := d.UpsertDisk("Alpha", "")
	require.NoError(t, err)
	_, err = d.UpsertDisk("Beta", "")
	require.NoError(t, err)

	disks, err := d.ListDisks()
	require.NoError(t, err)
	require.Len(t, disks, 2)
	assert.Equal(t, "Alpha", disks[0].Label)
	assert.Equal(t, "Beta", disks[1].Label)
}

func TestUpdateDiskIndexedAt(t *testing.T) {
	d := openTestDB(t)

	disk, err := d.UpsertDisk("My Disk", "")
	require.NoError(t, err)

	now := time.Now().UTC().Truncate(time.Second)
	require.NoError(t, d.UpdateDiskIndexedAt(disk.ID, now))

	disk2, err := d.GetDiskByLabel("My Disk")
	require.NoError(t, err)
	require.NotNil(t, disk2.LastIndexedAt)
	assert.Equal(t, now, disk2.LastIndexedAt.UTC())
}

// ── Collection tests ──────────────────────────────────────────────────────────

func TestUpsertAndListCollections(t *testing.T) {
	d := openTestDB(t)

	disk, err := d.UpsertDisk("My Disk", "")
	require.NoError(t, err)

	c1, err := d.UpsertCollection(disk.ID, "Vacation 2019", "/mnt/disk/vacation-2019")
	require.NoError(t, err)
	require.NotNil(t, c1)
	assert.Equal(t, "Vacation 2019", c1.Label)

	c2, err := d.UpsertCollection(disk.ID, "Work Docs", "/mnt/disk/work")
	require.NoError(t, err)
	require.NotNil(t, c2)

	colls, err := d.ListCollections(disk.ID)
	require.NoError(t, err)
	require.Len(t, colls, 2)
}

func TestUpsertCollection_UpdatesLabel(t *testing.T) {
	d := openTestDB(t)

	disk, err := d.UpsertDisk("My Disk", "")
	require.NoError(t, err)

	_, err = d.UpsertCollection(disk.ID, "Old Label", "/mnt/disk/folder")
	require.NoError(t, err)

	// Re-upsert same path with new label — should update.
	updated, err := d.UpsertCollection(disk.ID, "New Label", "/mnt/disk/folder")
	require.NoError(t, err)
	assert.Equal(t, "New Label", updated.Label)
}

func TestRenameCollection(t *testing.T) {
	d := openTestDB(t)

	disk, err := d.UpsertDisk("My Disk", "")
	require.NoError(t, err)
	coll, err := d.UpsertCollection(disk.ID, "Original", "/mnt/disk/folder")
	require.NoError(t, err)

	require.NoError(t, d.RenameCollection(coll.ID, "Renamed"))

	colls, err := d.ListCollections(disk.ID)
	require.NoError(t, err)
	assert.Equal(t, "Renamed", colls[0].Label)
}

func TestRenameCollection_NotFound(t *testing.T) {
	d := openTestDB(t)
	err := d.RenameCollection(9999, "nope")
	assert.Error(t, err)
}

// ── File tests ────────────────────────────────────────────────────────────────

func makeFile(diskID int64, collID *int64, path string, size int64, isDir bool) *db.File {
	name := filepath.Base(path)
	return &db.File{
		DiskID:       diskID,
		CollectionID: collID,
		Name:         name,
		Path:         path,
		Size:         size,
		ModifiedAt:   time.Now().UTC().Truncate(time.Second),
		Extension:    "jpg",
		IsDir:        isDir,
	}
}

func TestUpsertFile_InsertAndUpdate(t *testing.T) {
	d := openTestDB(t)

	disk, err := d.UpsertDisk("My Disk", "")
	require.NoError(t, err)

	f := makeFile(disk.ID, nil, "vacation/photo.jpg", 1024, false)
	require.NoError(t, d.UpsertFile(f))

	// Upsert again with different size — should update.
	f.Size = 2048
	require.NoError(t, d.UpsertFile(f))

	fileMap, err := d.GetFileMapForDisk(disk.ID)
	require.NoError(t, err)
	require.Contains(t, fileMap, "vacation/photo.jpg")
	assert.Equal(t, int64(2048), fileMap["vacation/photo.jpg"].Size)
}

func TestGetFileMapForDisk(t *testing.T) {
	d := openTestDB(t)

	disk, err := d.UpsertDisk("My Disk", "")
	require.NoError(t, err)

	paths := []string{"a/foo.jpg", "a/bar.mp4", "b/baz.png"}
	for _, p := range paths {
		require.NoError(t, d.UpsertFile(makeFile(disk.ID, nil, p, 100, false)))
	}

	fileMap, err := d.GetFileMapForDisk(disk.ID)
	require.NoError(t, err)
	assert.Len(t, fileMap, 3)
	for _, p := range paths {
		assert.Contains(t, fileMap, p)
	}
}

func TestDeleteFilesByPath(t *testing.T) {
	d := openTestDB(t)

	disk, err := d.UpsertDisk("My Disk", "")
	require.NoError(t, err)

	require.NoError(t, d.UpsertFile(makeFile(disk.ID, nil, "keep.jpg", 100, false)))
	require.NoError(t, d.UpsertFile(makeFile(disk.ID, nil, "delete.jpg", 100, false)))

	require.NoError(t, d.DeleteFilesByPath(disk.ID, []string{"delete.jpg"}))

	fileMap, err := d.GetFileMapForDisk(disk.ID)
	require.NoError(t, err)
	assert.Len(t, fileMap, 1)
	assert.Contains(t, fileMap, "keep.jpg")
}

func TestDeleteAllFilesForDisk(t *testing.T) {
	d := openTestDB(t)

	disk, err := d.UpsertDisk("My Disk", "")
	require.NoError(t, err)
	require.NoError(t, d.UpsertFile(makeFile(disk.ID, nil, "a.jpg", 100, false)))
	require.NoError(t, d.UpsertFile(makeFile(disk.ID, nil, "b.jpg", 200, false)))

	require.NoError(t, d.DeleteAllFilesForDisk(disk.ID))

	fileMap, err := d.GetFileMapForDisk(disk.ID)
	require.NoError(t, err)
	assert.Empty(t, fileMap)
}

// ── Search tests ──────────────────────────────────────────────────────────────

func insertTestFiles(t *testing.T, d *db.DB, diskID int64, collID *int64) {
	t.Helper()
	files := []struct {
		path  string
		size  int64
		isDir bool
		ext   string
	}{
		{"vacation/beach.jpg", 4 * 1024 * 1024, false, "jpg"},
		{"vacation/sunset.jpg", 2 * 1024 * 1024, false, "jpg"},
		{"vacation/trip.mp4", 2 * 1024 * 1024 * 1024, false, "mp4"},
		{"work/report.pdf", 500 * 1024, false, "pdf"},
		{"vacation", 0, true, ""},
	}
	for _, f := range files {
		name := filepath.Base(f.path)
		file := &db.File{
			DiskID:       diskID,
			CollectionID: collID,
			Name:         name,
			Path:         f.path,
			Size:         f.size,
			ModifiedAt:   time.Now().UTC().Truncate(time.Second),
			Extension:    f.ext,
			IsDir:        f.isDir,
		}
		require.NoError(t, d.UpsertFile(file))
	}
}

func TestSearch_ByQuery(t *testing.T) {
	d := openTestDB(t)

	disk, _ := d.UpsertDisk("My Disk", "")
	insertTestFiles(t, d, disk.ID, nil)

	results, err := d.Search(db.SearchParams{Query: "beach", Limit: 50})
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.Equal(t, "beach.jpg", results[0].Name)
}

func TestSearch_ByExtension(t *testing.T) {
	d := openTestDB(t)

	disk, _ := d.UpsertDisk("My Disk", "")
	insertTestFiles(t, d, disk.ID, nil)

	results, err := d.Search(db.SearchParams{Extension: "jpg", Limit: 50})
	require.NoError(t, err)
	assert.Len(t, results, 2)
}

func TestSearch_DirsOnly(t *testing.T) {
	d := openTestDB(t)

	disk, _ := d.UpsertDisk("My Disk", "")
	insertTestFiles(t, d, disk.ID, nil)

	isDir := true
	results, err := d.Search(db.SearchParams{IsDir: &isDir, Limit: 50})
	require.NoError(t, err)
	assert.Len(t, results, 1)
	assert.True(t, results[0].IsDir)
}

func TestSearch_FilesOnly(t *testing.T) {
	d := openTestDB(t)

	disk, _ := d.UpsertDisk("My Disk", "")
	insertTestFiles(t, d, disk.ID, nil)

	isDir := false
	results, err := d.Search(db.SearchParams{IsDir: &isDir, Limit: 50})
	require.NoError(t, err)
	for _, r := range results {
		assert.False(t, r.IsDir)
	}
}

func TestSearch_MinSize(t *testing.T) {
	d := openTestDB(t)

	disk, _ := d.UpsertDisk("My Disk", "")
	insertTestFiles(t, d, disk.ID, nil)

	// Only the mp4 is >= 1GB
	results, err := d.Search(db.SearchParams{MinSize: 1 << 30, Limit: 50})
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.Equal(t, "trip.mp4", results[0].Name)
}

func TestSearch_ByDiskID(t *testing.T) {
	d := openTestDB(t)

	disk1, _ := d.UpsertDisk("Disk One", "")
	disk2, _ := d.UpsertDisk("Disk Two", "")
	require.NoError(t, d.UpsertFile(makeFile(disk1.ID, nil, "a.jpg", 100, false)))
	require.NoError(t, d.UpsertFile(makeFile(disk2.ID, nil, "b.jpg", 100, false)))

	results, err := d.Search(db.SearchParams{DiskID: disk1.ID, Limit: 50})
	require.NoError(t, err)
	require.Len(t, results, 1)
	assert.Equal(t, "Disk One", results[0].DiskLabel)
}

func TestSearch_Limit(t *testing.T) {
	d := openTestDB(t)

	disk, _ := d.UpsertDisk("My Disk", "")
	for i := 0; i < 10; i++ {
		require.NoError(t, d.UpsertFile(makeFile(disk.ID, nil, filepath.Join("dir", fmt.Sprintf("file%d.jpg", i)), 100, false)))
	}

	results, err := d.Search(db.SearchParams{Limit: 3})
	require.NoError(t, err)
	assert.Len(t, results, 3)
}

