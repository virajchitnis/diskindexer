package indexer

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/viraj/diskindexer/internal/db"
)

// CollectionSpec describes a manually specified collection.
type CollectionSpec struct {
	Label    string
	RootPath string // absolute path on disk
}

// Options configures an index run.
type Options struct {
	DiskLabel   string
	Description string
	MountPath   string
	// Collections overrides auto-detection when non-empty.
	Collections []CollectionSpec
	// Force wipes existing data before re-indexing from scratch.
	Force bool
}

// Stats is returned after a successful index run.
type Stats struct {
	Added   int
	Updated int
	Deleted int
	Skipped int
	Elapsed time.Duration
}

// Run indexes a disk, performing an incremental update unless Force is set.
func Run(database *db.DB, opts Options) (*Stats, error) {
	start := time.Now()

	disk, err := database.UpsertDisk(opts.DiskLabel, opts.Description)
	if err != nil {
		return nil, fmt.Errorf("upsert disk: %w", err)
	}

	if opts.Force {
		fmt.Println("  Force mode: clearing existing index...")
		if err := database.DeleteAllFilesForDisk(disk.ID); err != nil {
			return nil, fmt.Errorf("clear files: %w", err)
		}
		if err := database.DeleteCollectionsForDisk(disk.ID); err != nil {
			return nil, fmt.Errorf("clear collections: %w", err)
		}
	}

	fileMap, err := database.GetFileMapForDisk(disk.ID)
	if err != nil {
		return nil, fmt.Errorf("load file map: %w", err)
	}

	colls, err := resolveCollections(database, disk.ID, opts)
	if err != nil {
		return nil, fmt.Errorf("resolve collections: %w", err)
	}

	stats := &Stats{}
	seenPaths := make(map[string]struct{}, len(fileMap))

	for _, coll := range colls {
		if err := walkCollection(database, disk.ID, coll, opts.MountPath, fileMap, seenPaths, stats); err != nil {
			return nil, fmt.Errorf("walk collection %q: %w", coll.Label, err)
		}
		_ = database.UpdateCollectionIndexedAt(coll.ID, time.Now())
	}

	if err := walkRoot(database, disk.ID, opts.MountPath, colls, fileMap, seenPaths, stats); err != nil {
		return nil, fmt.Errorf("walk root: %w", err)
	}

	// Remove files that no longer exist on disk.
	var toDelete []string
	for path := range fileMap {
		if _, seen := seenPaths[path]; !seen {
			toDelete = append(toDelete, path)
		}
	}
	if err := database.DeleteFilesByPath(disk.ID, toDelete); err != nil {
		return nil, fmt.Errorf("delete stale files: %w", err)
	}
	stats.Deleted = len(toDelete)

	if err := database.UpdateDiskIndexedAt(disk.ID, time.Now()); err != nil {
		return nil, fmt.Errorf("update disk timestamp: %w", err)
	}

	stats.Elapsed = time.Since(start)
	return stats, nil
}

func resolveCollections(database *db.DB, diskID int64, opts Options) ([]*db.Collection, error) {
	var specs []CollectionSpec

	if len(opts.Collections) > 0 {
		specs = opts.Collections
	} else {
		entries, err := os.ReadDir(opts.MountPath)
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			if e.IsDir() && !isHidden(e.Name()) {
				specs = append(specs, CollectionSpec{
					Label:    e.Name(),
					RootPath: filepath.Join(opts.MountPath, e.Name()),
				})
			}
		}
	}

	var colls []*db.Collection
	for _, spec := range specs {
		coll, err := database.UpsertCollection(diskID, spec.Label, spec.RootPath)
		if err != nil {
			return nil, fmt.Errorf("upsert collection %q: %w", spec.Label, err)
		}
		colls = append(colls, coll)
	}
	return colls, nil
}

