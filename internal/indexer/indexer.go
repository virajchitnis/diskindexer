package indexer

import (
	"context"
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
	// MountPath is the disk's root. It may be empty when Collections is set,
	// e.g. to add a copy of a collection that lives elsewhere to a disk that
	// isn't plugged in; files at the disk root are then neither indexed nor
	// removed.
	MountPath string
	// Collections overrides auto-detection when non-empty.
	Collections []CollectionSpec
	// Force wipes existing data before re-indexing from scratch.
	Force bool
	// Excludes are names or glob patterns (filepath.Match) of files and
	// folders to skip at any depth, e.g. [".snapshots", "*.tmp"]; a skipped
	// folder skips everything in it. They are saved with the disk. nil means
	// "reuse the excludes saved with the disk"; an empty, non-nil slice means
	// none.
	Excludes []string
	// DefaultExcludes always apply on top of Excludes (the configured
	// default_excludes). They aren't saved with the disk.
	DefaultExcludes []string
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
	// ErrorCount is the number of paths that couldn't be read. Errors holds
	// the first maxErrorSamples of them. A folder that couldn't be read keeps
	// whatever was indexed under it before, rather than being emptied.
	ErrorCount int
	Errors     []PathError
	// Excludes are the patterns this run actually skipped: the defaults plus
	// the disk's own.
	Excludes []string
	Elapsed  time.Duration
}

// PathError is a file or folder the walk couldn't read.
type PathError struct {
	Path string // absolute path on the machine doing the indexing
	Err  string
}

const maxErrorSamples = 50

// progressInterval throttles progress reports during the walk, so they keep
// coming even when every file is unchanged. A var so tests can shorten it.
var progressInterval = 200 * time.Millisecond

// ProgressUpdate carries cumulative progress for a running index operation.
// All integer fields are totals for the entire run so far.
type ProgressUpdate struct {
	// Phase is one of:
	//   "loading"  reading the existing index for this disk
	//   "clearing" wiping it first (Force)
	//   "indexing" walking a collection (see Collection)
	//   "root"     indexing loose files at the top of the disk
	//   "deleting" removing files no longer on disk (see Deleting)
	//   "sizes"    computing folder sizes (see DirsTotal/DirsDone)
	Phase      string
	Collection string // label of the collection currently being walked
	Added      int
	Updated    int
	Skipped    int
	// Total is the estimated total file count (from the pre-walk file map).
	// Zero means unknown (first run, or --force wipe).
	Total int
	// Errors counts paths that couldn't be read so far.
	Errors int
	// Deleting is how many files the "deleting" phase is removing.
	Deleting int
	// DirsTotal and DirsDone track progress during the "sizes" phase.
	DirsTotal int
	DirsDone  int
}

// Run indexes a disk, performing an incremental update unless Force is set.
func Run(database *db.DB, opts Options) (*Stats, error) {
	return RunContext(context.Background(), database, opts)
}

// run is the state of one index run.
type run struct {
	ctx     context.Context
	db      *db.DB
	diskID  int64
	opts    Options
	stats   *Stats
	fileMap map[string]*db.File
	seen    map[string]struct{}
	total   int

	phase, coll string
	deleting    int
	lastReport  time.Time
	excludes    []string // effective: defaults + the disk's own

	// unreadable holds index paths ("<disk>/...") of folders that couldn't
	// be read. Files previously indexed under them are kept: an I/O error or
	// a permissions change doesn't mean the files are gone from the disk.
	unreadable []string
}

// report sends progress; unless force is set it is throttled to
// progressInterval so the walk can call it for every entry.
func (r *run) report(force bool) {
	if r.opts.ProgressFn == nil {
		return
	}
	now := time.Now()
	if !force && now.Sub(r.lastReport) < progressInterval {
		return
	}
	r.lastReport = now
	r.opts.ProgressFn(ProgressUpdate{
		Phase:      r.phase,
		Collection: r.coll,
		Added:      r.stats.Added,
		Updated:    r.stats.Updated,
		Skipped:    r.stats.Skipped,
		Total:      r.total,
		Errors:     r.stats.ErrorCount,
		Deleting:   r.deleting,
	})
}

func (r *run) setPhase(phase, coll string) {
	r.phase, r.coll = phase, coll
	r.report(true)
}

// unreadablePath records a path the walk couldn't read. relPath is its index
// path; if it is (or may be) a folder, everything indexed under it is kept.
func (r *run) unreadablePath(absPath, relPath string, err error, isDir bool) {
	r.stats.ErrorCount++
	if len(r.stats.Errors) < maxErrorSamples {
		r.stats.Errors = append(r.stats.Errors, PathError{Path: absPath, Err: err.Error()})
	}
	r.seen[relPath] = struct{}{}
	if isDir {
		r.unreadable = append(r.unreadable, relPath)
	}
}

