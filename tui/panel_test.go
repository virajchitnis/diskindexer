package tui

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/viraj/diskindexer/internal/db"
	"github.com/viraj/diskindexer/internal/search"
)

// press sends a key of any type through Update.
func press(m Model, k tea.KeyType) Model {
	next, _ := m.Update(tea.KeyMsg{Type: k})
	return next.(Model)
}

func panelModel() Model {
	m := New(nil, "", []string{"Disk A", "Disk B"}, "", map[string][]string{
		"Disk A": {"Movies", "Photos"},
		"Disk B": {"Backup"},
	})
	m.width, m.height = 120, 30
	return m
}

func nodeAt(m Model) panelNode { return m.buildPanelNodes()[m.panelCursor] }

func TestPanel_OpenNavigateAndApply(t *testing.T) {
	m := panelModel()
	m = sendKey(m, "tab") // focus results so b toggles the panel
	m = sendKey(m, "b")
	require.True(t, m.showPanel)
	require.True(t, m.panelFocused)
	// All disks start expanded: (all), A, Movies, Photos, B, Backup.
	assert.Len(t, m.buildPanelNodes(), 6)
	assert.True(t, nodeAt(m).isAll)

	m = sendKey(m, "down")
	m = sendKey(m, "j")
	assert.Equal(t, "Movies", nodeAt(m).collLabel)

	// Enter applies the collection as the filter and keeps the panel open.
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(Model)
	assert.NotNil(t, cmd)
	p := m.BuildParams()
	assert.Equal(t, "Disk A", p.DiskLabel)
	assert.Equal(t, "Movies", p.CollLabel)
	assert.True(t, m.showPanel)

	// Left on a collection collapses its disk and moves to it.
	m = press(m, tea.KeyLeft)
	assert.Equal(t, "Disk A", nodeAt(m).diskLabel)
	assert.Equal(t, "", nodeAt(m).collLabel)
	assert.Len(t, m.buildPanelNodes(), 4)

	// Right expands it again; Space applies the disk node.
	m = press(m, tea.KeyRight)
	assert.Len(t, m.buildPanelNodes(), 6)
	m = press(m, tea.KeySpace)
	assert.Equal(t, "Disk A", m.BuildParams().DiskLabel)
	assert.Equal(t, "", m.BuildParams().CollLabel)

	// Left on a disk collapses it.
	m = press(m, tea.KeyLeft)
	assert.Len(t, m.buildPanelNodes(), 4)

	// Up to (all) and apply clears the filters.
	m = sendKey(m, "up")
	m = sendKey(m, "k")
	m = sendKey(m, "k")
	assert.True(t, nodeAt(m).isAll)
	m = sendKey(m, "enter")
	assert.Equal(t, "", m.BuildParams().DiskLabel)

	// Esc returns focus to the search bar but leaves the panel visible.
	m = sendKey(m, "esc")
	assert.True(t, m.showPanel)
	assert.False(t, m.panelFocused)
	assert.True(t, m.inputFocused)
}

func TestPanel_ReopenFocusesActiveFilterAndBCloses(t *testing.T) {
	m := panelModel()
	m = sendKey(m, "tab")
	m = sendKey(m, "d") // Disk A
	m = sendKey(m, "c") // first collection
	m = sendKey(m, "b")
	n := nodeAt(m)
	assert.Equal(t, "Disk A", n.diskLabel)
	assert.Equal(t, "Movies", n.collLabel)

	// b while the panel is focused closes it entirely.
	m = sendKey(m, "b")
	assert.False(t, m.showPanel)
	assert.True(t, m.inputFocused)

	// Ctrl+C from the panel quits.
	m = sendKey(m, "tab")
	m = sendKey(m, "b")
	_, cmd := m.Update(tea.KeyMsg{Type: tea.KeyCtrlC})
	assert.NotNil(t, cmd)
}

func TestPanel_ScrollsWithShortTerminal(t *testing.T) {
	m := panelModel()
	m.height = 4 // two node rows visible
	m = sendKey(m, "tab")
	m = sendKey(m, "b")
	for i := 0; i < 10; i++ {
		m = sendKey(m, "down")
	}
	assert.Equal(t, 5, m.panelCursor, "clamped to the last node")
	assert.Equal(t, 4, m.panelOffset)

	m.height = 1
	assert.Equal(t, 1, m.visiblePanelRows())
}

func TestView_WithPanelAndDetail(t *testing.T) {
	m := panelModel()
	m = injectResults(m, []search.Result{
		makeResult("beach.jpg", "Disk A", "Photos", "Disk A/Photos/beach.jpg", 2048),
		makeResult("beach.jpg", "Disk B", "Backup", "Disk B/Backup/beach.jpg", 2048),
	})
	m = sendKey(m, "tab")
	m = sendKey(m, "i")
	m = sendKey(m, "b")
	v := m.View()
	assert.Contains(t, v, "Disk A")
	assert.Contains(t, v, "Backup")
	assert.Contains(t, v, "beach.jpg")
	assert.Contains(t, v, "2,048")

	m.width = 0
	assert.Equal(t, "Loading…\n", m.View())
}

