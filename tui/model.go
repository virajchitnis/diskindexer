package tui

import (
	"fmt"
	"strings"
	"time"

	"github.com/atotto/clipboard"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/viraj/diskindexer/internal/db"
	"github.com/viraj/diskindexer/internal/search"
)

// ── Message types ─────────────────────────────────────────────────────────────

type searchDoneMsg struct {
	seq     int
	results []search.Result
	err     error
}

type clearStatusMsg struct{}

// debounceTick carries a sequence number so stale ticks are ignored.
type debounceTick struct{ seq int }

// ── Filter constants ──────────────────────────────────────────────────────────

type typeMode int

const (
	typeModeAll typeMode = iota
	typeModeFiles
	typeModeDirs
)

func (t typeMode) label() string {
	switch t {
	case typeModeFiles:
		return "Files"
	case typeModeDirs:
		return "Dirs"
	default:
		return "All"
	}
}

// ── Model ─────────────────────────────────────────────────────────────────────

// Model is the bubbletea model for the interactive search TUI.
type Model struct {
	dbs   []*db.DB
	input textinput.Model

	// filter state
	diskNames []string // index 0 is always "(all)"
	diskIdx   int
	typeMode  typeMode

	// results
	results []search.Result
	cursor  int // selected row (absolute index)
	offset  int // first visible row

	// debounce: each search trigger increments searchSeq; stale results are dropped
	searchSeq int

	// window dimensions
	width  int
	height int

	// status bar
	statusMsg string

	// whether search input is focused
	inputFocused bool

	err error
}

// New creates a new TUI Model ready to be passed to bubbletea.
// diskNames should not include the "(all)" entry — it is prepended automatically.
// initialQuery pre-fills the search bar.
// initialDisk pre-selects a disk filter (empty = all).
func New(dbs []*db.DB, initialQuery string, diskNames []string, initialDisk string) Model {
	ti := textinput.New()
	ti.Placeholder = "search files and folders..."
	ti.SetValue(initialQuery)
	ti.Focus()

	allNames := make([]string, 0, len(diskNames)+1)
	allNames = append(allNames, "(all)")
	allNames = append(allNames, diskNames...)

	diskIdx := 0
	if initialDisk != "" {
		for i, n := range allNames {
			if n == initialDisk {
				diskIdx = i
				break
			}
		}
	}

	return Model{
		dbs:          dbs,
		input:        ti,
		diskNames:    allNames,
		diskIdx:      diskIdx,
		inputFocused: true,
	}
}

// ── Init ──────────────────────────────────────────────────────────────────────

func (m Model) Init() tea.Cmd {
	return tea.Batch(textinput.Blink, m.triggerSearch())
}

// ── Update ────────────────────────────────────────────────────────────────────

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.clampViewport()
		return m, nil

	case debounceTick:
		if msg.seq != m.searchSeq {
			return m, nil // superseded by a newer keystroke
		}
		return m, m.execSearch()

	case searchDoneMsg:
		if msg.seq != m.searchSeq {
			return m, nil // stale result
		}
		m.err = msg.err
		m.results = msg.results
		m.cursor = 0
		m.offset = 0
		return m, nil

	case clearStatusMsg:
		m.statusMsg = ""
		return m, nil

	case tea.KeyMsg:
		if m.inputFocused {
			return m.handleInputKey(msg)
		}
		return m.handleResultsKey(msg)
	}

	return m, nil
}

func (m Model) handleInputKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit

	case "esc":
		if m.input.Value() == "" {
			return m, tea.Quit
		}
		m.input.SetValue("")
		return m, m.triggerSearch()

	case "enter", "down", "tab":
		m.inputFocused = false
		m.input.Blur()
		return m, nil

	default:
		prev := m.input.Value()
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		if m.input.Value() != prev {
			m.searchSeq++
			return m, tea.Batch(cmd, tea.Tick(150*time.Millisecond, func(time.Time) tea.Msg {
				return debounceTick{m.searchSeq}
			}))
		}
		return m, cmd
	}
}

