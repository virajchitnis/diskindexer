package tui

import (
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/stretchr/testify/assert"
	"github.com/viraj/diskindexer/internal/db"
	"github.com/viraj/diskindexer/internal/search"
)

// newTestModel creates a model with a fixed window size and no real DBs.
func newTestModel(query string, disks []string) Model {
	m := New(nil, query, disks, "")
	m.width = 120
	m.height = 30
	return m
}

// sendKey sends a single key message through Update and returns the new model.
func sendKey(m Model, key string) Model {
	msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)}
	if key == "enter" {
		msg = tea.KeyMsg{Type: tea.KeyEnter}
	} else if key == "esc" {
		msg = tea.KeyMsg{Type: tea.KeyEsc}
	} else if key == "up" {
		msg = tea.KeyMsg{Type: tea.KeyUp}
	} else if key == "down" {
		msg = tea.KeyMsg{Type: tea.KeyDown}
	} else if key == "tab" {
		msg = tea.KeyMsg{Type: tea.KeyTab}
	} else if key == "pgup" {
		msg = tea.KeyMsg{Type: tea.KeyPgUp}
	} else if key == "pgdown" {
		msg = tea.KeyMsg{Type: tea.KeyPgDown}
	} else if key == "ctrl+c" {
		msg = tea.KeyMsg{Type: tea.KeyCtrlC}
	}
	next, _ := m.Update(msg)
	return next.(Model)
}

// injectResults pushes a searchDoneMsg directly into the model.
func injectResults(m Model, results []search.Result) Model {
	next, _ := m.Update(searchDoneMsg{seq: m.searchSeq, results: results, err: nil})
	return next.(Model)
}

func makeResult(name, diskLabel, collLabel, path string, size int64) search.Result {
	return search.Result{
		File: &db.File{
			Name:       name,
			DiskLabel:  diskLabel,
			CollLabel:  collLabel,
			Path:       path,
			Size:       size,
			ModifiedAt: time.Now(),
		},
	}
}

// ── Initialisation ────────────────────────────────────────────────────────────

func TestNew_InitialState(t *testing.T) {
	m := newTestModel("", []string{"WD Red", "Seagate"})
	assert.Equal(t, []string{"(all)", "WD Red", "Seagate"}, m.diskNames)
	assert.Equal(t, 0, m.diskIdx)
	assert.Equal(t, typeModeAll, m.typeMode)
	assert.True(t, m.inputFocused)
	assert.Empty(t, m.results)
}

func TestNew_InitialQuery(t *testing.T) {
	m := newTestModel("vacation", []string{})
	assert.Equal(t, "vacation", m.input.Value())
}

func TestNew_InitialDisk(t *testing.T) {
	m := New(nil, "", []string{"WD Red", "Seagate"}, "Seagate")
	m.width = 120
	m.height = 30
	assert.Equal(t, 2, m.diskIdx)
}

func TestNew_InitialDiskNotFound(t *testing.T) {
	m := New(nil, "", []string{"WD Red"}, "Unknown")
	assert.Equal(t, 0, m.diskIdx) // falls back to "(all)"
}

// ── Filter cycling ────────────────────────────────────────────────────────────

func TestTypeFilter_Cycles(t *testing.T) {
	m := newTestModel("", nil)
	m.inputFocused = false

	m = sendKey(m, "t")
	assert.Equal(t, typeModeFiles, m.typeMode)

	m = sendKey(m, "t")
	assert.Equal(t, typeModeDirs, m.typeMode)

	m = sendKey(m, "t")
	assert.Equal(t, typeModeAll, m.typeMode)
}

func TestDiskFilter_CyclesForward(t *testing.T) {
	m := newTestModel("", []string{"WD Red", "Seagate"})
	m.inputFocused = false

	m = sendKey(m, "d")
	assert.Equal(t, 1, m.diskIdx)
	assert.Equal(t, "WD Red", m.diskNames[m.diskIdx])

	m = sendKey(m, "d")
	assert.Equal(t, 2, m.diskIdx)

	m = sendKey(m, "d")
	assert.Equal(t, 0, m.diskIdx) // wraps back to "(all)"
}

func TestDiskFilter_CyclesBackward(t *testing.T) {
	m := newTestModel("", []string{"WD Red", "Seagate"})
	m.inputFocused = false

	m = sendKey(m, "D")
	assert.Equal(t, 2, m.diskIdx) // wraps to last
}

// ── Navigation ────────────────────────────────────────────────────────────────

func TestNavigation_DownAndUp(t *testing.T) {
	m := newTestModel("", nil)
	m.inputFocused = false
	m = injectResults(m, []search.Result{
		makeResult("a.jpg", "Disk", "Col", "col/a.jpg", 100),
		makeResult("b.jpg", "Disk", "Col", "col/b.jpg", 200),
		makeResult("c.jpg", "Disk", "Col", "col/c.jpg", 300),
	})

	m = sendKey(m, "down")
	assert.Equal(t, 1, m.cursor)

	m = sendKey(m, "down")
	assert.Equal(t, 2, m.cursor)

	// Can't go past the last result.
	m = sendKey(m, "down")
	assert.Equal(t, 2, m.cursor)

	m = sendKey(m, "up")
	assert.Equal(t, 1, m.cursor)

	m = sendKey(m, "up")
	assert.Equal(t, 0, m.cursor)

	// Can't go above first result.
	m = sendKey(m, "up")
	assert.Equal(t, 0, m.cursor)
}

