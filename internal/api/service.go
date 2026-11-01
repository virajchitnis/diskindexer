package api

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"

	"github.com/viraj/diskindexer/internal/db"
	"github.com/viraj/diskindexer/internal/search"
)

// Sentinel errors; the HTTP layer maps them to status codes.
var (
	ErrBadRequest = errors.New("bad request")
	ErrNotFound   = errors.New("not found")
	ErrConflict   = errors.New("conflict")
)

// Service implements every operation the GUI needs. It keeps one long-lived
// handle per index for reads and small writes; index jobs open their own
// handle so a long run never blocks searches (the DBs use WAL mode).
type Service struct {
	version   string
	defaultDB string
	dbPaths   []string
	dbs       map[string]*db.DB
	jobs      *jobManager
}

// NewService opens defaultDB plus every path in dbPaths. defaultDB is where
// index runs write unless a request names another known DB. Other DBs that
// fail to open are skipped with a warning, as the CLI does.
func NewService(version, defaultDB string, dbPaths []string) (*Service, error) {
	s := &Service{version: version, defaultDB: defaultDB, dbs: map[string]*db.DB{}}
	d, err := db.Open(defaultDB)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", defaultDB, err)
	}
	s.dbs[defaultDB] = d
	s.dbPaths = append(s.dbPaths, defaultDB)
	for _, p := range dbPaths {
		if _, ok := s.dbs[p]; ok {
			continue
		}
		d, err := db.Open(p)
		if err != nil {
			log.Printf("warning: skipping %s: %v", p, err)
			continue
		}
		s.dbs[p] = d
		s.dbPaths = append(s.dbPaths, p)
	}
	s.jobs = newJobManager()
	return s, nil
}

// Close cancels running jobs, waits for them to stop, and closes the DBs.
func (s *Service) Close() {
	s.jobs.cancelAll()
	for _, d := range s.dbs {
		d.Close()
	}
}

func (s *Service) Info() Info {
	host, _ := os.Hostname()
	return Info{APIVersion: Version, Version: s.version, Hostname: host,
		OS: runtime.GOOS, DefaultDB: s.defaultDB, DBs: s.dbPaths}
}

// resolveDB maps a request's db field to an open handle; "" means default.
// Only known DBs are accepted so a client can't make the server open files.
func (s *Service) resolveDB(path string) (string, *db.DB, error) {
	if path == "" {
		path = s.defaultDB
	}
	d, ok := s.dbs[path]
	if !ok {
		return "", nil, fmt.Errorf("%w: unknown db %q", ErrBadRequest, path)
	}
	return path, d, nil
}

func (s *Service) handles() []*db.DB {
	out := make([]*db.DB, 0, len(s.dbPaths))
	for _, p := range s.dbPaths {
		out = append(out, s.dbs[p])
	}
	return out
}

func (s *Service) Disks() ([]Disk, error) {
	out := []Disk{}
	for _, p := range s.dbPaths {
		disks, err := s.dbs[p].ListDisks()
		if err != nil {
			return nil, err
		}
		for _, d := range disks {
			out = append(out, diskFromDB(p, d))
		}
	}
	return out, nil
}

// Collections lists collections across all DBs, optionally for one disk label.
func (s *Service) Collections(diskLabel string) ([]Collection, error) {
	out := []Collection{}
	for _, p := range s.dbPaths {
		colls, err := s.dbs[p].ListCollections(0)
		if err != nil {
			return nil, err
		}
		for _, c := range colls {
			if diskLabel == "" || c.DiskLabel == diskLabel {
				out = append(out, collectionFromDB(p, c))
			}
		}
	}
	return out, nil
}

func (s *Service) Search(req SearchRequest) (SearchResponse, error) {
	limit := req.Limit
	if limit <= 0 {
		limit = DefaultSearchLimit
	}
	p := db.SearchParams{
		Query:     req.Query,
		DiskLabel: req.Disk,
		CollLabel: req.Collection,
		Extension: req.Extension,
		MinSize:   req.MinSize,
		MaxSize:   req.MaxSize,
		Limit:     limit + 1, // one extra row tells us whether we hit the cap
	}
	switch req.Type {
	case "", "all":
	case "files":
		f := false
		p.IsDir = &f
	case "dirs":
		t := true
		p.IsDir = &t
	default:
		return SearchResponse{}, fmt.Errorf("%w: type must be all, files or dirs", ErrBadRequest)
	}
	if req.ModAfter != nil {
		p.ModAfter = *req.ModAfter
	}
	if req.ModBefore != nil {
		p.ModBefore = *req.ModBefore
	}

	results, err := search.Across(s.handles(), p)
	if err != nil {
		return SearchResponse{}, err
	}
	resp := SearchResponse{Results: make([]File, 0, min(len(results), limit))}
	if len(results) > limit {
		resp.Capped = true
		results = results[:limit]
	}
	for _, r := range results {
		resp.Results = append(resp.Results, fileFromDB(r.DBPath, r.File))
	}
	return resp, nil
}

