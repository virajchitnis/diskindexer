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
	// Excludes is a list of directory names (or glob patterns) to skip at any
	// depth during the walk. Files are never matched; only directories. Example:
	// [".snapshots", "*.cache"]. Uses filepath.Match for pattern matching.
	Excludes []string
	// ProgressFn is called periodically with cumulative progress.
	// It may be called from any goroutine. Nil disables progress reporting.
	ProgressFn func(ProgressUpdate)
}

// Stats is returned after a successful index run.
type Stats struct {
	Added   int
	Updated int
	Deleted int
	Skipped int
	Elapsed time.Duration
}

// ProgressUpdate carries cumulative progress for a running index operation.
// All integer fields are totals for the entire run so far.
type ProgressUpdate struct {
	Phase      string // "clearing" | "indexing" | "sizes"
	Collection string // label of the collection currently being walked
	Added      int
	Updated    int
	Skipped    int
	// Total is the estimated total file count (from the pre-walk file map).
	// Zero means unknown (first run, or --force wipe).
	Total int
	// DirsTotal and DirsDone track progress during the "sizes" phase.
	DirsTotal int
	DirsDone  int
}

// Run indexes a disk, performing an incremental update unless Force is set.
func Run(database *db.DB, opts Options) (*Stats, error) {
	start := time.Now()

	disk, err := database.UpsertDisk(opts.DiskLabel, opts.Description)
	if err != nil {
		return nil, fmt.Errorf("upsert disk: %w", err)
	}

	stats := &Stats{}

	// report sends a ProgressUpdate with current cumulative totals.
	// totalEstimate and dir progress are captured by closure after being set below.
	var totalEstimate int
	report := func(phase, coll string, dirsTotal, dirsDone int) {
		if opts.ProgressFn != nil {
			opts.ProgressFn(ProgressUpdate{
				Phase:      phase,
				Collection: coll,
				Added:      stats.Added,
				Updated:    stats.Updated,
				Skipped:    stats.Skipped,
				Total:      totalEstimate,
				DirsTotal:  dirsTotal,
				DirsDone:   dirsDone,
			})
		}
	}

	if opts.Force {
		report("clearing", "", 0, 0)
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
	// Use the existing file count as a total estimate. This is accurate for
	// incremental re-index runs; zero for first runs and --force (unknown total).
	totalEstimate = len(fileMap)

	colls, err := resolveCollections(database, disk.ID, opts)
	if err != nil {
		return nil, fmt.Errorf("resolve collections: %w", err)
	}

	seenPaths := make(map[string]struct{}, len(fileMap))

	for _, coll := range colls {
		report("indexing", coll.Label, 0, 0)
		if err := walkCollection(database, disk.ID, coll, opts.DiskLabel, fileMap, seenPaths, stats, totalEstimate, opts.Excludes, opts.ProgressFn); err != nil {
			return nil, fmt.Errorf("walk collection %q: %w", coll.Label, err)
		}
		_ = database.UpdateCollectionIndexedAt(coll.ID, time.Now())
	}

	if err := walkRoot(database, disk.ID, opts.MountPath, opts.DiskLabel, colls, fileMap, seenPaths, stats); err != nil {
		return nil, fmt.Errorf("walk root: %w", err)
	}

	// Build the set of collection IDs walked this run so we only delete stale
	// files within those collections. Files belonging to collections that were
	// not walked (e.g. previously indexed collections not included in this
	// --collection run) are left untouched.
	walkedCollIDs := make(map[int64]struct{}, len(colls))
	for _, c := range colls {
		walkedCollIDs[c.ID] = struct{}{}
	}

	var toDelete []string
	for path, f := range fileMap {
		if _, seen := seenPaths[path]; seen {
			continue
		}
		// Preserve files from collections not walked this run.
		if f.CollectionID != nil {
			if _, walked := walkedCollIDs[*f.CollectionID]; !walked {
				continue
			}
		}
		toDelete = append(toDelete, path)
	}
	if err := database.DeleteFilesByPath(disk.ID, toDelete); err != nil {
		return nil, fmt.Errorf("delete stale files: %w", err)
	}
	stats.Deleted = len(toDelete)

	// Recompute directory sizes in Go (O(N × depth)) with parallel collection
	// processing. Done after all upserts/deletes so numbers are accurate.
	report("sizes", "", 0, 0)
	sizesProgressFn := func(done, total int) {
		if opts.ProgressFn != nil {
			opts.ProgressFn(ProgressUpdate{
				Phase:     "sizes",
				Total:     totalEstimate,
				DirsTotal: total,
				DirsDone:  done,
			})
		}
	}
	if err := database.ComputeAndUpdateDirSizes(disk.ID, sizesProgressFn); err != nil {
		return nil, fmt.Errorf("update dir sizes: %w", err)
	}

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
		// Validate all collection paths up-front before touching the database.
		for _, spec := range specs {
			info, err := os.Stat(spec.RootPath)
			if err != nil {
				return nil, fmt.Errorf("collection %q: %w", spec.Label, err)
			}
			if !info.IsDir() {
				return nil, fmt.Errorf("collection %q: path %q is not a directory", spec.Label, spec.RootPath)
			}
		}
	} else {
		entries, err := os.ReadDir(opts.MountPath)
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			if e.IsDir() && !isHidden(e.Name()) && !isExcluded(e.Name(), opts.Excludes) {
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
	diskLabel string,
	fileMap map[string]*db.File,
	seenPaths map[string]struct{},
	stats *Stats,
	totalEstimate int,
	excludes []string,
	progressFn func(ProgressUpdate),
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
		// Skip excluded directories (and everything beneath them).
		if d.IsDir() && absPath != coll.RootPath && isExcluded(d.Name(), excludes) {
			return fs.SkipDir
		}

		// Path is always relative to the collection root so that collections
		// outside the mount path (manually specified) work correctly.
		collRel, relErr := filepath.Rel(coll.RootPath, absPath)
		if relErr != nil {
			return relErr
		}
		var relPath string
		if collRel == "." {
			relPath = diskLabel + "/" + coll.Label
		} else {
			relPath = diskLabel + "/" + coll.Label + "/" + collRel
		}

		seenPaths[relPath] = struct{}{}

		info, infoErr := d.Info()
		if infoErr != nil {
			return nil // not fatal; skip this entry
		}

		if existing, ok := fileMap[relPath]; ok {
			// For directories, skip the size comparison: their size is managed
			// by UpdateDirSizes (a computed value), not the OS-reported size.
			sizeMatch := info.IsDir() || existing.Size == info.Size()
			if sizeMatch && existing.ModifiedAt.Equal(info.ModTime().UTC().Truncate(time.Second)) {
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
			if progressFn != nil {
				progressFn(ProgressUpdate{
					Phase:      "indexing",
					Collection: coll.Label,
					Added:      stats.Added,
					Updated:    stats.Updated,
					Skipped:    stats.Skipped,
					Total:      totalEstimate,
				})
			}
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
	diskLabel string,
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
		relPath := diskLabel + "/" + e.Name()
		seenPaths[relPath] = struct{}{}

		if existing, ok := fileMap[relPath]; ok {
			sizeMatch := info.IsDir() || existing.Size == info.Size()
			if sizeMatch && existing.ModifiedAt.Equal(info.ModTime().UTC().Truncate(time.Second)) {
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

// isExcluded reports whether a directory name matches any of the given exclude
// patterns. Patterns follow filepath.Match syntax (e.g. ".snapshots", "*.tmp").
// An invalid pattern is silently treated as a literal string comparison.
func isExcluded(name string, excludes []string) bool {
	for _, pattern := range excludes {
		matched, err := filepath.Match(pattern, name)
		if err != nil {
			// Malformed pattern — fall back to exact match.
			matched = pattern == name
		}
		if matched {
			return true
		}
	}
	return false
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

