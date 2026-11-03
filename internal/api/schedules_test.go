package api

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/viraj/diskindexer/internal/db"
)

func TestNextRun(t *testing.T) {
	loc := time.FixedZone("T", 3600)
	old := schedulerLocation
	schedulerLocation = loc
	t.Cleanup(func() { schedulerLocation = old })

	created := time.Date(2026, 3, 2, 10, 0, 0, 0, loc)
	at := func(day, h, m int) time.Time { return time.Date(2026, 3, day, h, m, 0, 0, loc) }
	cases := []struct {
		name string
		sc   db.Schedule
		want *time.Time
	}{
		{"disabled", db.Schedule{IntervalHours: 24, CreatedAt: created}, nil},
		{"first, interval", db.Schedule{Enabled: true, IntervalHours: 6, CreatedAt: created}, ptr(at(2, 16, 0))},
		{"after a run", db.Schedule{Enabled: true, IntervalHours: 6, CreatedAt: created, LastRunAt: ptr(at(3, 1, 0))}, ptr(at(3, 7, 0))},
		{"first, at a time later today", db.Schedule{Enabled: true, IntervalHours: 24, At: "23:30", CreatedAt: created}, ptr(at(2, 23, 30))},
		{"first, at a time already past", db.Schedule{Enabled: true, IntervalHours: 24, At: "03:00", CreatedAt: created}, ptr(at(3, 3, 0))},
		{"daily after an on-time run", db.Schedule{Enabled: true, IntervalHours: 24, At: "03:00", CreatedAt: created, LastRunAt: ptr(at(3, 3, 0))}, ptr(at(4, 3, 0))},
		{"daily after a late run", db.Schedule{Enabled: true, IntervalHours: 24, At: "03:00", CreatedAt: created, LastRunAt: ptr(at(3, 9, 30))}, ptr(at(4, 3, 0))},
		{"weekly", db.Schedule{Enabled: true, IntervalHours: 168, At: "03:00", CreatedAt: created, LastRunAt: ptr(at(3, 3, 0))}, ptr(at(10, 3, 0))},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := nextRun(&c.sc)
			if c.want == nil {
				assert.Nil(t, got)
				return
			}
			require.NotNil(t, got)
			assert.True(t, c.want.Equal(*got), "want %v, got %v", c.want, got)
		})
	}
}

func ptr[T any](v T) *T { return &v }

func writeTree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for rel, content := range files {
		p := filepath.Join(root, rel)
		require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o755))
		require.NoError(t, os.WriteFile(p, []byte(content), 0o644))
	}
	return root
}

func newTestService(t *testing.T) *Service {
	t.Helper()
	s, err := NewService("test", filepath.Join(t.TempDir(), "t.diskindex"), nil)
	require.NoError(t, err)
	t.Cleanup(s.Close)
	return s
}