func TestUpdate_Messages(t *testing.T) {
	m := newTestModel("", []string{"A"})

	next, _ := m.Update(tea.WindowSizeMsg{Width: 80, Height: 20})
	m = next.(Model)
	assert.Equal(t, 80, m.width)

	// Spinner ticks only matter while searching.
	_, cmd := m.Update(spinner.TickMsg{})
	assert.Nil(t, cmd)
	m.searching = true
	_, cmd = m.Update(spinner.TickMsg{})
	assert.NotNil(t, cmd)

	// A debounce tick from an older keystroke is ignored.
	_, cmd = m.Update(debounceTick{seq: m.searchSeq + 5})
	assert.Nil(t, cmd)
	_, cmd = m.Update(debounceTick{seq: m.searchSeq})
	assert.NotNil(t, cmd)

	// Stale search results are dropped.
	next, _ = m.Update(searchDoneMsg{seq: m.searchSeq - 1, results: []search.Result{makeResult("x", "A", "", "A/x", 1)}})
	assert.Empty(t, next.(Model).results)

	m.statusMsg = "copied"
	next, _ = m.Update(clearStatusMsg{})
	assert.Equal(t, "", next.(Model).statusMsg)

	assert.NotNil(t, m.Init())
}

func TestInputKeys(t *testing.T) {
	m := newTestModel("", []string{"A"})

	// Typing schedules a debounced search.
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("x")})
	m = next.(Model)
	assert.NotNil(t, cmd)
	assert.Equal(t, "x", m.input.Value())

	// Esc clears a non-empty query, then quits when empty.
	m = sendKey(m, "esc")
	assert.Equal(t, "", m.input.Value())
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	assert.NotNil(t, cmd)

	// Ctrl+C quits.
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyCtrlC})
	assert.NotNil(t, cmd)

	// Keys that don't change the text don't search.
	_, cmd = m.Update(tea.KeyMsg{Type: tea.KeyLeft})
	_ = cmd
}

func TestResultsKeys_ReverseCyclingAndPaging(t *testing.T) {
	m := panelModel()
	var rs []search.Result
	for i := 0; i < 40; i++ {
		rs = append(rs, makeResult("f.txt", "Disk A", "Photos", "Disk A/Photos/f.txt", int64(i)))
	}
	m = injectResults(m, rs)
	m = sendKey(m, "tab")

	m = sendKey(m, "D") // wraps to the last disk
	assert.Equal(t, "Disk B", m.BuildParams().DiskLabel)
	m = sendKey(m, "C") // wraps to the last collection of Disk B
	assert.Equal(t, "Backup", m.BuildParams().CollLabel)
	m = sendKey(m, "C") // back to (all)
	assert.Equal(t, "", m.BuildParams().CollLabel)

	m = injectResults(m, rs)
	m = sendKey(m, "pgdown")
	m = sendKey(m, "pgdown")
	m = sendKey(m, "pgdown")
	assert.Equal(t, 39, m.cursor)
	m = sendKey(m, "pgup")
	m = sendKey(m, "pgup")
	m = sendKey(m, "pgup")
	assert.Equal(t, 0, m.cursor)

	// Collection cycling does nothing on a disk without collections.
	m2 := New(nil, "", []string{"Solo"}, "", nil)
	m2 = sendKey(m2, "tab")
	m2 = sendKey(m2, "d")
	_, cmd := m2.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("c")})
	assert.Nil(t, cmd)
	_, cmd = m2.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("C")})
	assert.Nil(t, cmd)
}

// The search command runs against real indexes.
func TestExecSearchAgainstRealDB(t *testing.T) {
	d, err := db.Open(filepath.Join(t.TempDir(), "t.diskindex"))
	require.NoError(t, err)
	defer d.Close()
	disk, err := d.UpsertDisk("Disk A", "")
	require.NoError(t, err)
	require.NoError(t, d.UpsertFile(&db.File{DiskID: disk.ID, Name: "beach.jpg", Path: "Disk A/beach.jpg", Size: 3, ModifiedAt: time.Now()}))

	m := New([]*db.DB{d}, "beach", []string{"Disk A"}, "", nil)
	msg := m.execSearch()()
	done, ok := msg.(searchDoneMsg)
	require.True(t, ok)
	require.NoError(t, done.err)
	require.Len(t, done.results, 1)
	assert.True(t, strings.HasSuffix(done.results[0].File.Path, "beach.jpg"))

	assert.NotNil(t, m.triggerSearch())
}