// checkIdle rejects mutations on a DB that an index job is writing to.
func (s *Service) checkIdle(dbPath string) error {
	if s.jobs.runningFor(dbPath) {
		return fmt.Errorf("%w: an index job is running on %s", ErrConflict, dbPath)
	}
	return nil
}

func (s *Service) RenameCollection(dbPath string, id int64, label string) error {
	label = strings.TrimSpace(label)
	if label == "" {
		return fmt.Errorf("%w: label must not be empty", ErrBadRequest)
	}
	dbPath, d, err := s.resolveDB(dbPath)
	if err != nil {
		return err
	}
	if err := s.checkIdle(dbPath); err != nil {
		return err
	}
	if err := d.RenameCollection(id, label); err != nil {
		if strings.Contains(err.Error(), "not found") {
			return fmt.Errorf("%w: collection %d", ErrNotFound, id)
		}
		return err
	}
	return nil
}

func (s *Service) DeleteCollection(dbPath string, id int64) error {
	dbPath, d, err := s.resolveDB(dbPath)
	if err != nil {
		return err
	}
	if err := s.checkIdle(dbPath); err != nil {
		return err
	}
	ok, err := d.DeleteCollection(id)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("%w: collection %d", ErrNotFound, id)
	}
	return nil
}

func (s *Service) DeleteDisk(dbPath, label string) error {
	dbPath, d, err := s.resolveDB(dbPath)
	if err != nil {
		return err
	}
	if err := s.checkIdle(dbPath); err != nil {
		return err
	}
	ok, err := d.DeleteDisk(label)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("%w: disk %q", ErrNotFound, label)
	}
	return nil
}

// ListDir lists the subdirectories of path so a remote client can pick a
// mount path. Hidden directories are omitted; symlinks to directories are kept.
func (s *Service) ListDir(path string) (DirListing, error) {
	if path == "" {
		path = "/"
	}
	if !filepath.IsAbs(path) {
		return DirListing{}, fmt.Errorf("%w: path must be absolute", ErrBadRequest)
	}
	path = filepath.Clean(path)
	entries, err := os.ReadDir(path)
	if err != nil {
		if os.IsNotExist(err) {
			return DirListing{}, fmt.Errorf("%w: %s", ErrNotFound, path)
		}
		return DirListing{}, fmt.Errorf("%w: %v", ErrBadRequest, err)
	}
	out := DirListing{Path: path, Entries: []DirEntry{}}
	if path != "/" {
		out.Parent = filepath.Dir(path)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".") {
			continue
		}
		full := filepath.Join(path, e.Name())
		isDir := e.IsDir()
		if e.Type()&os.ModeSymlink != 0 {
			if info, err := os.Stat(full); err == nil {
				isDir = info.IsDir()
			}
		}
		if isDir {
			out.Entries = append(out.Entries, DirEntry{Name: e.Name(), Path: full})
		}
	}
	sort.Slice(out.Entries, func(i, j int) bool {
		return strings.ToLower(out.Entries[i].Name) < strings.ToLower(out.Entries[j].Name)
	})
	return out, nil
}

// Roots suggests where external disks are usually mounted on this machine.
func (s *Service) Roots() []DirEntry {
	user := os.Getenv("USER")
	home, _ := os.UserHomeDir()
	candidates := []string{"/Volumes", "/media/" + user, "/run/media/" + user, "/media", "/mnt", home, "/"}
	out := []DirEntry{}
	seen := map[string]bool{}
	for _, c := range candidates {
		if c == "" || seen[c] {
			continue
		}
		seen[c] = true
		if info, err := os.Stat(c); err == nil && info.IsDir() {
			out = append(out, DirEntry{Name: c, Path: c})
		}
	}
	return out
}