// walkCollection walks a collection directory and upserts file metadata in
// batched transactions. The tx variable is captured by the closure so that
// batch commits can start a fresh transaction mid-walk.
func walkCollection(
	database *db.DB,
	diskID int64,
	coll *db.Collection,
	mountPath string,
	fileMap map[string]*db.File,
	seenPaths map[string]struct{},
	stats *Stats,
) error {
	tx, err := database.BeginTx()
	if err != nil {
		return err
	}
	batchCount := 0

	err = filepath.WalkDir(coll.RootPath, func(absPath string, d fs.DirEntry, entryErr error) error {
		if entryErr != nil {
			fmt.Fprintf(os.Stderr, "  warning: skipping %s: %v\n", absPath, entryErr)
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}

		relPath, relErr := filepath.Rel(mountPath, absPath)
		if relErr != nil {
			return relErr
		}

		seenPaths[relPath] = struct{}{}

		info, infoErr := d.Info()
		if infoErr != nil {
			return nil // not fatal; skip this entry
		}

		if existing, ok := fileMap[relPath]; ok {
			if existing.Size == info.Size() && existing.ModifiedAt.Equal(info.ModTime().UTC().Truncate(time.Second)) {
				stats.Skipped++
				return nil
			}
			stats.Updated++
		} else {
			stats.Added++
		}

		f := fileFromEntry(diskID, &coll.ID, relPath, info)
		if upsertErr := db.UpsertFileTx(tx, f); upsertErr != nil {
			return upsertErr
		}

		batchCount++
		if batchCount >= 500 {
			batchCount = 0
			if commitErr := tx.Commit(); commitErr != nil {
				tx = nil
				return commitErr
			}
			tx, err = database.BeginTx()
			if err != nil {
				return err
			}
			fmt.Printf("\r  %s: %d files...", coll.Label, stats.Added+stats.Updated+stats.Skipped)
		}
		return nil
	})

	if err != nil {
		if tx != nil {
			tx.Rollback() //nolint:errcheck
		}
		return err
	}
	return tx.Commit()
}

// walkRoot indexes files sitting directly in the disk root (not inside any collection directory).
func walkRoot(
	database *db.DB,
	diskID int64,
	mountPath string,
	colls []*db.Collection,
	fileMap map[string]*db.File,
	seenPaths map[string]struct{},
	stats *Stats,
) error {
	collRoots := make(map[string]struct{}, len(colls))
	for _, c := range colls {
		collRoots[c.RootPath] = struct{}{}
	}

	entries, err := os.ReadDir(mountPath)
	if err != nil {
		return err
	}

	tx, err := database.BeginTx()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck

	for _, e := range entries {
		absPath := filepath.Join(mountPath, e.Name())
		if _, isCollRoot := collRoots[absPath]; isCollRoot {
			continue
		}
		if e.IsDir() {
			continue // subdirs at disk root that aren't collections are not indexed here
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		relPath := e.Name()
		seenPaths[relPath] = struct{}{}

		if existing, ok := fileMap[relPath]; ok {
			if existing.Size == info.Size() && existing.ModifiedAt.Equal(info.ModTime().UTC().Truncate(time.Second)) {
				stats.Skipped++
				continue
			}
			stats.Updated++
		} else {
			stats.Added++
		}

		f := fileFromEntry(diskID, nil, relPath, info)
		if err := db.UpsertFileTx(tx, f); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func fileFromEntry(diskID int64, collID *int64, relPath string, info fs.FileInfo) *db.File {
	name := filepath.Base(relPath)
	ext := strings.ToLower(filepath.Ext(name))
	if len(ext) > 0 {
		ext = ext[1:]
	}
	return &db.File{
		DiskID:       diskID,
		CollectionID: collID,
		Name:         name,
		Path:         relPath,
		Size:         info.Size(),
		ModifiedAt:   info.ModTime().UTC().Truncate(time.Second),
		Extension:    ext,
		IsDir:        info.IsDir(),
	}
}

func isHidden(name string) bool {
	return len(name) > 0 && name[0] == '.'
}

// ParseCollectionSpec parses "Label:/absolute/path" into a CollectionSpec.
func ParseCollectionSpec(s string) (CollectionSpec, error) {
	idx := strings.Index(s, ":")
	if idx <= 0 {
		return CollectionSpec{}, fmt.Errorf("invalid collection spec %q: expected \"Label:/path\"", s)
	}
	label := strings.TrimSpace(s[:idx])
	path := strings.TrimSpace(s[idx+1:])
	if label == "" || path == "" {
		return CollectionSpec{}, fmt.Errorf("invalid collection spec %q: label and path must not be empty", s)
	}
	return CollectionSpec{Label: label, RootPath: path}, nil
}

// ValidateUnderMount returns an error if the collection path is not under mountPath.
func (s CollectionSpec) ValidateUnderMount(mountPath string) error {
	rel, err := filepath.Rel(mountPath, s.RootPath)
	if err != nil || strings.HasPrefix(rel, "..") {
		return fmt.Errorf("collection %q: path %q is not under mount path %q", s.Label, s.RootPath, mountPath)
	}
	return nil
}