func (m Model) handleResultsKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c", "q":
		return m, tea.Quit

	case "esc", "/":
		m.inputFocused = true
		m.input.Focus()
		return m, textinput.Blink

	case "up", "k":
		if m.cursor > 0 {
			m.cursor--
			m.clampViewport()
		}
		return m, nil

	case "down", "j":
		if m.cursor < len(m.results)-1 {
			m.cursor++
			m.clampViewport()
		}
		return m, nil

	case "pgup":
		m.cursor -= m.visibleRows()
		if m.cursor < 0 {
			m.cursor = 0
		}
		m.clampViewport()
		return m, nil

	case "pgdown":
		m.cursor += m.visibleRows()
		if m.cursor >= len(m.results) && len(m.results) > 0 {
			m.cursor = len(m.results) - 1
		}
		m.clampViewport()
		return m, nil

	case "d":
		m.diskIdx = (m.diskIdx + 1) % len(m.diskNames)
		return m, m.triggerSearch()

	case "D":
		m.diskIdx--
		if m.diskIdx < 0 {
			m.diskIdx = len(m.diskNames) - 1
		}
		return m, m.triggerSearch()

	case "t":
		m.typeMode = (m.typeMode + 1) % 3
		return m, m.triggerSearch()

	case "enter":
		if len(m.results) == 0 || m.cursor >= len(m.results) {
			return m, nil
		}
		path := m.results[m.cursor].File.Path
		if err := clipboard.WriteAll(path); err == nil {
			m.statusMsg = "✓ copied to clipboard"
		} else {
			m.statusMsg = "path: " + path
		}
		return m, tea.Tick(3*time.Second, func(time.Time) tea.Msg {
			return clearStatusMsg{}
		})
	}

	return m, nil
}

// ── Search ────────────────────────────────────────────────────────────────────

// triggerSearch increments the sequence counter and schedules a debounced search.
func (m Model) triggerSearch() tea.Cmd {
	m.searchSeq++
	seq := m.searchSeq
	return tea.Tick(150*time.Millisecond, func(time.Time) tea.Msg {
		return debounceTick{seq}
	})
}

// execSearch runs the search synchronously inside a tea.Cmd (goroutine).
func (m Model) execSearch() tea.Cmd {
	seq := m.searchSeq
	dbs := m.dbs
	params := m.buildParams()
	return func() tea.Msg {
		results, err := search.Across(dbs, params)
		return searchDoneMsg{seq, results, err}
	}
}

// BuildParams is exported so tests can inspect it without a running program.
func (m Model) BuildParams() db.SearchParams {
	return m.buildParams()
}

func (m Model) buildParams() db.SearchParams {
	p := db.SearchParams{
		Query: m.input.Value(),
		Limit: 500,
	}
	if m.diskIdx > 0 && m.diskIdx < len(m.diskNames) {
		p.DiskLabel = m.diskNames[m.diskIdx]
	}
	switch m.typeMode {
	case typeModeFiles:
		f := false
		p.IsDir = &f
	case typeModeDirs:
		t := true
		p.IsDir = &t
	}
	return p
}

// ── Viewport ──────────────────────────────────────────────────────────────────

func (m *Model) clampViewport() {
	rows := m.visibleRows()
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+rows {
		m.offset = m.cursor - rows + 1
	}
	if m.offset < 0 {
		m.offset = 0
	}
}

// visibleRows returns how many result rows fit in the current terminal.
func (m Model) visibleRows() int {
	// overhead: title(1) + search(1) + filters(1) + divider(1) + header(1) + divider(1) + status(2) = 8
	v := m.height - 8
	if v < 1 {
		return 1
	}
	return v
}

// ── View ──────────────────────────────────────────────────────────────────────

func (m Model) View() string {
	if m.width == 0 {
		return "Loading…\n"
	}

	var b strings.Builder

	// Title
	b.WriteString(styles.title.Render(" Disk Indexer"))
	b.WriteByte('\n')

	// Search bar
	b.WriteString(styles.label.Render(" Search: "))
	b.WriteString(m.input.View())
	b.WriteByte('\n')

	// Filters
	b.WriteString(m.renderFilters())
	b.WriteByte('\n')

	// Divider
	b.WriteString(styles.divider.Render(strings.Repeat("─", m.width)))
	b.WriteByte('\n')

	// Column headers
	b.WriteString(m.renderHeaders())
	b.WriteByte('\n')

	// Results
	b.WriteString(m.renderResults())

	// Divider
	b.WriteString(styles.divider.Render(strings.Repeat("─", m.width)))
	b.WriteByte('\n')

	// Status
	b.WriteString(m.renderStatus())

	return b.String()
}

func (m Model) renderFilters() string {
	disk := styles.filterKey.Render("d") +
		styles.label.Render(" Disk: ") +
		styles.filterVal.Render(m.diskNames[m.diskIdx])

	typ := styles.filterKey.Render("t") +
		styles.label.Render(" Type: ") +
		styles.filterVal.Render(m.typeMode.label())

	return "  " + disk + styles.dim.Render("   ") + typ
}

func (m Model) renderHeaders() string {
	c := m.colWidths()
	row := fmt.Sprintf("  %-*s  %-*s  %-*s  %8s  %10s",
		c.name, "NAME",
		c.disk, "DISK",
		c.coll, "COLLECTION",
		"SIZE",
		"MODIFIED",
	)
	return styles.colHeader.Render(row)
}

