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
	m := New(nil, query, disks, "", nil)
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
	m := New(nil, "", []string{"WD Red", "Seagate"}, "Seagate", nil)
	m.width = 120
	m.height = 30
	assert.Equal(t, 2, m.diskIdx)
}

func TestNew_InitialDiskNotFound(t *testing.T) {
	m := New(nil, "", []string{"WD Red"}, "Unknown", nil)
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

func TestCollFilter_NilCollsByDiskNoOp(t *testing.T) {
	// When no collections are provided, c/C should be a no-op.
	m := newTestModel("", []string{"WD Red"})
	m.inputFocused = false

	m = sendKey(m, "c")
	assert.Equal(t, 0, m.collIdx)
}

func TestCollFilter_CyclesForward(t *testing.T) {
	collsByDisk := map[string][]string{
		"WD Red": {"Photos", "Videos"},
	}
	m := New(nil, "", []string{"WD Red"}, "", collsByDisk)
	m.width = 120
	m.height = 30
	m.inputFocused = false

	// Select disk first so we get that disk's collections
	m = sendKey(m, "d") // disk → WD Red
	assert.Equal(t, []string{"(all)", "Photos", "Videos"}, m.collNames)

	m = sendKey(m, "c")
	assert.Equal(t, 1, m.collIdx)
	assert.Equal(t, "Photos", m.collNames[m.collIdx])

	m = sendKey(m, "c")
	assert.Equal(t, 2, m.collIdx)
	assert.Equal(t, "Videos", m.collNames[m.collIdx])

	m = sendKey(m, "c") // wraps back to "(all)"
	assert.Equal(t, 0, m.collIdx)
}

func TestCollFilter_CyclesBackward(t *testing.T) {
	collsByDisk := map[string][]string{
		"WD Red": {"Photos", "Videos"},
	}
	m := New(nil, "", []string{"WD Red"}, "", collsByDisk)
	m.width = 120
	m.height = 30
	m.inputFocused = false
	m = sendKey(m, "d") // select WD Red

	m = sendKey(m, "C") // wraps to last
	assert.Equal(t, 2, m.collIdx)
	assert.Equal(t, "Videos", m.collNames[m.collIdx])
}

func TestCollFilter_ResetsWhenDiskChanges(t *testing.T) {
	collsByDisk := map[string][]string{
		"WD Red":  {"Photos", "Videos"},
		"Seagate": {"Archive"},
	}
	m := New(nil, "", []string{"WD Red", "Seagate"}, "", collsByDisk)
	m.width = 120
	m.height = 30
	m.inputFocused = false

	m = sendKey(m, "d") // disk → WD Red
	m = sendKey(m, "c") // coll → Photos
	assert.Equal(t, "Photos", m.collNames[m.collIdx])

	m = sendKey(m, "d") // disk → Seagate → collection must reset
	assert.Equal(t, 0, m.collIdx)
	assert.Equal(t, []string{"(all)", "Archive"}, m.collNames)
}

func TestCollFilter_AllDisksShowsMergedCollections(t *testing.T) {
	collsByDisk := map[string][]string{
		"WD Red":  {"Photos", "Videos"},
		"Seagate": {"Archive", "Photos"}, // "Photos" appears in both
	}
	m := New(nil, "", []string{"WD Red", "Seagate"}, "", collsByDisk)
	m.width = 120
	m.height = 30

	// When disk is "(all)", collection list = deduplicated union, sorted
	assert.Equal(t, []string{"(all)", "Archive", "Photos", "Videos"}, m.collNames)
}

func TestCollFilter_ParamIncludesCollLabel(t *testing.T) {
	collsByDisk := map[string][]string{
		"WD Red": {"Photos"},
	}
	m := New(nil, "", []string{"WD Red"}, "", collsByDisk)
	m.width = 120
	m.height = 30
	m.inputFocused = false
	m = sendKey(m, "d") // select WD Red
	m = sendKey(m, "c") // select Photos

	p := m.BuildParams()
	assert.Equal(t, "Photos", p.CollLabel)
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

// ── Sorting ───────────────────────────────────────────────────────────────────

func TestSort_DefaultIsNameAsc(t *testing.T) {
	m := newTestModel("", nil)
	assert.Equal(t, sortNameAsc, m.sort)
}

func TestSort_CyclesOnSKey(t *testing.T) {
	m := newTestModel("", nil)
	m.inputFocused = false
	m = injectResults(m, []search.Result{
		makeResult("b.jpg", "", "", "b.jpg", 0),
		makeResult("a.jpg", "", "", "a.jpg", 0),
	})

	m = sendKey(m, "s")
	assert.Equal(t, sortNameDesc, m.sort)
	assert.Equal(t, "b.jpg", m.results[0].File.Name) // desc: b before a

	m = sendKey(m, "s")
	assert.Equal(t, sortSizeAsc, m.sort)

	m = sendKey(m, "s")
	assert.Equal(t, sortSizeDesc, m.sort)

	m = sendKey(m, "s")
	assert.Equal(t, sortDateAsc, m.sort)

	m = sendKey(m, "s")
	assert.Equal(t, sortDateDesc, m.sort)

	m = sendKey(m, "s")
	assert.Equal(t, sortNameAsc, m.sort) // wraps back
}

func TestSort_BySize(t *testing.T) {
	m := newTestModel("", nil)
	m.inputFocused = false
	m = injectResults(m, []search.Result{
		makeResult("big.jpg", "", "", "big.jpg", 3000),
		makeResult("small.jpg", "", "", "small.jpg", 100),
		makeResult("mid.jpg", "", "", "mid.jpg", 500),
	})

	// Default is name asc; switch to size asc
	m = sendKey(m, "s") // name desc
	m = sendKey(m, "s") // size asc
	assert.Equal(t, int64(100), m.results[0].File.Size)
	assert.Equal(t, int64(500), m.results[1].File.Size)
	assert.Equal(t, int64(3000), m.results[2].File.Size)

	m = sendKey(m, "s") // size desc
	assert.Equal(t, int64(3000), m.results[0].File.Size)
	assert.Equal(t, int64(100), m.results[2].File.Size)
}

func TestSort_ByDate(t *testing.T) {
	older := search.Result{File: &db.File{Name: "old.jpg", ModifiedAt: time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)}}
	newer := search.Result{File: &db.File{Name: "new.jpg", ModifiedAt: time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)}}

	m := newTestModel("", nil)
	m.inputFocused = false
	m = injectResults(m, []search.Result{newer, older})

	// Advance to date asc
	for i := 0; i < int(sortDateAsc); i++ {
		m = sendKey(m, "s")
	}
	assert.Equal(t, "old.jpg", m.results[0].File.Name)

	m = sendKey(m, "s") // date desc
	assert.Equal(t, "new.jpg", m.results[0].File.Name)
}

