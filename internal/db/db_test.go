package db_test

import (
	"context"
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

// ── ComputeAndUpdateDirSizes tests ────────────────────────────────────────────

func TestComputeAndUpdateDirSizes_Basic(t *testing.T) {
	d := openTestDB(t)
	disk, _ := d.UpsertDisk("Test Disk", "")
	coll, _ := d.UpsertCollection(disk.ID, "Photos", "/mnt/Photos")

	require.NoError(t, d.UpsertFile(makeFile(disk.ID, &coll.ID, "Test Disk/Photos", 0, true)))
	require.NoError(t, d.UpsertFile(makeFile(disk.ID, &coll.ID, "Test Disk/Photos/a.jpg", 1024, false)))
	require.NoError(t, d.UpsertFile(makeFile(disk.ID, &coll.ID, "Test Disk/Photos/b.jpg", 2048, false)))

	var progressCalls []int
	err := d.ComputeAndUpdateDirSizes(context.Background(), disk.ID, func(done, _ int) {
		progressCalls = append(progressCalls, done)
	})
	require.NoError(t, err)

	fileMap, _ := d.GetFileMapForDisk(disk.ID)
	assert.Equal(t, int64(3072), fileMap["Test Disk/Photos"].Size)

	// Progress was called at least twice (initial 0 and final N).
	require.GreaterOrEqual(t, len(progressCalls), 2)
	assert.Equal(t, 0, progressCalls[0])
	assert.Equal(t, 1, progressCalls[len(progressCalls)-1]) // 1 dir total
}

func TestComputeAndUpdateDirSizes_NoDirs(t *testing.T) {
	d := openTestDB(t)
	disk, _ := d.UpsertDisk("Test Disk", "")
	// File only, no directory entry.
	require.NoError(t, d.UpsertFile(makeFile(disk.ID, nil, "Test Disk/root.jpg", 500, false)))

	// Should not error and should not panic.
	require.NoError(t, d.ComputeAndUpdateDirSizes(context.Background(), disk.ID, nil))
}

func TestComputeAndUpdateDirSizes_EmptyDisk(t *testing.T) {
	d := openTestDB(t)
	disk, _ := d.UpsertDisk("Test Disk", "")
	// No files at all.
	require.NoError(t, d.ComputeAndUpdateDirSizes(context.Background(), disk.ID, nil))
}

func TestComputeAndUpdateDirSizes_NestedDirs(t *testing.T) {
	d := openTestDB(t)
	disk, _ := d.UpsertDisk("Test Disk", "")
	coll, _ := d.UpsertCollection(disk.ID, "Work", "/mnt/Work")

	// Hierarchy: Work/ → Sub/ → file.pdf (100 bytes)
	// Both Work/ and Work/Sub/ should accumulate 100.
	entries := []struct {
		p     string
		size  int64
		isDir bool
	}{
		{"Test Disk/Work", 0, true},
		{"Test Disk/Work/Sub", 0, true},
		{"Test Disk/Work/Sub/f.pdf", 100, false},
	}
	for _, e := range entries {
		require.NoError(t, d.UpsertFile(makeFile(disk.ID, &coll.ID, e.p, e.size, e.isDir)))
	}

	require.NoError(t, d.ComputeAndUpdateDirSizes(context.Background(), disk.ID, nil))

	fileMap, _ := d.GetFileMapForDisk(disk.ID)
	assert.Equal(t, int64(100), fileMap["Test Disk/Work"].Size)
	assert.Equal(t, int64(100), fileMap["Test Disk/Work/Sub"].Size)
}

func TestComputeAndUpdateDirSizes_MultipleCollections(t *testing.T) {
	d := openTestDB(t)
	disk, _ := d.UpsertDisk("Test Disk", "")
	c1, _ := d.UpsertCollection(disk.ID, "Photos", "/mnt/Photos")
	c2, _ := d.UpsertCollection(disk.ID, "Videos", "/mnt/Videos")

	require.NoError(t, d.UpsertFile(makeFile(disk.ID, &c1.ID, "Test Disk/Photos", 0, true)))
	require.NoError(t, d.UpsertFile(makeFile(disk.ID, &c1.ID, "Test Disk/Photos/a.jpg", 500, false)))
	require.NoError(t, d.UpsertFile(makeFile(disk.ID, &c2.ID, "Test Disk/Videos", 0, true)))
	require.NoError(t, d.UpsertFile(makeFile(disk.ID, &c2.ID, "Test Disk/Videos/b.mp4", 2000, false)))

	require.NoError(t, d.ComputeAndUpdateDirSizes(context.Background(), disk.ID, nil))

	fileMap, _ := d.GetFileMapForDisk(disk.ID)
	assert.Equal(t, int64(500), fileMap["Test Disk/Photos"].Size)
	assert.Equal(t, int64(2000), fileMap["Test Disk/Videos"].Size)
}


// ── MoveCollection tests ──────────────────────────────────────────────────────

// seedTwoDisks creates "Disk A" with a Photos collection (root dir, a file,
// and a nested file) and an empty "Disk B" with one Music collection, both
// with collection roots under a common mount point.
func seedTwoDisks(t *testing.T, d *db.DB) (photos *db.Collection, diskB *db.Disk) {
	t.Helper()
	diskA, err := d.UpsertDisk("Disk A", "")
	require.NoError(t, err)
	diskB, err = d.UpsertDisk("Disk B", "")
	require.NoError(t, err)
	photos, err = d.UpsertCollection(diskA.ID, "Photos", "/media/a/Photos")
	require.NoError(t, err)
	_, err = d.UpsertCollection(diskB.ID, "Music", "/media/b/Music")
	require.NoError(t, err)
	now := time.Now().UTC().Truncate(time.Second)
	for _, f := range []*db.File{
		{DiskID: diskA.ID, CollectionID: &photos.ID, Name: "Photos", Path: "Disk A/Photos", IsDir: true, Size: 7, ModifiedAt: now},
		{DiskID: diskA.ID, CollectionID: &photos.ID, Name: "beach.jpg", Path: "Disk A/Photos/beach.jpg", Size: 3, ModifiedAt: now, Extension: "jpg"},
		{DiskID: diskA.ID, CollectionID: &photos.ID, Name: "x.jpg", Path: "Disk A/Photos/2019/x.jpg", Size: 4, ModifiedAt: now, Extension: "jpg"},
		{DiskID: diskA.ID, Name: "root.txt", Path: "Disk A/root.txt", Size: 1, ModifiedAt: now},
	} {
		require.NoError(t, d.UpsertFile(f))
	}
	return photos, diskB
}

func TestMoveCollection(t *testing.T) {
	d := openTestDB(t)
	photos, diskB := seedTwoDisks(t, d)

	moved, err := d.MoveCollection(photos.ID, diskB.ID)
	require.NoError(t, err)
	require.NotNil(t, moved)
	assert.Equal(t, photos.ID, moved.ID)
	assert.Equal(t, "Disk B", moved.DiskLabel)
	assert.Equal(t, "/media/b/Photos", moved.RootPath, "root follows the target's mount point")

	files, err := d.GetFileMapForDisk(diskB.ID)
	require.NoError(t, err)
	for _, p := range []string{"Disk B/Photos", "Disk B/Photos/beach.jpg", "Disk B/Photos/2019/x.jpg"} {
		assert.Contains(t, files, p)
	}
	assert.Equal(t, int64(7), files["Disk B/Photos"].Size, "folder sizes are kept")

	// Disk A keeps only its root file.
	files, err = d.GetFileMapForDisk(photos.DiskID)
	require.NoError(t, err)
	assert.Len(t, files, 1)
	assert.Contains(t, files, "Disk A/root.txt")

	// Search (FTS) sees the new paths, and filtering by the new disk works.
	res, err := d.Search(db.SearchParams{Query: "beach", DiskLabel: "Disk B"})
	require.NoError(t, err)
	require.Len(t, res, 1)
	assert.Equal(t, "Disk B/Photos/beach.jpg", res[0].Path)
	res, err = d.Search(db.SearchParams{Query: "beach", DiskLabel: "Disk A"})
	require.NoError(t, err)
	assert.Empty(t, res)

	// Moving back restores the original paths.
	back, err := d.MoveCollection(photos.ID, photos.DiskID)
	require.NoError(t, err)
	assert.Equal(t, "Disk A", back.DiskLabel)
	files, err = d.GetFileMapForDisk(photos.DiskID)
	require.NoError(t, err)
	assert.Contains(t, files, "Disk A/Photos/2019/x.jpg")
}

func TestMoveCollection_Conflicts(t *testing.T) {
	d := openTestDB(t)
	photos, diskB := seedTwoDisks(t, d)

	_, err := d.UpsertCollection(diskB.ID, "Photos", "/elsewhere/Photos")
	require.NoError(t, err)
	_, err = d.MoveCollection(photos.ID, diskB.ID)
	require.ErrorIs(t, err, db.ErrConflict)
	assert.Contains(t, err.Error(), "already has a collection named")

	// Nothing moved.
	files, err := d.GetFileMapForDisk(photos.DiskID)
	require.NoError(t, err)
	assert.Len(t, files, 4)
}

func TestMoveCollection_PathCollision(t *testing.T) {
	d := openTestDB(t)
	photos, diskB := seedTwoDisks(t, d)
	// A root-level file on Disk B at the path the collection's root dir would take.
	require.NoError(t, d.UpsertFile(&db.File{DiskID: diskB.ID, Name: "Photos", Path: "Disk B/Photos", ModifiedAt: time.Now()}))

	_, err := d.MoveCollection(photos.ID, diskB.ID)
	require.ErrorIs(t, err, db.ErrConflict)
	// The transaction rolled back: the collection is still on Disk A.
	c, err := d.GetCollectionByID(photos.ID)
	require.NoError(t, err)
	assert.Equal(t, "Disk A", c.DiskLabel)
	files, err := d.GetFileMapForDisk(photos.DiskID)
	require.NoError(t, err)
	assert.Len(t, files, 4)
}

func TestMoveCollection_NoOpAndMissing(t *testing.T) {
	d := openTestDB(t)
	photos, _ := seedTwoDisks(t, d)

	same, err := d.MoveCollection(photos.ID, photos.DiskID)
	require.NoError(t, err)
	assert.Equal(t, "/media/a/Photos", same.RootPath)

	missing, err := d.MoveCollection(9999, photos.DiskID)
	require.NoError(t, err)
	assert.Nil(t, missing)

	_, err = d.MoveCollection(photos.ID, 9999)
	require.Error(t, err)
}

func TestMoveCollection_KeepsRootWhenTargetMountUnknown(t *testing.T) {
	d := openTestDB(t)
	photos, err := func() (*db.Collection, error) {
		a, _ := d.UpsertDisk("Disk A", "")
		return d.UpsertCollection(a.ID, "Photos", "/media/a/Photos")
	}()
	require.NoError(t, err)
	empty, err := d.UpsertDisk("Empty", "")
	require.NoError(t, err)

	moved, err := d.MoveCollection(photos.ID, empty.ID)
	require.NoError(t, err)
	assert.Equal(t, "/media/a/Photos", moved.RootPath)
}

func TestUpsertCollection_MatchesByLabel(t *testing.T) {
	d := openTestDB(t)
	disk, err := d.UpsertDisk("Disk", "")
	require.NoError(t, err)
	orig, err := d.UpsertCollection(disk.ID, "Photos", "/srv/copy/Photos")
	require.NoError(t, err)

	// Same label from a different folder adopts the existing collection.
	again, err := d.UpsertCollection(disk.ID, "Photos", "/media/disk/Photos")
	require.NoError(t, err)
	assert.Equal(t, orig.ID, again.ID)
	assert.Equal(t, "/media/disk/Photos", again.RootPath)

	colls, err := d.ListCollections(disk.ID)
	require.NoError(t, err)
	assert.Len(t, colls, 1)

	// A different label is still a new collection.
	other, err := d.UpsertCollection(disk.ID, "Music", "/media/disk/Music")
	require.NoError(t, err)
	assert.NotEqual(t, orig.ID, other.ID)
}
