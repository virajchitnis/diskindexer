package db

import "time"

type Disk struct {
	ID            int64
	Label         string
	Description   string
	CreatedAt     time.Time
	LastIndexedAt *time.Time
	// Excludes are the patterns the disk was last indexed with (beyond the
	// configured defaults), reused when a run doesn't specify any.
	Excludes []string
}

type Collection struct {
	ID            int64
	DiskID        int64
	DiskLabel     string
	Label         string
	RootPath      string
	LastIndexedAt *time.Time
}

type File struct {
	ID           int64
	DiskID       int64
	CollectionID *int64
	Name         string
	Path         string // relative to disk root
	Size         int64
	ModifiedAt   time.Time
	Extension    string
	IsDir        bool
	// populated by joins
	DiskLabel string
	CollLabel string
}