func TestSort_ResetsResultsOnNewSearch(t *testing.T) {
	m := newTestModel("", nil)
	m.inputFocused = false

	// Switch to size desc
	m = sendKey(m, "s") // name desc
	m = sendKey(m, "s") // size asc
	m = sendKey(m, "s") // size desc

	// New results should be sorted by the current mode (size desc)
	m = injectResults(m, []search.Result{
		makeResult("small.jpg", "", "", "small.jpg", 100),
		makeResult("big.jpg", "", "", "big.jpg", 3000),
	})
	assert.Equal(t, int64(3000), m.results[0].File.Size)
}

func TestSortModeLabel(t *testing.T) {
	assert.Equal(t, "NAME ▲", sortNameAsc.label())
	assert.Equal(t, "NAME ▼", sortNameDesc.label())
	assert.Equal(t, "SIZE ▲", sortSizeAsc.label())
	assert.Equal(t, "SIZE ▼", sortSizeDesc.label())
	assert.Equal(t, "MODIFIED ▲", sortDateAsc.label())
	assert.Equal(t, "MODIFIED ▼", sortDateDesc.label())
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
	m := New(nil, "", nil, "", nil)
	// Before WindowSizeMsg is received, View should not panic.
	output := m.View()
	assert.Contains(t, output, "Loading")
}