func (m Model) renderResults() string {
	if m.err != nil {
		return styles.errStyle.Render("  error: "+m.err.Error()) + "\n"
	}

	rows := m.visibleRows()

	if len(m.results) == 0 {
		empty := styles.dim.Render("  no results")
		// Pad so the layout height stays stable.
		var b strings.Builder
		b.WriteString(empty)
		b.WriteByte('\n')
		for i := 1; i < rows; i++ {
			b.WriteByte('\n')
		}
		return b.String()
	}

	c := m.colWidths()
	end := m.offset + rows
	if end > len(m.results) {
		end = len(m.results)
	}

	var b strings.Builder
	for i := m.offset; i < end; i++ {
		r := m.results[i]
		f := r.File

		name := f.Name
		if f.IsDir {
			name += "/"
		}

		sizeStr := formatSize(f.Size)
		if f.IsDir {
			sizeStr = "—"
		}

		line := fmt.Sprintf("  %-*s  %-*s  %-*s  %8s  %10s",
			c.name, truncate(name, c.name),
			c.disk, truncate(f.DiskLabel, c.disk),
			c.coll, truncate(f.CollLabel, c.coll),
			sizeStr,
			f.ModifiedAt.Format("2006-01-02"),
		)

		if i == m.cursor {
			b.WriteString(styles.selected.Width(m.width).Render(line))
		} else {
			b.WriteString(line)
		}
		b.WriteByte('\n')
	}

	// Pad remaining rows to keep layout stable.
	for i := end - m.offset; i < rows; i++ {
		b.WriteByte('\n')
	}

	return b.String()
}

func (m Model) renderStatus() string {
	// Line 1: result count + path/status message
	count := styles.count.Render(fmt.Sprintf(" %d", len(m.results)))
	suffix := " results"
	if len(m.results) == 500 {
		suffix += styles.dim.Render(" (limit reached — refine your query)")
	}

	var detail string
	if m.statusMsg != "" {
		detail = "   " + styles.statusMsg.Render(m.statusMsg)
	} else if len(m.results) > 0 && m.cursor < len(m.results) {
		detail = styles.dim.Render("   " + m.results[m.cursor].File.Path)
	}

	line1 := count + suffix + detail

	// Line 2: key hints
	sep := styles.dim.Render(" · ")
	hints := styles.dim.Render(" ") +
		styles.dim.Render("[↑↓/jk]") + " navigate" + sep +
		styles.dim.Render("[enter]") + " copy path" + sep +
		styles.dim.Render("[/]") + " search" + sep +
		styles.dim.Render("[d]") + " disk" + sep +
		styles.dim.Render("[t]") + " type" + sep +
		styles.dim.Render("[q]") + " quit"

	return line1 + "\n" + hints + "\n"
}

// ── Column widths ─────────────────────────────────────────────────────────────

type colWidths struct {
	name, disk, coll int
}

func (m Model) colWidths() colWidths {
	// Fixed columns: size(8) + date(10) + separators("  " × 4) + indent("  ") = 28
	const fixed = 8 + 10 + 2*4 + 2
	flex := m.width - fixed
	if flex < 42 {
		flex = 42
	}
	nameW := flex * 40 / 100
	diskW := flex * 28 / 100
	collW := flex - nameW - diskW
	if nameW < 14 {
		nameW = 14
	}
	if diskW < 10 {
		diskW = 10
	}
	if collW < 8 {
		collW = 8
	}
	return colWidths{nameW, diskW, collW}
}

// ── String helpers ────────────────────────────────────────────────────────────

// truncate shortens s to w runes, appending "…" if truncated.
func truncate(s string, w int) string {
	if w <= 0 {
		return ""
	}
	runes := []rune(s)
	if len(runes) <= w {
		return s
	}
	if w <= 1 {
		return string(runes[:w])
	}
	return string(runes[:w-1]) + "…"
}

// formatSize returns a short human-readable size for the results table.
func formatSize(bytes int64) string {
	const (
		kb = 1 << 10
		mb = 1 << 20
		gb = 1 << 30
		tb = 1 << 40
	)
	switch {
	case bytes >= tb:
		return fmt.Sprintf("%.1fT", float64(bytes)/tb)
	case bytes >= gb:
		return fmt.Sprintf("%.1fG", float64(bytes)/gb)
	case bytes >= mb:
		return fmt.Sprintf("%.1fM", float64(bytes)/mb)
	case bytes >= kb:
		return fmt.Sprintf("%.1fK", float64(bytes)/kb)
	default:
		return fmt.Sprintf("%dB", bytes)
	}
}
