package db

import (
	"database/sql"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

// DB wraps a SQLite connection for all diskindexer operations.
type DB struct {
	sql  *sql.DB
	Path string
}

func Open(path string) (*DB, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return nil, fmt.Errorf("create directory: %w", err)
	}
	sqlDB, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	// SQLite does not support concurrent writers; one connection is correct.
	sqlDB.SetMaxOpenConns(1)
	sqlDB.SetMaxIdleConns(1)
	if _, err := sqlDB.Exec(`
		PRAGMA journal_mode=WAL;
		PRAGMA foreign_keys=ON;
		PRAGMA busy_timeout=5000;
		PRAGMA synchronous=NORMAL;
	`); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("set pragmas: %w", err)
	}
	d := &DB{sql: sqlDB, Path: path}
	if err := d.migrate(); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return d, nil
}

func (d *DB) Close() error {
	return d.sql.Close()
}

func (d *DB) migrate() error {
	_, err := d.sql.Exec(schema)
	return err
}

// BeginTx starts a transaction for batch operations.
func (d *DB) BeginTx() (*sql.Tx, error) {
	return d.sql.Begin()
}

// ── Disks ────────────────────────────────────────────────────────────────────

func (d *DB) UpsertDisk(label, description string) (*Disk, error) {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := d.sql.Exec(`
		INSERT INTO disks (label, description, created_at)
		VALUES (?, ?, ?)
		ON CONFLICT(label) DO NOTHING
	`, label, description, now)
	if err != nil {
		return nil, err
	}
	return d.GetDiskByLabel(label)
}

func (d *DB) GetDiskByLabel(label string) (*Disk, error) {
	row := d.sql.QueryRow(
		`SELECT id, label, description, created_at, last_indexed_at FROM disks WHERE label = ?`,
		label,
	)
	return scanDisk(row)
}

