package api

import (
	"context"
	"errors"
	"fmt"
	"log"
	"path/filepath"
	"strings"
	"time"

	"github.com/viraj/diskindexer/internal/db"
	"github.com/viraj/diskindexer/internal/indexer"
)

// Schedules run inside `diskindexer serve`: every scheduleTick the scheduler
// starts the runs that are due, as ordinary index jobs. A run whose folder
// isn't available (disk unplugged, folder empty) is skipped, never indexed,
// so a schedule can't empty a collection by itself.

const maxIntervalHours = 24 * 366

// schedulerLocation is the time zone "at" times are in. A var for tests.
var schedulerLocation = time.Local

const interruptedMessage = "The server stopped during this run. Files indexed so far were kept."

// Schedules lists the schedules in every index, with their next run.
func (s *Service) Schedules() ([]Schedule, error) {
	out := []Schedule{}
	for _, p := range s.dbPaths {
		list, err := s.dbs[p].ListSchedules()
		if err != nil {
			return nil, err
		}
		for _, sc := range list {
			out = append(out, scheduleFromDB(p, sc))
		}
	}
	return out, nil
}

// SaveSchedule creates a schedule (id 0) or replaces one's settings.
func (s *Service) SaveSchedule(dbPath string, id int64, req ScheduleRequest) (Schedule, error) {
	dbPath, d, err := s.resolveDB(dbPath)
	if err != nil {
		return Schedule{}, err
	}
	sc, err := validateSchedule(d, req)
	if err != nil {
		return Schedule{}, err
	}
	sc.ID = id
	if id != 0 {
		existing, err := d.GetSchedule(id)
		if err != nil {
			return Schedule{}, err
		}
		if existing == nil {
			return Schedule{}, fmt.Errorf("%w: schedule %d", ErrNotFound, id)
		}
	}
	saved, err := d.SaveSchedule(sc)
	if err != nil {
		if errors.Is(err, db.ErrConflict) {
			return Schedule{}, fmt.Errorf("%w: %v", ErrConflict, err)
		}
		return Schedule{}, err
	}
	return scheduleFromDB(dbPath, saved), nil
}

func (s *Service) DeleteSchedule(dbPath string, id int64) error {
	_, d, err := s.resolveDB(dbPath)
	if err != nil {
		return err
	}
	ok, err := d.DeleteSchedule(id)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("%w: schedule %d", ErrNotFound, id)
	}
	return nil
}

// RunSchedule runs a schedule now, whether or not it is due or enabled. Like
// a scheduled run it is skipped if its folder isn't available; the returned
// schedule says what happened.
func (s *Service) RunSchedule(dbPath string, id int64) (Schedule, error) {
	dbPath, d, err := s.resolveDB(dbPath)
	if err != nil {
		return Schedule{}, err
	}
	sc, err := d.GetSchedule(id)
	if err != nil {
		return Schedule{}, err
	}
	if sc == nil {
		return Schedule{}, fmt.Errorf("%w: schedule %d", ErrNotFound, id)
	}
	if err := s.runSchedule(dbPath, sc, time.Now()); err != nil {
		return Schedule{}, err
	}
	sc, err = d.GetSchedule(id)
	if err != nil {
		return Schedule{}, err
	}
	return scheduleFromDB(dbPath, sc), nil
}

