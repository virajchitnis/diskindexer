package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/viraj/diskindexer/internal/db"
	"github.com/viraj/diskindexer/internal/indexer"
)

// job is the server-side state of one index run. Watchers wait on changed,
// which is closed and replaced on every update (a broadcast).
type job struct {
	mu      sync.Mutex
	snap    Job
	changed chan struct{}
	cancel  context.CancelFunc
	done    chan struct{}
}

func (j *job) update(fn func(*Job)) {
	j.mu.Lock()
	fn(&j.snap)
	close(j.changed)
	j.changed = make(chan struct{})
	j.mu.Unlock()
}

// Watch returns the current snapshot and a channel that is closed on the
// next change.
func (j *job) watch() (Job, <-chan struct{}) {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.snap, j.changed
}

type jobManager struct {
	mu   sync.Mutex
	jobs map[string]*job
}

func newJobManager() *jobManager {
	return &jobManager{jobs: map[string]*job{}}
}

func (m *jobManager) runningFor(dbPath string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, j := range m.jobs {
		snap, _ := j.watch()
		if snap.State == JobRunning && snap.Request.DB == dbPath {
			return true
		}
	}
	return false
}

func (m *jobManager) get(id string) (*job, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[id]
	return j, ok
}

func (m *jobManager) cancelAll() {
	m.mu.Lock()
	jobs := make([]*job, 0, len(m.jobs))
	for _, j := range m.jobs {
		jobs = append(jobs, j)
	}
	m.mu.Unlock()
	for _, j := range jobs {
		j.cancel()
		<-j.done
	}
}

func newJobID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// StartIndex validates req and starts an index run in the background. Only
// one run per DB may be active at a time.
func (s *Service) StartIndex(req IndexRequest) (Job, error) {
	req.Disk = strings.TrimSpace(req.Disk)
	if req.Disk == "" {
		return Job{}, fmt.Errorf("%w: disk label is required", ErrBadRequest)
	}
	// The mount path is optional when collections are listed, e.g. adding a
	// copy of a collection to a disk that isn't plugged in.
	if req.MountPath == "" {
		if len(req.Collections) == 0 {
			return Job{}, fmt.Errorf("%w: a mount path is required unless collections are listed", ErrBadRequest)
		}
	} else {
		info, err := os.Stat(req.MountPath)
		if err != nil {
			return Job{}, fmt.Errorf("%w: mount path %q: %v", ErrBadRequest, req.MountPath, err)
		}
		if !info.IsDir() {
			return Job{}, fmt.Errorf("%w: mount path %q is not a directory", ErrBadRequest, req.MountPath)
		}
	}
	dbPath, _, err := s.resolveDB(req.DB)
	if err != nil {
		return Job{}, err
	}
	req.DB = dbPath

	opts := indexer.Options{
		DiskLabel:   req.Disk,
		Description: req.Description,
		MountPath:   req.MountPath,
		Excludes:    req.Excludes,
		Force:       req.Force,
	}
	for _, c := range req.Collections {
		if c.Label == "" || c.RootPath == "" {
			return Job{}, fmt.Errorf("%w: collections need a label and a path", ErrBadRequest)
		}
		if info, err := os.Stat(c.RootPath); err != nil || !info.IsDir() {
			return Job{}, fmt.Errorf("%w: collection %q: %q is not a directory", ErrBadRequest, c.Label, c.RootPath)
		}
		opts.Collections = append(opts.Collections, indexer.CollectionSpec{Label: c.Label, RootPath: c.RootPath})
	}

	// Check-and-insert under one lock so two requests can't both start.
	m := s.jobs
	m.mu.Lock()
	for _, j := range m.jobs {
		snap, _ := j.watch()
		if snap.State == JobRunning && snap.Request.DB == dbPath {
			m.mu.Unlock()
			return Job{}, fmt.Errorf("%w: job %s is already indexing %s", ErrConflict, snap.ID, dbPath)
		}
	}
	// A separate handle for the writer keeps searches on the shared handle
	// responsive while the run holds its connection.
	writer, err := db.Open(dbPath)
	if err != nil {
		m.mu.Unlock()
		return Job{}, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	j := &job{
		snap:    Job{ID: newJobID(), State: JobRunning, Request: req, StartedAt: time.Now().UTC(), Progress: Progress{Phase: "starting"}},
		changed: make(chan struct{}),
		cancel:  cancel,
		done:    make(chan struct{}),
	}
	m.jobs[j.snap.ID] = j
	m.mu.Unlock()

	opts.ProgressFn = func(u indexer.ProgressUpdate) {
		j.update(func(s *Job) { s.Progress = progressFromIndexer(u) })
	}

	go func() {
		defer close(j.done)
		defer writer.Close()
		stats, err := indexer.RunContext(ctx, writer, opts)
		now := time.Now().UTC()
		j.update(func(s *Job) {
			s.FinishedAt = &now
			switch {
			case errors.Is(err, context.Canceled):
				s.State = JobCancelled
			case err != nil:
				s.State = JobFailed
				s.Error = err.Error()
			default:
				s.State = JobDone
				s.Stats = &Stats{Added: stats.Added, Updated: stats.Updated, Deleted: stats.Deleted,
					Skipped: stats.Skipped, ElapsedMs: float64(stats.Elapsed.Milliseconds())}
			}
		})
	}()

	snap, _ := j.watch()
	return snap, nil
}

// Jobs returns all jobs, newest first. Finished jobs are kept for the life of
// the process so a reconnecting client can see how a run ended.
func (s *Service) Jobs() []Job {
	s.jobs.mu.Lock()
	out := make([]Job, 0, len(s.jobs.jobs))
	for _, j := range s.jobs.jobs {
		snap, _ := j.watch()
		out = append(out, snap)
	}
	s.jobs.mu.Unlock()
	sort.Slice(out, func(i, k int) bool { return out[i].StartedAt.After(out[k].StartedAt) })
	return out
}

func (s *Service) Job(id string) (Job, error) {
	j, ok := s.jobs.get(id)
	if !ok {
		return Job{}, fmt.Errorf("%w: job %s", ErrNotFound, id)
	}
	snap, _ := j.watch()
	return snap, nil
}

// WatchJob returns the job's snapshot and a channel closed on its next change.
func (s *Service) WatchJob(id string) (Job, <-chan struct{}, error) {
	j, ok := s.jobs.get(id)
	if !ok {
		return Job{}, nil, fmt.Errorf("%w: job %s", ErrNotFound, id)
	}
	snap, ch := j.watch()
	return snap, ch, nil
}

// CancelJob asks a running job to stop and waits until it has.
func (s *Service) CancelJob(id string) (Job, error) {
	j, ok := s.jobs.get(id)
	if !ok {
		return Job{}, fmt.Errorf("%w: job %s", ErrNotFound, id)
	}
	j.cancel()
	<-j.done
	snap, _ := j.watch()
	return snap, nil
}
