package cmd

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/stretchr/testify/assert"
	"github.com/viraj/diskindexer/internal/indexer"
)

func TestFormatRateAndETA(t *testing.T) {
	assert.Equal(t, "", formatRate(10, 500*time.Millisecond), "under a second is too early")
	assert.Equal(t, "", formatRate(0, time.Minute))
	assert.Equal(t, "50 files/s", formatRate(100, 2*time.Second))
	assert.Equal(t, "2.5k files/s", formatRate(5000, 2*time.Second))

	assert.Equal(t, "", formatETA(10, 0, time.Minute), "unknown total")
	assert.Equal(t, "", formatETA(100, 100, time.Minute), "already done")
	assert.Equal(t, "~10s remaining", formatETA(50, 100, 10*time.Second))
	assert.Equal(t, "~2m remaining", formatETA(50, 100, 2*time.Minute))
	assert.Equal(t, "~1m30s remaining", formatETA(40, 100, time.Minute))
}

func TestPhaseLabels(t *testing.T) {
	for phase, want := range map[string]string{
		"loading":  "Loading existing index…",
		"clearing": "Clearing existing index…",
		"root":     "Indexing files at the top of the disk…",
		"deleting": "Removing files no longer on disk…",
		"sizes":    "Computing directory sizes…",
		"indexing": "Indexing",
	} {
		assert.Equal(t, want, phaseLabel(phase), phase)
	}
}

func TestProgressModelViews(t *testing.T) {
	m := newProgressModel("Disk One")
	assert.NotNil(t, m.Init())
	m.startTime = time.Now().Add(-10 * time.Second)

	step := func(u indexer.ProgressUpdate) progressModel {
		next, _ := m.Update(progressUpdateMsg(u))
		return next.(progressModel)
	}

	m = step(indexer.ProgressUpdate{Phase: "loading"})
	assert.Contains(t, m.View(), "Loading existing index")

	m = step(indexer.ProgressUpdate{Phase: "indexing", Collection: "Photos", Added: 40, Skipped: 10, Total: 100, Errors: 2})
	v := m.View()
	assert.Contains(t, v, "Photos")
	assert.Contains(t, v, "[50%]")
	assert.Contains(t, v, "files/s")
	assert.Contains(t, v, "remaining")
	assert.Contains(t, v, "2 unreadable")

	m = step(indexer.ProgressUpdate{Phase: "deleting", Deleting: 7})
	assert.Contains(t, m.View(), "7")

	m = step(indexer.ProgressUpdate{Phase: "sizes"})
	assert.Contains(t, m.View(), "scanning")
	m = step(indexer.ProgressUpdate{Phase: "sizes", DirsTotal: 4, DirsDone: 1})
	assert.Contains(t, m.View(), "[25%]")

	// Spinner ticks are passed through.
	next, cmd := m.Update(spinner.TickMsg{})
	assert.NotNil(t, next)
	_ = cmd

	// Finished with unreadable paths.
	stats := &indexer.Stats{Added: 3, Updated: 1, Deleted: 2, Skipped: 5, Elapsed: time.Second,
		ErrorCount: 3, Errors: []indexer.PathError{{Path: "/m/a", Err: "permission denied"}}}
	next, _ = m.Update(progressDoneMsg{stats: stats})
	done := next.(progressModel)
	v = done.View()
	assert.Contains(t, v, "indexed in")
	assert.Contains(t, v, "Deleted:")
	assert.Contains(t, v, "Couldn't read 3 paths")
	assert.Contains(t, v, "/m/a: permission denied")
	assert.Contains(t, v, "… and 2 more")

	next, _ = m.Update(progressDoneMsg{err: errors.New("boom")})
	assert.Contains(t, next.(progressModel).View(), "indexing failed")

	// Unknown messages are ignored.
	next, _ = m.Update(fmt.Errorf("unrelated"))
	assert.Equal(t, m.diskLabel, next.(progressModel).diskLabel)
}

func TestFormatPathErrors(t *testing.T) {
	plain := func(s string) string { return s }
	assert.Equal(t, "", formatPathErrors(nil, plain))
	assert.Equal(t, "", formatPathErrors(&indexer.Stats{}, plain))
	one := formatPathErrors(&indexer.Stats{ErrorCount: 1, Errors: []indexer.PathError{{Path: "/x", Err: "e"}}}, plain)
	assert.Contains(t, one, "Couldn't read 1 path;")
	assert.Contains(t, one, "/x: e")
}