// RunScheduler starts due schedules now and then every tick, until ctx ends.
// Runs the previous server left unfinished are marked interrupted first.
func (s *Service) RunScheduler(ctx context.Context, tick time.Duration) {
	for _, p := range s.dbPaths {
		if err := s.dbs[p].MarkInterruptedSchedules(interruptedMessage); err != nil {
			log.Printf("schedules in %s: %v", p, err)
		}
	}
	t := time.NewTicker(tick)
	defer t.Stop()
	for {
		s.RunDueSchedules(time.Now())
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// RunDueSchedules starts every enabled schedule whose next run is at or
// before now. One that can't start because its index is busy is tried again
// on the next call.
func (s *Service) RunDueSchedules(now time.Time) {
	for _, p := range s.dbPaths {
		list, err := s.dbs[p].ListSchedules()
		if err != nil {
			log.Printf("schedules in %s: %v", p, err)
			continue
		}
		for _, sc := range list {
			if next := nextRun(sc); next == nil || next.After(now) {
				continue
			}
			if err := s.runSchedule(p, sc, now); err != nil && !errors.Is(err, ErrConflict) {
				log.Printf("schedule %d (%s): %v", sc.ID, scheduleTarget(sc), err)
			}
		}
	}
}

// runSchedule starts sc's run, or records why it was skipped. ErrConflict
// means another run is writing to the index, and nothing was recorded.
func (s *Service) runSchedule(dbPath string, sc *db.Schedule, now time.Time) error {
	d := s.dbs[dbPath]
	skip := func(reason string) error {
		return d.RecordScheduleRun(sc.ID, &now, "skipped", reason, "")
	}
	disk, err := d.GetDiskByLabel(sc.Disk)
	if err != nil {
		return err
	}
	if disk == nil {
		return skip(fmt.Sprintf("Disk “%s” isn’t in the index.", sc.Disk))
	}
	req := IndexRequest{DB: dbPath, Disk: sc.Disk}
	path, mountPoint := sc.Path, sc.MountPoint
	if sc.Collection == "" {
		req.MountPath = path
	} else {
		coll, err := d.GetCollectionByLabel(disk.ID, sc.Collection)
		if err != nil {
			return err
		}
		if coll == nil {
			return skip(fmt.Sprintf("Collection “%s” isn’t on “%s” any more.", sc.Collection, sc.Disk))
		}
		if path == "" {
			path = coll.RootPath
		}
		req.Collections = []CollectionSpec{{Label: coll.Label, RootPath: path, KeepRootPath: sc.Path != ""}}
	}
	if err := indexer.CheckAvailable(path, mountPoint); err != nil {
		return skip(availabilityMessage(err))
	}
	job, err := s.startIndex(req, sc.ID, func(j Job) {
		status, message := string(j.State), j.Error
		if j.Stats != nil {
			message = fmt.Sprintf("%d added, %d updated, %d removed", j.Stats.Added, j.Stats.Updated, j.Stats.Deleted)
			if j.Stats.ErrorCount > 0 {
				message += fmt.Sprintf(", %d unreadable", j.Stats.ErrorCount)
			}
		}
		if err := d.RecordScheduleRun(sc.ID, nil, status, message, j.ID); err != nil {
			log.Printf("schedule %d: %v", sc.ID, err)
		}
	})
	if err != nil {
		if errors.Is(err, ErrBadRequest) {
			return skip(strings.TrimPrefix(err.Error(), ErrBadRequest.Error()+": "))
		}
		return err
	}
	return d.RecordScheduleRun(sc.ID, &now, "running", "", job.ID)
}

func availabilityMessage(err error) string {
	msg := strings.TrimPrefix(err.Error(), indexer.ErrUnavailable.Error()+": ")
	return strings.ToUpper(msg[:1]) + msg[1:] + "."
}

func scheduleTarget(sc *db.Schedule) string {
	if sc.Collection == "" {
		return sc.Disk
	}
	return sc.Disk + "/" + sc.Collection
}

// validateSchedule checks req against the index and the filesystem, and
// records where the path's disk is mounted.
func validateSchedule(d *db.DB, req ScheduleRequest) (*db.Schedule, error) {
	sc := &db.Schedule{
		Disk:          strings.TrimSpace(req.Disk),
		Collection:    strings.TrimSpace(req.Collection),
		IntervalHours: req.IntervalHours,
		At:            strings.TrimSpace(req.At),
		Enabled:       req.Enabled,
	}
	if sc.IntervalHours < 1 || sc.IntervalHours > maxIntervalHours {
		return nil, fmt.Errorf("%w: the interval must be between 1 hour and a year", ErrBadRequest)
	}
	if sc.At != "" {
		if _, _, ok := parseClock(sc.At); !ok {
			return nil, fmt.Errorf("%w: time %q must be HH:MM", ErrBadRequest, sc.At)
		}
		if sc.IntervalHours%24 != 0 {
			return nil, fmt.Errorf("%w: a time of day needs an interval of whole days", ErrBadRequest)
		}
	}
	disk, err := d.GetDiskByLabel(sc.Disk)
	if err != nil {
		return nil, err
	}
	if disk == nil {
		return nil, fmt.Errorf("%w: disk %q isn’t in the index", ErrNotFound, sc.Disk)
	}
	path := strings.TrimSpace(req.Path)
	if path != "" {
		if !filepath.IsAbs(path) {
			return nil, fmt.Errorf("%w: path %q must be absolute", ErrBadRequest, path)
		}
		path = filepath.Clean(path)
	}
	sc.Path = path
	if sc.Collection == "" {
		if path == "" {
			return nil, fmt.Errorf("%w: a disk schedule needs the disk’s mount path", ErrBadRequest)
		}
	} else {
		coll, err := d.GetCollectionByLabel(disk.ID, sc.Collection)
		if err != nil {
			return nil, err
		}
		if coll == nil {
			return nil, fmt.Errorf("%w: disk %q has no collection %q", ErrNotFound, sc.Disk, sc.Collection)
		}
		if path == "" {
			path = coll.RootPath
		}
	}
	// The folder has to be there now, to learn which disk it is on; later
	// runs are skipped while that disk isn't mounted.
	if err := indexer.CheckAvailable(path, ""); err != nil {
		return nil, fmt.Errorf("%w: %s Plug the disk in to set up its schedule.", ErrBadRequest, availabilityMessage(err))
	}
	sc.MountPoint = indexer.FindMountPoint(path)
	return sc, nil
}

// nextRun is when sc is next due, or nil while it is disabled. A schedule
// that was due while the server was down is due straight away, once.
func nextRun(sc *db.Schedule) *time.Time {
	if !sc.Enabled {
		return nil
	}
	interval := time.Duration(sc.IntervalHours) * time.Hour
	var next time.Time
	switch {
	case sc.At == "" && sc.LastRunAt == nil:
		next = sc.CreatedAt.Add(interval)
	case sc.At == "":
		next = sc.LastRunAt.Add(interval)
	case sc.LastRunAt == nil:
		next = nextClock(sc.At, sc.CreatedAt)
	default:
		// The slot nearest a full interval after the last run, so a run
		// that started late doesn't push the next one back a day.
		next = nextClock(sc.At, sc.LastRunAt.Add(interval-12*time.Hour))
	}
	return &next
}

// nextClock is the first time at or after t whose local time is at ("HH:MM").
func nextClock(at string, t time.Time) time.Time {
	h, m, _ := parseClock(at)
	local := t.In(schedulerLocation)
	slot := time.Date(local.Year(), local.Month(), local.Day(), h, m, 0, 0, schedulerLocation)
	if slot.Before(t) {
		slot = time.Date(local.Year(), local.Month(), local.Day()+1, h, m, 0, 0, schedulerLocation)
	}
	return slot
}

func parseClock(s string) (int, int, bool) {
	t, err := time.Parse("15:04", s)
	if err != nil {
		return 0, 0, false
	}
	return t.Hour(), t.Minute(), true
}

func scheduleFromDB(dbPath string, sc *db.Schedule) Schedule {
	return Schedule{
		DB: dbPath, ID: sc.ID,
		ScheduleRequest: ScheduleRequest{Disk: sc.Disk, Collection: sc.Collection, Path: sc.Path,
			IntervalHours: sc.IntervalHours, At: sc.At, Enabled: sc.Enabled},
		MountPoint: sc.MountPoint, CreatedAt: sc.CreatedAt, LastRunAt: sc.LastRunAt,
		LastStatus: sc.LastStatus, LastMessage: sc.LastMessage, LastJobID: sc.LastJobID,
		NextRunAt: nextRun(sc),
	}
}