func (d *DB) ListDisks() ([]*Disk, error) {
	rows, err := d.sql.Query(
		`SELECT id, label, description, created_at, last_indexed_at FROM disks ORDER BY label`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var disks []*Disk
	for rows.Next() {
		disk, err := scanDisk(rows)
		if err != nil {
			return nil, err
		}
		disks = append(disks, disk)
	}
	return disks, rows.Err()
}

func (d *DB) UpdateDiskIndexedAt(diskID int64, t time.Time) error {
	_, err := d.sql.Exec(
		`UPDATE disks SET last_indexed_at = ? WHERE id = ?`,
		t.UTC().Format(time.RFC3339), diskID,
	)
	return err
}

// ── Collections ───────────────────────────────────────────────────────────────

func (d *DB) UpsertCollection(diskID int64, label, rootPath string) (*Collection, error) {
	_, err := d.sql.Exec(`
		INSERT INTO collections (disk_id, label, root_path)
		VALUES (?, ?, ?)
		ON CONFLICT(disk_id, root_path) DO UPDATE SET label = excluded.label
	`, diskID, label, rootPath)
	if err != nil {
		return nil, err
	}
	return d.GetCollectionByPath(diskID, rootPath)
}

func (d *DB) GetCollectionByPath(diskID int64, rootPath string) (*Collection, error) {
	row := d.sql.QueryRow(`
		SELECT c.id, c.disk_id, d.label, c.label, c.root_path, c.last_indexed_at
		FROM collections c JOIN disks d ON c.disk_id = d.id
		WHERE c.disk_id = ? AND c.root_path = ?
	`, diskID, rootPath)
	return scanCollection(row)
}

func (d *DB) ListCollections(diskID int64) ([]*Collection, error) {
	var (
		rows *sql.Rows
		err  error
	)
	if diskID == 0 {
		rows, err = d.sql.Query(`
			SELECT c.id, c.disk_id, d.label, c.label, c.root_path, c.last_indexed_at
			FROM collections c JOIN disks d ON c.disk_id = d.id
			ORDER BY d.label, c.label
		`)
	} else {
		rows, err = d.sql.Query(`
			SELECT c.id, c.disk_id, d.label, c.label, c.root_path, c.last_indexed_at
			FROM collections c JOIN disks d ON c.disk_id = d.id
			WHERE c.disk_id = ?
			ORDER BY c.label
		`, diskID)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var colls []*Collection
	for rows.Next() {
		c, err := scanCollection(rows)
		if err != nil {
			return nil, err
		}
		colls = append(colls, c)
	}
	return colls, rows.Err()
}

// GetCollectionsByLabel returns all collections whose label matches collLabel.
// If diskLabel is non-empty the results are further filtered to that disk.
// Returns an empty slice (not an error) when nothing matches.
func (d *DB) GetCollectionsByLabel(collLabel, diskLabel string) ([]*Collection, error) {
	var (
		rows *sql.Rows
		err  error
	)
	if diskLabel != "" {
		rows, err = d.sql.Query(`
			SELECT c.id, c.disk_id, d.label, c.label, c.root_path, c.last_indexed_at
			FROM collections c JOIN disks d ON c.disk_id = d.id
			WHERE c.label = ? AND d.label = ?
			ORDER BY d.label, c.label
		`, collLabel, diskLabel)
	} else {
		rows, err = d.sql.Query(`
			SELECT c.id, c.disk_id, d.label, c.label, c.root_path, c.last_indexed_at
			FROM collections c JOIN disks d ON c.disk_id = d.id
			WHERE c.label = ?
			ORDER BY d.label, c.label
		`, collLabel)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var colls []*Collection
	for rows.Next() {
		c, err := scanCollection(rows)
		if err != nil {
			return nil, err
		}
		colls = append(colls, c)
	}
	return colls, rows.Err()
}

func (d *DB) RenameCollection(id int64, newLabel string) error {
	res, err := d.sql.Exec(`UPDATE collections SET label = ? WHERE id = ?`, newLabel, id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("collection %d not found", id)
	}
	return nil
}

func (d *DB) UpdateCollectionIndexedAt(collID int64, t time.Time) error {
	_, err := d.sql.Exec(
		`UPDATE collections SET last_indexed_at = ? WHERE id = ?`,
		t.UTC().Format(time.RFC3339), collID,
	)
	return err
}

func (d *DB) DeleteCollectionsForDisk(diskID int64) error {
	_, err := d.sql.Exec(`DELETE FROM collections WHERE disk_id = ?`, diskID)
	return err
}

// ── Files ─────────────────────────────────────────────────────────────────────

// GetFileMapForDisk returns all files for a disk keyed by relative path.
// Used to detect new, changed, and deleted files during incremental indexing.
func (d *DB) GetFileMapForDisk(diskID int64) (map[string]*File, error) {
	rows, err := d.sql.Query(`
		SELECT id, disk_id, collection_id, name, path, size, modified_at, extension, is_dir
		FROM files WHERE disk_id = ?
	`, diskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	m := make(map[string]*File)
	for rows.Next() {
		f, err := scanFile(rows)
		if err != nil {
			return nil, err
		}
		m[f.Path] = f
	}
	return m, rows.Err()
}

const upsertFileSQL = `
	INSERT INTO files (disk_id, collection_id, name, path, size, modified_at, extension, is_dir)
	VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	ON CONFLICT(disk_id, path) DO UPDATE SET
		collection_id = excluded.collection_id,
		name          = excluded.name,
		size          = excluded.size,
		modified_at   = excluded.modified_at,
		extension     = excluded.extension,
		is_dir        = excluded.is_dir
`

func (d *DB) UpsertFile(f *File) error {
	_, err := d.sql.Exec(upsertFileSQL,
		f.DiskID, nullInt64(f.CollectionID), f.Name, f.Path,
		f.Size, f.ModifiedAt.UTC().Format(time.RFC3339),
		f.Extension, boolToInt(f.IsDir),
	)
	return err
}

func UpsertFileTx(tx *sql.Tx, f *File) error {
	_, err := tx.Exec(upsertFileSQL,
		f.DiskID, nullInt64(f.CollectionID), f.Name, f.Path,
		f.Size, f.ModifiedAt.UTC().Format(time.RFC3339),
		f.Extension, boolToInt(f.IsDir),
	)
	return err
}

// DeleteFilesByPath removes specific files from a disk's index in a single transaction.
func (d *DB) DeleteFilesByPath(diskID int64, paths []string) error {
	if len(paths) == 0 {
		return nil
	}
	tx, err := d.sql.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck

	stmt, err := tx.Prepare(`DELETE FROM files WHERE disk_id = ? AND path = ?`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, p := range paths {
		if _, err := stmt.Exec(diskID, p); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (d *DB) DeleteAllFilesForDisk(diskID int64) error {
	_, err := d.sql.Exec(`DELETE FROM files WHERE disk_id = ?`, diskID)
	return err
}

// DeleteDisk removes a disk and all its collections and files (via CASCADE).
// Returns false if no disk with that label exists.
func (d *DB) DeleteDisk(label string) (bool, error) {
	res, err := d.sql.Exec(`DELETE FROM disks WHERE label = ?`, label)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// DeleteCollection removes a collection and all its files from the index.
// Files are deleted first to avoid the ON DELETE SET NULL behaviour on
// collection_id, which would orphan them rather than remove them.
// Returns false if no collection with that ID exists.
func (d *DB) DeleteCollection(id int64) (bool, error) {
	tx, err := d.sql.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback() //nolint:errcheck

	if _, err = tx.Exec(`DELETE FROM files WHERE collection_id = ?`, id); err != nil {
		return false, err
	}
	res, err := tx.Exec(`DELETE FROM collections WHERE id = ?`, id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return false, nil
	}
	return true, tx.Commit()
}

// dirSizeRow is a lightweight file record used by ComputeAndUpdateDirSizes.
type dirSizeRow struct {
	id    int64
	path  string
	size  int64
	isDir bool
}

// fetchAllFilesForDisk fetches id, path, size, and is_dir for every file
// belonging to diskID in a single sequential scan.
func (d *DB) fetchAllFilesForDisk(diskID int64) ([]dirSizeRow, error) {
	rows, err := d.sql.Query(
		`SELECT id, path, size, is_dir FROM files WHERE disk_id = ?`,
		diskID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dirSizeRow
	for rows.Next() {
		var r dirSizeRow
		var isDir int
		if err := rows.Scan(&r.id, &r.path, &r.size, &isDir); err != nil {
			return nil, err
		}
		r.isDir = isDir == 1
		out = append(out, r)
	}
	return out, rows.Err()
}

// groupByCollection partitions files into groups keyed by their first two
// path components (DiskLabel/CollLabel). Files sitting directly at the disk
// root (only one component) are grouped under just the disk label. Collections
// are disjoint subtrees, so each group can be processed independently.
func groupByCollection(files []dirSizeRow) map[string][]dirSizeRow {
	groups := make(map[string][]dirSizeRow)
	for _, f := range files {
		idx := strings.Index(f.path, "/")
		if idx < 0 {
			// Bare disk-root entry — unlikely but safe.
			groups[f.path] = append(groups[f.path], f)
			continue
		}
		rest := f.path[idx+1:]
		idx2 := strings.Index(rest, "/")
		var key string
		if idx2 < 0 {
			key = f.path[:idx+1+len(rest)] // DiskLabel/CollLabel (no deeper)
		} else {
			key = f.path[:idx+1+idx2] // DiskLabel/CollLabel
		}
		groups[key] = append(groups[key], f)
	}
	return groups
}

// computeDirSizes calculates directory sizes for one group of files
// (typically one collection). For every non-dir file it walks up the path
// hierarchy and adds the file's size to each ancestor directory.
// Paths use "/" as separator (stored format). Returns a map of dir ID → size.
func computeDirSizes(files []dirSizeRow) map[int64]int64 {
	// Build a lookup from path → dir row for this group.
	dirByPath := make(map[string]*dirSizeRow, len(files))
	for i := range files {
		if files[i].isDir {
			dirByPath[files[i].path] = &files[i]
		}
	}

	accumulator := make(map[int64]int64, len(dirByPath))
	for _, dr := range dirByPath {
		accumulator[dr.id] = 0 // initialise all dirs at zero
	}

	for _, f := range files {
		if f.isDir {
			continue
		}
		p := f.path
		for {
			parent := path.Dir(p) // always uses "/"; returns "." at root
			if parent == p || parent == "." {
				break
			}
			if dr, ok := dirByPath[parent]; ok {
				accumulator[dr.id] += f.size
			}
			p = parent
		}
	}
	return accumulator
}

// ComputeAndUpdateDirSizes recomputes directory sizes in Go (O(N × depth))
// rather than via a correlated SQL subquery (O(N²)). Collections are
// processed in parallel goroutines for the in-memory computation step; the
// resulting UPDATEs are written back to SQLite sequentially in batches of 200.
//
// progressFn is called after each batch with (done, total) directory counts.
// Passing nil disables progress reporting.
func (d *DB) ComputeAndUpdateDirSizes(diskID int64, progressFn func(done, total int)) error {
	files, err := d.fetchAllFilesForDisk(diskID)
	if err != nil {
		return fmt.Errorf("fetch files: %w", err)
	}
	if len(files) == 0 {
		return nil // nothing to do
	}

	// Parallel computation across disjoint collection subtrees.
	groups := groupByCollection(files)

	type result struct {
		sizes map[int64]int64
	}
	ch := make(chan result, len(groups))
	var wg sync.WaitGroup
	for _, grp := range groups {
		grp := grp
		wg.Add(1)
		go func() {
			defer wg.Done()
			ch <- result{sizes: computeDirSizes(grp)}
		}()
	}
	// Close channel once all goroutines finish so the range below terminates.
	go func() { wg.Wait(); close(ch) }()

	merged := make(map[int64]int64)
	for r := range ch {
		for id, sz := range r.sizes {
			merged[id] += sz
		}
	}

	// Build the update slice (only directories — entries with id in merged).
	type dirUpdate struct {
		id   int64
		size int64
	}
	updates := make([]dirUpdate, 0, len(merged))
	for id, sz := range merged {
		updates = append(updates, dirUpdate{id, sz})
	}

	total := len(updates)
	if progressFn != nil {
		progressFn(0, total)
	}
	if total == 0 {
		return nil
	}

	const batchSize = 200
	done := 0
	for len(updates) > 0 {
		batch := updates
		if len(batch) > batchSize {
			batch = updates[:batchSize]
		}
		updates = updates[len(batch):]

		tx, err := d.sql.Begin()
		if err != nil {
			return err
		}
		stmt, err := tx.Prepare(`UPDATE files SET size = ? WHERE id = ?`)
		if err != nil {
			tx.Rollback() //nolint:errcheck
			return err
		}
		for _, u := range batch {
			if _, err := stmt.Exec(u.size, u.id); err != nil {
				stmt.Close()
				tx.Rollback() //nolint:errcheck
				return err
			}
		}
		stmt.Close()
		if err := tx.Commit(); err != nil {
			return err
		}

		done += len(batch)
		if progressFn != nil {
			progressFn(done, total)
		}
	}
	return nil
}

// ── Search ────────────────────────────────────────────────────────────────────

// SearchParams defines filters for a file search.
type SearchParams struct {
	Query      string
	DiskLabel  string // filter by disk label; resolved to DiskID per-DB
	DiskID     int64  // 0 = all disks (set automatically from DiskLabel)
	CollID     int64  // 0 = all collections
	CollLabel  string // filter by collection label ("" = all collections)
	Extension  string // "" = all extensions
	IsDir      *bool  // nil = both, true = dirs only, false = files only
	MinSize    int64  // 0 = no minimum
	MaxSize    int64  // 0 = no maximum
	ModAfter   time.Time
	ModBefore  time.Time
	Limit      int // 0 = no limit; text mode defaults to 50 via flag
	Offset     int
}

// Search executes a search against this database and returns matching files.
func (d *DB) Search(p SearchParams) ([]*File, error) {
	// Resolve DiskLabel to a DiskID scoped to this database.
	if p.DiskLabel != "" && p.DiskID == 0 {
		disk, err := d.GetDiskByLabel(p.DiskLabel)
		if err != nil {
			return nil, err
		}
		if disk == nil {
			return nil, nil // this DB doesn't have that disk
		}
		p.DiskID = disk.ID
	}

	// 0 means no limit; SQLite LIMIT -1 is the canonical "unlimited" value.
	limit := p.Limit
	if limit == 0 {
		limit = -1
	}

	if p.Query != "" {
		return d.searchFTS(p, limit)
	}
	return d.searchSQL(p, limit)
}

func (d *DB) searchFTS(p SearchParams, limit int) ([]*File, error) {
	ftsQuery := buildFTSQuery(p.Query)
	args := []interface{}{ftsQuery}

	where := " WHERE files_fts MATCH ?"
	where, args = appendFilters(where, args, p)

	q := `
		SELECT f.id, f.disk_id, f.collection_id, f.name, f.path, f.size,
		       f.modified_at, f.extension, f.is_dir,
		       d.label, COALESCE(c.label, '')
		FROM files_fts ft
		JOIN files f       ON ft.rowid = f.id
		JOIN disks d       ON f.disk_id = d.id
		LEFT JOIN collections c ON f.collection_id = c.id` +
		where +
		fmt.Sprintf(" ORDER BY rank LIMIT %d OFFSET %d", limit, p.Offset)

	return d.queryFiles(q, args...)
}

func (d *DB) searchSQL(p SearchParams, limit int) ([]*File, error) {
	where := " WHERE 1=1"
	args := []interface{}{}
	where, args = appendFilters(where, args, p)

	q := `
		SELECT f.id, f.disk_id, f.collection_id, f.name, f.path, f.size,
		       f.modified_at, f.extension, f.is_dir,
		       d.label, COALESCE(c.label, '')
		FROM files f
		JOIN disks d       ON f.disk_id = d.id
		LEFT JOIN collections c ON f.collection_id = c.id` +
		where +
		fmt.Sprintf(" ORDER BY f.name LIMIT %d OFFSET %d", limit, p.Offset)

	return d.queryFiles(q, args...)
}

func appendFilters(where string, args []interface{}, p SearchParams) (string, []interface{}) {
	if p.DiskID != 0 {
		where += " AND f.disk_id = ?"
		args = append(args, p.DiskID)
	}
	if p.CollID != 0 {
		where += " AND f.collection_id = ?"
		args = append(args, p.CollID)
	}
	if p.CollLabel != "" {
		where += " AND c.label = ?"
		args = append(args, p.CollLabel)
	}
	if p.Extension != "" {
		where += " AND f.extension = ?"
		args = append(args, p.Extension)
	}
	if p.IsDir != nil {
		where += " AND f.is_dir = ?"
		args = append(args, boolToInt(*p.IsDir))
	}
	if p.MinSize > 0 {
		where += " AND f.size >= ?"
		args = append(args, p.MinSize)
	}
	if p.MaxSize > 0 {
		where += " AND f.size <= ?"
		args = append(args, p.MaxSize)
	}
	if !p.ModAfter.IsZero() {
		where += " AND f.modified_at >= ?"
		args = append(args, p.ModAfter.UTC().Format(time.RFC3339))
	}
	if !p.ModBefore.IsZero() {
		where += " AND f.modified_at <= ?"
		args = append(args, p.ModBefore.UTC().Format(time.RFC3339))
	}
	return where, args
}

func (d *DB) queryFiles(query string, args ...interface{}) ([]*File, error) {
	rows, err := d.sql.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var files []*File
	for rows.Next() {
		f := &File{}
		var collID sql.NullInt64
		var modifiedAt string
		var isDir int
		if err := rows.Scan(
			&f.ID, &f.DiskID, &collID, &f.Name, &f.Path, &f.Size,
			&modifiedAt, &f.Extension, &isDir,
			&f.DiskLabel, &f.CollLabel,
		); err != nil {
			return nil, err
		}
		if collID.Valid {
			f.CollectionID = &collID.Int64
		}
		f.ModifiedAt, _ = time.Parse(time.RFC3339, modifiedAt)
		f.IsDir = isDir == 1
		files = append(files, f)
	}
	return files, rows.Err()
}

// ── Helpers ───────────────────────────────────────────────────────────────────

type scanner interface {
	Scan(dest ...interface{}) error
}

func scanDisk(s scanner) (*Disk, error) {
	d := &Disk{}
	var createdAt, lastIndexedAt sql.NullString
	if err := s.Scan(&d.ID, &d.Label, &d.Description, &createdAt, &lastIndexedAt); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	if createdAt.Valid {
		d.CreatedAt, _ = time.Parse(time.RFC3339, createdAt.String)
	}
	if lastIndexedAt.Valid {
		t, _ := time.Parse(time.RFC3339, lastIndexedAt.String)
		d.LastIndexedAt = &t
	}
	return d, nil
}

func scanCollection(s scanner) (*Collection, error) {
	c := &Collection{}
	var lastIndexedAt sql.NullString
	if err := s.Scan(&c.ID, &c.DiskID, &c.DiskLabel, &c.Label, &c.RootPath, &lastIndexedAt); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	if lastIndexedAt.Valid {
		t, _ := time.Parse(time.RFC3339, lastIndexedAt.String)
		c.LastIndexedAt = &t
	}
	return c, nil
}

func scanFile(s scanner) (*File, error) {
	f := &File{}
	var collID sql.NullInt64
	var modifiedAt string
	var isDir int
	if err := s.Scan(&f.ID, &f.DiskID, &collID, &f.Name, &f.Path,
		&f.Size, &modifiedAt, &f.Extension, &isDir); err != nil {
		return nil, err
	}
	if collID.Valid {
		f.CollectionID = &collID.Int64
	}
	f.ModifiedAt, _ = time.Parse(time.RFC3339, modifiedAt)
	f.IsDir = isDir == 1
	return f, nil
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func nullInt64(v *int64) interface{} {
	if v == nil {
		return nil
	}
	return *v
}

// buildFTSQuery converts user input into an FTS5 prefix-match query.
// "vacation photo" → `"vacation"* "photo"*`
func buildFTSQuery(input string) string {
	if input == "" {
		return ""
	}
	// Simple word split; each word becomes a quoted prefix term.
	var parts []string
	start := -1
	for i, ch := range input + " " {
		if ch == ' ' || ch == '\t' {
			if start >= 0 {
				word := input[start:i]
				word = `"` + escFTS(word) + `"*`
				parts = append(parts, word)
				start = -1
			}
		} else if start < 0 {
			start = i
		}
	}
	result := ""
	for i, p := range parts {
		if i > 0 {
			result += " "
		}
		result += p
	}
	return result
}

func escFTS(s string) string {
	// Escape double quotes inside the FTS term
	result := ""
	for _, ch := range s {
		if ch == '"' {
			result += `""`
		} else {
			result += string(ch)
		}
	}
	return result
}