func TestNavigation_VimKeys(t *testing.T) {
	m := newTestModel("", nil)
	m.inputFocused = false
	m = injectResults(m, []search.Result{
		makeResult("a.jpg", "", "", "a.jpg", 0),
		makeResult("b.jpg", "", "", "b.jpg", 0),
	})

	m = sendKey(m, "j")
	assert.Equal(t, 1, m.cursor)

	m = sendKey(m, "k")
	assert.Equal(t, 0, m.cursor)
}

func TestNavigation_CursorResetsOnNewSearch(t *testing.T) {
	m := newTestModel("", nil)
	m.inputFocused = false
	m = injectResults(m, []search.Result{
		makeResult("a.jpg", "", "", "a.jpg", 0),
		makeResult("b.jpg", "", "", "b.jpg", 0),
	})
	m = sendKey(m, "down")
	assert.Equal(t, 1, m.cursor)

	// New search results reset cursor.
	m = injectResults(m, []search.Result{makeResult("x.jpg", "", "", "x.jpg", 0)})
	assert.Equal(t, 0, m.cursor)
}

// ── Focus switching ───────────────────────────────────────────────────────────

func TestFocus_TabMovesToResults(t *testing.T) {
	m := newTestModel("", nil)
	assert.True(t, m.inputFocused)

	m = sendKey(m, "tab")
	assert.False(t, m.inputFocused)
}

func TestFocus_SlashMovesToSearch(t *testing.T) {
	m := newTestModel("", nil)
	m.inputFocused = false

	m = sendKey(m, "/")
	assert.True(t, m.inputFocused)
}

func TestFocus_EscInResultsMovesToSearch(t *testing.T) {
	m := newTestModel("", nil)
	m.inputFocused = false

	m = sendKey(m, "esc")
	assert.True(t, m.inputFocused)
}

// ── Search params ─────────────────────────────────────────────────────────────

func TestBuildParams_EmptyQuery(t *testing.T) {
	m := newTestModel("", nil)
	p := m.BuildParams()
	assert.Equal(t, "", p.Query)
	assert.Nil(t, p.IsDir)
	assert.Equal(t, "", p.DiskLabel)
	assert.Equal(t, 500, p.Limit)
}

func TestBuildParams_WithQuery(t *testing.T) {
	m := newTestModel("vacation", nil)
	p := m.BuildParams()
	assert.Equal(t, "vacation", p.Query)
}

func TestBuildParams_FilesFilter(t *testing.T) {
	m := newTestModel("", nil)
	m.typeMode = typeModeFiles
	p := m.BuildParams()
	assert.NotNil(t, p.IsDir)
	assert.False(t, *p.IsDir)
}

func TestBuildParams_DirsFilter(t *testing.T) {
	m := newTestModel("", nil)
	m.typeMode = typeModeDirs
	p := m.BuildParams()
	assert.NotNil(t, p.IsDir)
	assert.True(t, *p.IsDir)
}

func TestBuildParams_DiskFilter(t *testing.T) {
	m := newTestModel("", []string{"WD Red"})
	m.diskIdx = 1
	p := m.BuildParams()
	assert.Equal(t, "WD Red", p.DiskLabel)
}

// ── Viewport ──────────────────────────────────────────────────────────────────

func TestViewport_ScrollsDown(t *testing.T) {
	m := newTestModel("", nil)
	m.inputFocused = false
	m.height = 12 // visibleRows = 12 - 8 = 4

	results := make([]search.Result, 10)
	for i := range results {
		results[i] = makeResult("file.jpg", "", "", "file.jpg", 0)
	}
	m = injectResults(m, results)

	// Move cursor past the visible window.
	for i := 0; i < 6; i++ {
		m = sendKey(m, "down")
	}
	assert.Equal(t, 6, m.cursor)
	assert.Greater(t, m.offset, 0) // viewport scrolled
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func TestTruncate(t *testing.T) {
	assert.Equal(t, "hello", truncate("hello", 10))
	assert.Equal(t, "hell…", truncate("hello world", 5))
	assert.Equal(t, "h", truncate("hello", 1))
	assert.Equal(t, "", truncate("hello", 0))
}

func TestFormatSize(t *testing.T) {
	assert.Equal(t, "512B", formatSize(512))
	assert.Equal(t, "1.0K", formatSize(1024))
	assert.Equal(t, "1.0M", formatSize(1024*1024))
	assert.Equal(t, "1.0G", formatSize(1024*1024*1024))
	assert.Equal(t, "1.0T", formatSize(1024*1024*1024*1024))
}

func TestTypeModeLabel(t *testing.T) {
	assert.Equal(t, "All", typeModeAll.label())
	assert.Equal(t, "Files", typeModeFiles.label())
	assert.Equal(t, "Dirs", typeModeDirs.label())
}

// ── View rendering ────────────────────────────────────────────────────────────

func TestView_RendersWithoutPanic(t *testing.T) {
	m := newTestModel("vacation", []string{"WD Red"})
	m = injectResults(m, []search.Result{
		makeResult("beach.jpg", "WD Red", "Vacation", "Vacation/beach.jpg", 4*1024*1024),
	})
	// Should not panic regardless of content.
	output := m.View()
	assert.Contains(t, output, "Disk Indexer")
	assert.Contains(t, output, "beach.jpg")
}

func TestView_EmptyResults(t *testing.T) {
	m := newTestModel("nothinghere", nil)
	output := m.View()
	assert.Contains(t, output, "no results")
}

func TestView_ZeroDimensions(t *testing.T) {
	m := New(nil, "", nil, "")
	// Before WindowSizeMsg is received, View should not panic.
	output := m.View()
	assert.Contains(t, output, "Loading")
}