func waitJob(t *testing.T, s *Service, id string) Job {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		j, err := s.Job(id)
		require.NoError(t, err)
		if j.State != JobRunning {
			return j
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("job %s did not finish", id)
	return Job{}
}

func onlySchedule(t *testing.T, s *Service) Schedule {
	t.Helper()
	list, err := s.Schedules()
	require.NoError(t, err)
	require.Len(t, list, 1)
	return list[0]
}

// A due disk schedule reindexes the disk; once the disk is "unplugged" (its
// mount folder left empty) the run is skipped and nothing is removed.
func TestRunDueSchedules_IndexesThenSkipsUnpluggedDisk(t *testing.T) {
	s := newTestService(t)
	root := writeTree(t, map[string]string{"Photos/a.jpg": "a"})
	j, err := s.StartIndex(IndexRequest{Disk: "D", MountPath: root})
	require.NoError(t, err)
	require.Equal(t, JobDone, waitJob(t, s, j.ID).State)

	_, err = s.SaveSchedule("", 0, ScheduleRequest{Disk: "D", Path: root, IntervalHours: 24, Enabled: true})
	require.NoError(t, err)

	s.RunDueSchedules(time.Now()) // not due yet
	assert.Empty(t, onlySchedule(t, s).LastStatus)

	require.NoError(t, os.WriteFile(filepath.Join(root, "Photos", "b.jpg"), []byte("b"), 0o644))
	now := time.Now().Add(25 * time.Hour)
	s.RunDueSchedules(now)
	sc := onlySchedule(t, s)
	require.Equal(t, "running", sc.LastStatus)
	job := waitJob(t, s, sc.LastJobID)
	assert.Equal(t, JobDone, job.State)
	assert.Equal(t, sc.ID, job.Schedule)
	sc = onlySchedule(t, s)
	assert.Equal(t, "done", sc.LastStatus)
	assert.Equal(t, "1 added, 0 updated, 0 removed", sc.LastMessage)
	assert.True(t, sc.NextRunAt.After(now))

	require.NoError(t, os.RemoveAll(filepath.Join(root, "Photos")))
	s.RunDueSchedules(now.Add(25 * time.Hour))
	sc = onlySchedule(t, s)
	assert.Equal(t, "skipped", sc.LastStatus)
	assert.Contains(t, sc.LastMessage, "is empty")
	res, err := s.Search(SearchRequest{Query: "jpg"})
	require.NoError(t, err)
	assert.Len(t, res.Results, 2, "a skipped run must not remove anything")
}

// A collection schedule can read a copy; the collection keeps its location.
func TestRunSchedule_CollectionFromCopy(t *testing.T) {
	s := newTestService(t)
	root := writeTree(t, map[string]string{"Photos/a.jpg": "a", "Music/s.flac": "s"})
	j, err := s.StartIndex(IndexRequest{Disk: "D", MountPath: root})
	require.NoError(t, err)
	waitJob(t, s, j.ID)

	cp := writeTree(t, map[string]string{"a.jpg": "a", "c.jpg": "c"})
	sc, err := s.SaveSchedule("", 0, ScheduleRequest{Disk: "D", Collection: "Photos", Path: cp, IntervalHours: 1})
	require.NoError(t, err)
	assert.Nil(t, sc.NextRunAt, "disabled")

	sc, err = s.RunSchedule("", sc.ID)
	require.NoError(t, err)
	waitJob(t, s, sc.LastJobID)
	colls, err := s.Collections("D")
	require.NoError(t, err)
	for _, c := range colls {
		if c.Label == "Photos" {
			assert.Equal(t, filepath.Join(root, "Photos"), c.RootPath)
		}
	}
	res, err := s.Search(SearchRequest{Query: "c.jpg"})
	require.NoError(t, err)
	assert.Len(t, res.Results, 1)

	// The collection's schedule follows a rename, and goes with a delete.
	require.NoError(t, s.RenameCollection("", colls[1].ID, "Pictures"))
	assert.Equal(t, "Pictures", onlySchedule(t, s).Collection)
	require.NoError(t, s.DeleteCollection("", colls[1].ID))
	list, err := s.Schedules()
	require.NoError(t, err)
	assert.Empty(t, list)
}

func TestRunSchedule_SkipsWhatIsGone(t *testing.T) {
	s := newTestService(t)
	root := writeTree(t, map[string]string{"Photos/a.jpg": "a"})
	j, err := s.StartIndex(IndexRequest{Disk: "D", MountPath: root})
	require.NoError(t, err)
	waitJob(t, s, j.ID)
	sc, err := s.SaveSchedule("", 0, ScheduleRequest{Disk: "D", Collection: "Photos", IntervalHours: 24, At: "04:00", Enabled: true})
	require.NoError(t, err)

	require.NoError(t, os.RemoveAll(root))
	sc, err = s.RunSchedule("", sc.ID)
	require.NoError(t, err)
	assert.Equal(t, "skipped", sc.LastStatus)
	assert.Contains(t, sc.LastMessage, "isn’t there")

	// A schedule left behind for a collection that's gone is skipped too.
	d := s.dbs[s.defaultDB]
	_, err = d.SaveSchedule(&db.Schedule{Disk: "D", Collection: "Gone", IntervalHours: 1, Enabled: true})
	require.NoError(t, err)
	_, err = d.SaveSchedule(&db.Schedule{Disk: "Nope", IntervalHours: 1, Enabled: true})
	require.NoError(t, err)
	s.RunDueSchedules(time.Now().Add(2 * time.Hour))
	list, err := s.Schedules()
	require.NoError(t, err)
	for _, sc := range list {
		assert.Equal(t, "skipped", sc.LastStatus, sc.Collection)
	}
	require.NoError(t, s.DeleteDisk("", "D"))
	list, err = s.Schedules()
	require.NoError(t, err)
	assert.Len(t, list, 1, "only the schedule for the disk that was never indexed is left")
}

func TestSaveSchedule_Validation(t *testing.T) {
	s := newTestService(t)
	root := writeTree(t, map[string]string{"Photos/a.jpg": "a"})
	j, err := s.StartIndex(IndexRequest{Disk: "D", MountPath: root})
	require.NoError(t, err)
	waitJob(t, s, j.ID)

	bad := []ScheduleRequest{
		{Disk: "D", Path: root},                                        // no interval
		{Disk: "D", Path: root, IntervalHours: 6, At: "03:00"},         // time needs whole days
		{Disk: "D", Path: root, IntervalHours: 24, At: "3am"},          // bad time
		{Disk: "D", IntervalHours: 24},                                 // no mount path
		{Disk: "D", Path: "relative", IntervalHours: 24},               // not absolute
		{Disk: "D", Path: filepath.Join(root, "x"), IntervalHours: 24}, // missing
	}
	for _, req := range bad {
		_, err := s.SaveSchedule("", 0, req)
		assert.ErrorIs(t, err, ErrBadRequest, "%+v", req)
	}
	_, err = s.SaveSchedule("", 0, ScheduleRequest{Disk: "Nope", Path: root, IntervalHours: 24})
	assert.ErrorIs(t, err, ErrNotFound)
	_, err = s.SaveSchedule("", 0, ScheduleRequest{Disk: "D", Collection: "Nope", IntervalHours: 24})
	assert.ErrorIs(t, err, ErrNotFound)

	sc, err := s.SaveSchedule("", 0, ScheduleRequest{Disk: "D", Path: root, IntervalHours: 24, Enabled: true})
	require.NoError(t, err)
	_, err = s.SaveSchedule("", 0, ScheduleRequest{Disk: "D", Path: root, IntervalHours: 12})
	assert.ErrorIs(t, err, ErrConflict)
	sc, err = s.SaveSchedule("", sc.ID, ScheduleRequest{Disk: "D", Path: root, IntervalHours: 48, At: "02:15", Enabled: true})
	require.NoError(t, err)
	assert.Equal(t, 48, sc.IntervalHours)
	_, err = s.SaveSchedule("", 99, ScheduleRequest{Disk: "D", Path: root, IntervalHours: 48})
	assert.ErrorIs(t, err, ErrNotFound)
	assert.ErrorIs(t, s.DeleteSchedule("", 99), ErrNotFound)
	_, err = s.RunSchedule("", 99)
	assert.ErrorIs(t, err, ErrNotFound)
	require.NoError(t, s.DeleteSchedule("", sc.ID))
}

// A run the previous server left "running" is marked interrupted on start.
func TestRunScheduler_MarksInterruptedRuns(t *testing.T) {
	s := newTestService(t)
	d := s.dbs[s.defaultDB]
	sc, err := d.SaveSchedule(&db.Schedule{Disk: "D", Path: "/x", IntervalHours: 24})
	require.NoError(t, err)
	now := time.Now()
	require.NoError(t, d.RecordScheduleRun(sc.ID, &now, "running", "", "abc"))

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	s.RunScheduler(ctx, time.Hour)
	got := onlySchedule(t, s)
	assert.Equal(t, "interrupted", got.LastStatus)
	assert.Equal(t, interruptedMessage, got.LastMessage)
}
