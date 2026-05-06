package db

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
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

// ── Search ────────────────────────────────────────────────────────────────────

// SearchParams defines filters for a file search.
type SearchParams struct {
	Query     string
	DiskLabel string // filter by disk label; resolved to DiskID per-DB
	DiskID    int64  // 0 = all disks (set automatically from DiskLabel)
	CollID    int64  // 0 = all collections
	Extension string // "" = all extensions
	IsDir     *bool  // nil = both, true = dirs only, false = files only
	MinSize   int64  // 0 = no minimum
	MaxSize   int64  // 0 = no maximum
	ModAfter  time.Time
	ModBefore time.Time
	Limit     int // 0 = default (50)
	Offset    int
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

	limit := p.Limit
	if limit <= 0 {
		limit = 50
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
