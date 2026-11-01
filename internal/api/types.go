// Package api defines the JSON wire types served by `diskindexer serve` and the
// Service that implements them on top of the db and indexer packages. The DTOs
// are deliberately separate from the db models so the wire format stays stable.
package api

import (
	"time"

	"github.com/viraj/diskindexer/internal/db"
	"github.com/viraj/diskindexer/internal/indexer"
)

// Version is the wire protocol version. Bump it on incompatible changes so
// clients can refuse to talk to a server they don't understand.
const Version = 1

// DefaultSearchLimit matches the TUI result cap.
const DefaultSearchLimit = 500

type Info struct {
	APIVersion int      `json:"apiVersion"`
	Version    string   `json:"version"`
	Hostname   string   `json:"hostname"`
	OS         string   `json:"os"`
	DefaultDB  string   `json:"defaultDb"`
	DBs        []string `json:"dbs"`
}

type Disk struct {
	DB            string     `json:"db"`
	ID            int64      `json:"id"`
	Label         string     `json:"label"`
	Description   string     `json:"description"`
	CreatedAt     time.Time  `json:"createdAt"`
	LastIndexedAt *time.Time `json:"lastIndexedAt,omitempty"`
}

type Collection struct {
	DB            string     `json:"db"`
	ID            int64      `json:"id"`
	DiskLabel     string     `json:"diskLabel"`
	Label         string     `json:"label"`
	RootPath      string     `json:"rootPath"`
	LastIndexedAt *time.Time `json:"lastIndexedAt,omitempty"`
}

type File struct {
	DB         string    `json:"db"`
	ID         int64     `json:"id"`
	Name       string    `json:"name"`
	Path       string    `json:"path"`
	Size       int64     `json:"size"`
	ModifiedAt time.Time `json:"modifiedAt"`
	Extension  string    `json:"extension"`
	IsDir      bool      `json:"isDir"`
	DiskLabel  string    `json:"diskLabel"`
	CollLabel  string    `json:"collLabel"`
}

// SearchRequest mirrors the TUI/CLI filters. Type is "", "all", "files" or "dirs".
type SearchRequest struct {
	Query      string     `json:"query"`
	Disk       string     `json:"disk,omitempty"`
	Collection string     `json:"collection,omitempty"`
	Type       string     `json:"type,omitempty"`
	Extension  string     `json:"extension,omitempty"`
	MinSize    int64      `json:"minSize,omitempty"`
	MaxSize    int64      `json:"maxSize,omitempty"`
	ModAfter   *time.Time `json:"modAfter,omitempty"`
	ModBefore  *time.Time `json:"modBefore,omitempty"`
	Limit      int        `json:"limit,omitempty"`
}

type SearchResponse struct {
	Results []File `json:"results"`
	// Capped is true when more results exist than Limit (the "500+" indicator).
	Capped bool `json:"capped"`
}

type CollectionSpec struct {
	Label    string `json:"label"`
	RootPath string `json:"rootPath"`
}

// IndexRequest starts an index run (index and reindex are the same operation).
type IndexRequest struct {
	DB          string           `json:"db,omitempty"` // "" = default DB
	Disk        string           `json:"disk"`
	Description string           `json:"description,omitempty"`
	MountPath   string           `json:"mountPath"` // "" allowed when Collections is set
	Collections []CollectionSpec `json:"collections,omitempty"`
	Excludes    []string         `json:"excludes,omitempty"`
	Force       bool             `json:"force,omitempty"`
}

type Progress struct {
	Phase      string `json:"phase"`
	Collection string `json:"collection,omitempty"`
	Added      int    `json:"added"`
	Updated    int    `json:"updated"`
	Skipped    int    `json:"skipped"`
	Total      int    `json:"total"`
	Errors     int    `json:"errors"`
	Deleting   int    `json:"deleting"`
	DirsTotal  int    `json:"dirsTotal"`
	DirsDone   int    `json:"dirsDone"`
}

// PathError is a file or folder the indexer couldn't read. What was indexed
// under it before is kept.
type PathError struct {
	Path  string `json:"path"`
	Error string `json:"error"`
}

type Stats struct {
	Added     int     `json:"added"`
	Updated   int     `json:"updated"`
	Deleted   int     `json:"deleted"`
	Skipped   int     `json:"skipped"`
	ElapsedMs float64 `json:"elapsedMs"`
	// ErrorCount paths couldn't be read; Errors lists the first of them.
	ErrorCount int         `json:"errorCount"`
	Errors     []PathError `json:"errors,omitempty"`
}

type JobState string

const (
	JobRunning   JobState = "running"
	JobDone      JobState = "done"
	JobFailed    JobState = "failed"
	JobCancelled JobState = "cancelled"
)

type Job struct {
	ID         string       `json:"id"`
	State      JobState     `json:"state"`
	Request    IndexRequest `json:"request"`
	StartedAt  time.Time    `json:"startedAt"`
	FinishedAt *time.Time   `json:"finishedAt,omitempty"`
	Progress   Progress     `json:"progress"`
	Stats      *Stats       `json:"stats,omitempty"`
	Error      string       `json:"error,omitempty"`
}

type DirEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

type DirListing struct {
	Path    string     `json:"path"`
	Parent  string     `json:"parent,omitempty"`
	Entries []DirEntry `json:"entries"`
}

type Error struct {
	Error string `json:"error"`
}

func diskFromDB(dbPath string, d *db.Disk) Disk {
	return Disk{DB: dbPath, ID: d.ID, Label: d.Label, Description: d.Description,
		CreatedAt: d.CreatedAt, LastIndexedAt: d.LastIndexedAt}
}

func collectionFromDB(dbPath string, c *db.Collection) Collection {
	return Collection{DB: dbPath, ID: c.ID, DiskLabel: c.DiskLabel, Label: c.Label,
		RootPath: c.RootPath, LastIndexedAt: c.LastIndexedAt}
}

func fileFromDB(dbPath string, f *db.File) File {
	return File{DB: dbPath, ID: f.ID, Name: f.Name, Path: f.Path, Size: f.Size,
		ModifiedAt: f.ModifiedAt, Extension: f.Extension, IsDir: f.IsDir,
		DiskLabel: f.DiskLabel, CollLabel: f.CollLabel}
}

func progressFromIndexer(u indexer.ProgressUpdate) Progress {
	return Progress{Phase: u.Phase, Collection: u.Collection, Added: u.Added,
		Updated: u.Updated, Skipped: u.Skipped, Total: u.Total, Errors: u.Errors,
		Deleting: u.Deleting, DirsTotal: u.DirsTotal, DirsDone: u.DirsDone}
}

func statsFromIndexer(st *indexer.Stats) *Stats {
	out := &Stats{Added: st.Added, Updated: st.Updated, Deleted: st.Deleted, Skipped: st.Skipped,
		ElapsedMs: float64(st.Elapsed.Milliseconds()), ErrorCount: st.ErrorCount}
	for _, e := range st.Errors {
		out.Errors = append(out.Errors, PathError{Path: e.Path, Error: e.Err})
	}
	return out
}