// ── Detail panel ──────────────────────────────────────────────────────────────

func TestDetail_HiddenByDefault(t *testing.T) {
	m := newTestModel("", nil)
	assert.False(t, m.showDetail)
}

func TestDetail_TogglesWithIKey(t *testing.T) {
	m := newTestModel("", nil)
	m.inputFocused = false

	m = sendKey(m, "i")
	assert.True(t, m.showDetail)

	m = sendKey(m, "i")
	assert.False(t, m.showDetail)
}

func TestDetail_ReducesVisibleRows(t *testing.T) {
	m := newTestModel("", nil)
	m.height = 20
	open := m.visibleRows()

	m.showDetail = true
	closed := m.visibleRows()

	assert.Equal(t, 3, open-closed)
}

func TestDetail_ShowsPathAndFields(t *testing.T) {
	m := newTestModel("", nil)
	m.inputFocused = false
	m.showDetail = true
	m = injectResults(m, []search.Result{
		makeResult("beach.jpg", "WD Red", "Vacation", "WD Red/Vacation/beach.jpg", 4*1024*1024),
	})

	output := m.renderDetail()
	assert.Contains(t, output, "WD Red/Vacation/beach.jpg")
	assert.Contains(t, output, "4.0M")
	assert.Contains(t, output, "WD Red")
	assert.Contains(t, output, "Vacation")
	assert.Contains(t, output, ".jpg")
}

func TestDetail_EmptyResultsNoPanic(t *testing.T) {
	m := newTestModel("", nil)
	m.showDetail = true
	// Should not panic with no results.
	output := m.renderDetail()
	assert.NotEmpty(t, output)
}

// ── Duplicate detection ───────────────────────────────────────────────────────

func TestDupes_SameNameAndSize(t *testing.T) {
	results := []search.Result{
		makeResult("photo.jpg", "Disk1", "Coll1", "Disk1/Coll1/photo.jpg", 1024),
		makeResult("photo.jpg", "Disk2", "Coll2", "Disk2/Coll2/photo.jpg", 1024),
		makeResult("other.jpg", "Disk1", "Coll1", "Disk1/Coll1/other.jpg", 2048),
	}
	dupes := buildDupeSet(results)
	assert.True(t, dupes["photo.jpg|1024"])
	assert.False(t, dupes["other.jpg|2048"])
}

func TestDupes_SameNameDifferentSize(t *testing.T) {
	results := []search.Result{
		makeResult("photo.jpg", "Disk1", "Coll1", "Disk1/Coll1/photo.jpg", 1024),
		makeResult("photo.jpg", "Disk2", "Coll2", "Disk2/Coll2/photo.jpg", 9999),
	}
	dupes := buildDupeSet(results)
	assert.Empty(t, dupes) // different sizes → not duplicates
}

func TestDupes_DirsExcluded(t *testing.T) {
	results := []search.Result{
		{File: &db.File{Name: "Photos", IsDir: true, Size: 0}},
		{File: &db.File{Name: "Photos", IsDir: true, Size: 0}},
	}
	dupes := buildDupeSet(results)
	assert.Empty(t, dupes)
}

func TestDupes_PopulatedOnResultsReceived(t *testing.T) {
	m := newTestModel("", nil)
	m = injectResults(m, []search.Result{
		makeResult("a.jpg", "D1", "C1", "D1/C1/a.jpg", 500),
		makeResult("a.jpg", "D2", "C2", "D2/C2/a.jpg", 500),
	})
	assert.True(t, m.dupeSet["a.jpg|500"])
}

func TestFormatCommas(t *testing.T) {
	assert.Equal(t, "0", formatCommas(0))
	assert.Equal(t, "999", formatCommas(999))
	assert.Equal(t, "1,000", formatCommas(1000))
	assert.Equal(t, "1,024", formatCommas(1024))
	assert.Equal(t, "1,048,576", formatCommas(1024*1024))
	assert.Equal(t, "4,404,019", formatCommas(4404019))
}