func (r *run) underUnreadable(path string) bool {
	for _, u := range r.unreadable {
		if strings.HasPrefix(path, u+"/") {
			return true
		}
	}
	return false
}

// RunContext is Run with cancellation. When ctx is cancelled the walk stops
// at the next entry and ctx.Err() is returned; batches already committed are
// kept, as with an interrupted CLI run.
func RunContext(ctx context.Context, database *db.DB, opts Options) (*Stats, error) {
	start := time.Now()

	if opts.MountPath == "" && len(opts.Collections) == 0 {
		return nil, fmt.Errorf("a mount path is required unless collections are specified")
	}
	if err := ValidateCollectionSpecs(opts.Collections); err != nil {
		return nil, err
	}

	disk, err := database.UpsertDisk(opts.DiskLabel, opts.Description)
	if err != nil {
		return nil, fmt.Errorf("upsert disk: %w", err)
	}

	// Reuse the disk's saved excludes unless this run gives its own, which
	// then replace them.
	if opts.Excludes == nil {
		opts.Excludes = disk.Excludes
	} else if err := database.SetDiskExcludes(disk.ID, opts.Excludes); err != nil {
		return nil, fmt.Errorf("save excludes: %w", err)
	}
	excludes := mergeExcludes(opts.DefaultExcludes, opts.Excludes)
	r := &run{ctx: ctx, db: database, diskID: disk.ID, opts: opts, stats: &Stats{Excludes: excludes}, excludes: excludes}

	if opts.Force {
		r.setPhase("clearing", "")
		if err := database.DeleteAllFilesForDisk(disk.ID); err != nil {
			return nil, fmt.Errorf("clear files: %w", err)
		}
		if err := database.DeleteCollectionsForDisk(disk.ID); err != nil {
			return nil, fmt.Errorf("clear collections: %w", err)
		}
	}

	r.setPhase("loading", "")
	r.fileMap, err = database.GetFileMapForDisk(disk.ID)
	if err != nil {
		return nil, fmt.Errorf("load file map: %w", err)
	}
	// Use the existing file count as a total estimate. This is accurate for
	// incremental re-index runs; zero for first runs and --force (unknown total).
	r.total = len(r.fileMap)
	r.seen = make(map[string]struct{}, len(r.fileMap))

	resolveOpts := opts
	resolveOpts.Excludes = excludes
	colls, err := resolveCollections(database, disk.ID, resolveOpts)
	if err != nil {
		return nil, fmt.Errorf("resolve collections: %w", err)
	}

	for _, coll := range colls {
		r.setPhase("indexing", coll.Label)
		if err := r.walkCollection(coll); err != nil {
			return nil, fmt.Errorf("walk collection %q: %w", coll.Label, err)
		}
		_ = database.UpdateCollectionIndexedAt(coll.ID, time.Now())
	}

	if opts.MountPath != "" {
		r.setPhase("root", "")
		if err := r.walkRoot(colls); err != nil {
			return nil, fmt.Errorf("walk root: %w", err)
		}
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
	for path, f := range r.fileMap {
		if _, seen := r.seen[path]; seen {
			continue
		}
		// Preserve files from collections not walked this run.
		if f.CollectionID != nil {
			if _, walked := walkedCollIDs[*f.CollectionID]; !walked {
				continue
			}
		} else if opts.MountPath == "" {
			// Disk-root files: only a run that walked the root may remove them.
			continue
		}
		if r.underUnreadable(path) {
			continue
		}
		toDelete = append(toDelete, path)
	}
	r.deleting = len(toDelete)
	r.setPhase("deleting", "")
	if err := database.DeleteFilesByPath(disk.ID, toDelete); err != nil {
		return nil, fmt.Errorf("delete stale files: %w", err)
	}
	r.stats.Deleted = len(toDelete)

	// Recompute directory sizes in Go (O(N × depth)) with parallel collection
	// processing. Done after all upserts/deletes so numbers are accurate.
	r.setPhase("sizes", "")
	sizesProgressFn := func(done, total int) {
		if opts.ProgressFn != nil {
			opts.ProgressFn(ProgressUpdate{
				Phase:     "sizes",
				Total:     r.total,
				Errors:    r.stats.ErrorCount,
				DirsTotal: total,
				DirsDone:  done,
			})
		}
	}
	if err := database.ComputeAndUpdateDirSizes(ctx, disk.ID, sizesProgressFn); err != nil {
		return nil, fmt.Errorf("update dir sizes: %w", err)
	}

	if err := database.UpdateDiskIndexedAt(disk.ID, time.Now()); err != nil {
		return nil, fmt.Errorf("update disk timestamp: %w", err)
	}

	r.stats.Elapsed = time.Since(start)
	return r.stats, nil
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
func (r *run) walkCollection(coll *db.Collection) error {
	diskLabel := r.opts.DiskLabel
	tx, err := r.db.BeginTx()
	if err != nil {
		return err
	}
	batchCount := 0

	err = filepath.WalkDir(coll.RootPath, func(absPath string, d fs.DirEntry, entryErr error) error {
		if ctxErr := r.ctx.Err(); ctxErr != nil {
			return ctxErr
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

		if entryErr != nil {
			// Either the entry itself couldn't be read (d is nil) or it is a
			// folder whose contents couldn't be listed. Either way keep what
			// was indexed there before.
			r.unreadablePath(absPath, relPath, entryErr, d == nil || d.IsDir())
			r.report(false)
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		// Skip excluded files and folders (and everything in them). Not
		// marking them seen means previously indexed copies are removed.
		if absPath != coll.RootPath && isExcluded(d.Name(), r.excludes) {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}

		r.seen[relPath] = struct{}{}
		defer r.report(false)

		info, infoErr := d.Info()
		if infoErr != nil {
			r.unreadablePath(absPath, relPath, infoErr, d.IsDir())
			return nil
		}

		if existing, ok := r.fileMap[relPath]; ok {
			// For directories, skip the size comparison: their size is managed
			// by UpdateDirSizes (a computed value), not the OS-reported size.
			sizeMatch := info.IsDir() || existing.Size == info.Size()
			// An unchanged file is still rewritten if it belongs to another
			// collection row, so it follows the collection it's found in.
			if sizeMatch && existing.ModifiedAt.Equal(info.ModTime().UTC().Truncate(time.Second)) &&
				sameCollection(existing.CollectionID, &coll.ID) {
				r.stats.Skipped++
				return nil
			}
			r.stats.Updated++
		} else {
			r.stats.Added++
		}

		f := fileFromEntry(r.diskID, &coll.ID, relPath, info)
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
			tx, err = r.db.BeginTx()
			if err != nil {
				return err
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
func (r *run) walkRoot(colls []*db.Collection) error {
	mountPath, diskLabel := r.opts.MountPath, r.opts.DiskLabel
	collRoots := make(map[string]struct{}, len(colls))
	for _, c := range colls {
		collRoots[c.RootPath] = struct{}{}
	}

	entries, err := os.ReadDir(mountPath)
	if err != nil {
		return err
	}

	tx, err := r.db.BeginTx()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck

	for _, e := range entries {
		if err := r.ctx.Err(); err != nil {
			return err
		}
		absPath := filepath.Join(mountPath, e.Name())
		if _, isCollRoot := collRoots[absPath]; isCollRoot {
			continue
		}
		if e.IsDir() {
			continue // subdirs at disk root that aren't collections are not indexed here
		}
		if isExcluded(e.Name(), r.excludes) {
			continue
		}
		relPath := diskLabel + "/" + e.Name()
		info, err := e.Info()
		if err != nil {
			r.unreadablePath(absPath, relPath, err, false)
			continue
		}
		r.seen[relPath] = struct{}{}

		if existing, ok := r.fileMap[relPath]; ok {
			sizeMatch := info.IsDir() || existing.Size == info.Size()
			if sizeMatch && existing.ModifiedAt.Equal(info.ModTime().UTC().Truncate(time.Second)) &&
				sameCollection(existing.CollectionID, nil) {
				r.stats.Skipped++
				continue
			}
			r.stats.Updated++
		} else {
			r.stats.Added++
		}

		f := fileFromEntry(r.diskID, nil, relPath, info)
		if err := db.UpsertFileTx(tx, f); err != nil {
			return err
		}
		r.report(false)
	}
	return tx.Commit()
}

func sameCollection(a, b *int64) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
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

// mergeExcludes combines exclude lists, dropping blanks and duplicates.
func mergeExcludes(lists ...[]string) []string {
	var out []string
	seen := map[string]bool{}
	for _, list := range lists {
		for _, p := range list {
			p = strings.TrimSpace(p)
			if p != "" && !seen[p] {
				seen[p] = true
				out = append(out, p)
			}
		}
	}
	return out
}

// isExcluded reports whether a file or folder name matches any of the given exclude
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

// ValidateCollectionSpecs rejects manual collections that would collide:
// every file is stored as "<disk>/<label>/...", so two specs with the same
// label would silently overwrite each other's files in the index, and the
// same folder listed twice would be indexed twice.
func ValidateCollectionSpecs(specs []CollectionSpec) error {
	labels := make(map[string]string, len(specs))
	roots := make(map[string]string, len(specs))
	for _, spec := range specs {
		if prev, ok := labels[spec.Label]; ok {
			return fmt.Errorf("collection %q is listed twice (%s and %s); each collection needs its own name", spec.Label, prev, spec.RootPath)
		}
		root := filepath.Clean(spec.RootPath)
		if prev, ok := roots[root]; ok {
			return fmt.Errorf("folder %s is listed twice (as %q and %q)", spec.RootPath, prev, spec.Label)
		}
		labels[spec.Label] = spec.RootPath
		roots[root] = spec.Label
	}
	return nil
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

