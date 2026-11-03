package db

import (
	"database/sql"
	"fmt"
	"time"
)

// Schedule is a periodic reindex of a disk or one of its collections.
type Schedule struct {
	ID int64
	// Disk and Collection are labels; Collection "" means the whole disk.
	Disk       string
	Collection string
	// Path is the disk's mount path, or for a collection the folder to read
	// it from ("" = the collection's saved location).
	Path string
	// MountPoint is the filesystem the path was on when the schedule was
	// saved ("" = the root filesystem). A run is skipped while nothing is
	// mounted there.
	MountPoint    string
	IntervalHours int
	// At is "HH:MM" in the server's local time, for whole-day intervals.
	At          string
	Enabled     bool
	CreatedAt   time.Time
	LastRunAt   *time.Time
	LastStatus  string
	LastMessage string
	LastJobID   string
}

const scheduleColumns = `id, disk, collection, path, mount_point, interval_hours, at, enabled,
	created_at, last_run_at, last_status, last_message, last_job_id`

func (d *DB) ListSchedules() ([]*Schedule, error) {
	rows, err := d.sql.Query(`SELECT ` + scheduleColumns + ` FROM schedules ORDER BY disk, collection`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Schedule
	for rows.Next() {
		sc, err := scanSchedule(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, sc)
	}
	return out, rows.Err()
}

// GetSchedule returns the schedule, or nil if there's none with that ID.
func (d *DB) GetSchedule(id int64) (*Schedule, error) {
	sc, err := scanSchedule(d.sql.QueryRow(`SELECT `+scheduleColumns+` FROM schedules WHERE id = ?`, id))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return sc, err
}

// SaveSchedule inserts sc (ID 0) or updates its settings; the last-run fields
// are only written by RecordScheduleRun. ErrConflict means the disk or
// collection already has a schedule.
func (d *DB) SaveSchedule(sc *Schedule) (*Schedule, error) {
	var err error
	if sc.ID == 0 {
		var res sql.Result
		res, err = d.sql.Exec(`
			INSERT INTO schedules (disk, collection, path, mount_point, interval_hours, at, enabled, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		`, sc.Disk, sc.Collection, sc.Path, sc.MountPoint, sc.IntervalHours, sc.At, boolToInt(sc.Enabled),
			time.Now().UTC().Format(time.RFC3339))
		if err == nil {
			sc.ID, err = res.LastInsertId()
		}
	} else {
		_, err = d.sql.Exec(`
			UPDATE schedules SET disk = ?, collection = ?, path = ?, mount_point = ?, interval_hours = ?, at = ?, enabled = ?
			WHERE id = ?
		`, sc.Disk, sc.Collection, sc.Path, sc.MountPoint, sc.IntervalHours, sc.At, boolToInt(sc.Enabled), sc.ID)
	}
	if err != nil {
		if isUniqueViolation(err) {
			what := fmt.Sprintf("disk %q", sc.Disk)
			if sc.Collection != "" {
				what = fmt.Sprintf("collection %q on disk %q", sc.Collection, sc.Disk)
			}
			return nil, fmt.Errorf("%w: %s already has a schedule", ErrConflict, what)
		}
		return nil, err
	}
	return d.GetSchedule(sc.ID)
}

// DeleteSchedule returns false if there's no schedule with that ID.
func (d *DB) DeleteSchedule(id int64) (bool, error) {
	res, err := d.sql.Exec(`DELETE FROM schedules WHERE id = ?`, id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// RecordScheduleRun stores the outcome of a run. A nil at keeps the time of
// the run (used when a started run finishes).
func (d *DB) RecordScheduleRun(id int64, at *time.Time, status, message, jobID string) error {
	if at != nil {
		_, err := d.sql.Exec(`UPDATE schedules SET last_run_at = ?, last_status = ?, last_message = ?, last_job_id = ? WHERE id = ?`,
			at.UTC().Format(time.RFC3339), status, message, jobID, id)
		return err
	}
	_, err := d.sql.Exec(`UPDATE schedules SET last_status = ?, last_message = ?, last_job_id = ? WHERE id = ?`,
		status, message, jobID, id)
	return err
}

// MarkInterruptedSchedules marks runs recorded as running, left behind by a
// server that stopped during them.
func (d *DB) MarkInterruptedSchedules(message string) error {
	_, err := d.sql.Exec(`UPDATE schedules SET last_status = 'interrupted', last_message = ? WHERE last_status = 'running'`, message)
	return err
}

// The schedule follows its collection or disk (see the schedules table).
const (
	renameScheduleCollection = `UPDATE schedules SET collection = ? WHERE disk = ? AND collection = ?`
	moveScheduleCollection   = `UPDATE schedules SET disk = ? WHERE disk = ? AND collection = ?`
	deleteCollectionSchedule = `DELETE FROM schedules WHERE disk = ? AND collection = ?`
	deleteDiskSchedules      = `DELETE FROM schedules WHERE disk = ?`
)

func scanSchedule(s scanner) (*Schedule, error) {
	sc := &Schedule{}
	var enabled int
	var created string
	var lastRun sql.NullString
	if err := s.Scan(&sc.ID, &sc.Disk, &sc.Collection, &sc.Path, &sc.MountPoint, &sc.IntervalHours, &sc.At, &enabled,
		&created, &lastRun, &sc.LastStatus, &sc.LastMessage, &sc.LastJobID); err != nil {
		return nil, err
	}
	sc.Enabled = enabled != 0
	sc.CreatedAt, _ = time.Parse(time.RFC3339, created)
	if lastRun.Valid {
		t, _ := time.Parse(time.RFC3339, lastRun.String)
		sc.LastRunAt = &t
	}
	return sc, nil
}
