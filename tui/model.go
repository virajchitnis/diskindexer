package tui

import (
	"fmt"
	"sort"
	"strconv"
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

// ── Sort constants ────────────────────────────────────────────────────────────

type sortMode int

const (
	sortNameAsc  sortMode = iota // NAME ▲
	sortNameDesc                 // NAME ▼
	sortSizeAsc                  // SIZE ▲
	sortSizeDesc                 // SIZE ▼
	sortDateAsc                  // MODIFIED ▲
	sortDateDesc                 // MODIFIED ▼
	sortModeCount
)

func (s sortMode) col() string {
	switch s {
	case sortSizeAsc, sortSizeDesc:
		return "SIZE"
	case sortDateAsc, sortDateDesc:
		return "MODIFIED"
	default:
		return "NAME"
	}
}

func (s sortMode) asc() bool {
	return s == sortNameAsc || s == sortSizeAsc || s == sortDateAsc
}

func (s sortMode) label() string {
	arrow := "▲"
	if !s.asc() {
		arrow = "▼"
	}
	return s.col() + " " + arrow
}

// ── Model ─────────────────────────────────────────────────────────────────────

// Model is the bubbletea model for the interactive search TUI.
type Model struct {
	dbs   []*db.DB
	input textinput.Model

	// filter state
	diskNames   []string            // index 0 is always "(all)"
	diskIdx     int
	collsByDisk map[string][]string // disk label → sorted collection names
	collNames   []string            // current selectable list, index 0 is "(all)"
	collIdx     int
	typeMode    typeMode
	sort        sortMode

	// results
	results []search.Result
	cursor  int              // selected row (absolute index)
	offset  int              // first visible row
	dupeSet map[string]bool  // keys of potential duplicates (name|size)

	// debounce: each search trigger increments searchSeq; stale results are dropped
	searchSeq int

	// window dimensions
	width  int
	height int

	// status bar
	statusMsg string

	// whether search input is focused
	inputFocused bool

	// whether the detail panel is visible
	showDetail bool

	err error
}

// New creates a new TUI Model ready to be passed to bubbletea.
// diskNames should not include the "(all)" entry — it is prepended automatically.
// initialQuery pre-fills the search bar.
// initialDisk pre-selects a disk filter (empty = all).
// collsByDisk maps disk label → sorted collection names (nil = no collection filter).
func New(dbs []*db.DB, initialQuery string, diskNames []string, initialDisk string, collsByDisk map[string][]string) Model {
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

	m := Model{
		dbs:          dbs,
		input:        ti,
		diskNames:    allNames,
		diskIdx:      diskIdx,
		collsByDisk:  collsByDisk,
		inputFocused: true,
	}
	m.collNames = m.buildCollNames()
	return m
}

// buildCollNames returns the selectable collection list for the current disk
// selection: "(all)" + all unique names across all disks when no disk is
// selected, or "(all)" + that disk's collections when a disk is selected.
func (m Model) buildCollNames() []string {
	result := []string{"(all)"}
	if len(m.collsByDisk) == 0 {
		return result
	}
	if m.diskIdx == 0 {
		// All disks: merge and deduplicate collection names.
		seen := make(map[string]struct{})
		var names []string
		for _, colls := range m.collsByDisk {
			for _, c := range colls {
				if _, ok := seen[c]; !ok {
					seen[c] = struct{}{}
					names = append(names, c)
				}
			}
		}
		sort.Strings(names)
		return append(result, names...)
	}
	// Specific disk selected.
	diskName := m.diskNames[m.diskIdx]
	return append(result, m.collsByDisk[diskName]...)
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
		applySortMode(m.results, m.sort)
		m.dupeSet = buildDupeSet(m.results)
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
		m.searchSeq++
		return m, m.execSearch()

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
		m.collIdx = 0
		m.collNames = m.buildCollNames()
		m.searchSeq++
		return m, m.execSearch()

	case "D":
		m.diskIdx--
		if m.diskIdx < 0 {
			m.diskIdx = len(m.diskNames) - 1
		}
		m.collIdx = 0
		m.collNames = m.buildCollNames()
		m.searchSeq++
		return m, m.execSearch()

	case "c":
		if len(m.collNames) > 1 {
			m.collIdx = (m.collIdx + 1) % len(m.collNames)
			m.searchSeq++
			return m, m.execSearch()
		}
		return m, nil

	case "C":
		if len(m.collNames) > 1 {
			m.collIdx--
			if m.collIdx < 0 {
				m.collIdx = len(m.collNames) - 1
			}
			m.searchSeq++
			return m, m.execSearch()
		}
		return m, nil

	case "t":
		m.typeMode = (m.typeMode + 1) % 3
		m.searchSeq++
		return m, m.execSearch()

	case "s":
		m.sort = (m.sort + 1) % sortModeCount
		applySortMode(m.results, m.sort)
		m.cursor = 0
		m.offset = 0
		return m, nil

	case "i":
		m.showDetail = !m.showDetail
		m.clampViewport()
		return m, nil

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
	if m.collIdx > 0 && m.collIdx < len(m.collNames) {
		p.CollLabel = m.collNames[m.collIdx]
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
	// detail panel adds 3 more lines when open
	overhead := 8
	if m.showDetail {
		overhead += 3
	}
	v := m.height - overhead
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

	// Detail panel
	if m.showDetail {
		b.WriteString(m.renderDetail())
	}

	// Status
	b.WriteString(m.renderStatus())

	return b.String()
}

func (m Model) renderFilters() string {
	disk := styles.filterKey.Render("d") +
		styles.label.Render(" Disk: ") +
		styles.filterVal.Render(m.diskNames[m.diskIdx])

	collVal := "(all)"
	if m.collIdx > 0 && m.collIdx < len(m.collNames) {
		collVal = m.collNames[m.collIdx]
	}
	coll := styles.filterKey.Render("c") +
		styles.label.Render(" Coll: ") +
		styles.filterVal.Render(collVal)

	typ := styles.filterKey.Render("t") +
		styles.label.Render(" Type: ") +
		styles.filterVal.Render(m.typeMode.label())

	srt := styles.filterKey.Render("s") +
		styles.label.Render(" Sort: ") +
		styles.filterVal.Render(m.sort.label())

	sep := styles.dim.Render("   ")
	return "  " + disk + sep + coll + sep + typ + sep + srt
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

		line := fmt.Sprintf("  %-*s  %-*s  %-*s  %8s  %10s",
			c.name, truncate(name, c.name),
			c.disk, truncate(f.DiskLabel, c.disk),
			c.coll, truncate(f.CollLabel, c.coll),
			sizeStr,
			f.ModifiedAt.Format("2006-01-02"),
		)

		isDupe := !f.IsDir && m.dupeSet[f.Name+"|"+strconv.FormatInt(f.Size, 10)]
		if i == m.cursor {
			b.WriteString(styles.selected.Width(m.width).Render(line))
		} else if isDupe {
			b.WriteString(styles.dupe.Render(line))
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
	n := len(m.results)
	countStr := fmt.Sprintf(" %d", n)
	suffix := " results"
	if n == 500 {
		countStr = " 500+"
		suffix = " results — refine your search to see more"
	}
	count := styles.count.Render(countStr)

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
		styles.dim.Render("[c]") + " collection" + sep +
		styles.dim.Render("[t]") + " type" + sep +
		styles.dim.Render("[s]") + " sort" + sep +
		styles.dim.Render("[i]") + " detail" + sep +
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

// renderDetail renders the 3-line detail panel for the currently selected entry.
func (m Model) renderDetail() string {
	if len(m.results) == 0 || m.cursor >= len(m.results) {
		return "\n\n\n"
	}
	f := m.results[m.cursor].File

	// Line 1: full path
	line1 := "  " + styles.detailPath.Render(f.Path)

	// Line 2: size, modified, type
	sizeStr := fmt.Sprintf("%s (%s bytes)", formatSize(f.Size), formatCommas(f.Size))
	typ := "File"
	if f.IsDir {
		typ = "Directory"
	} else if f.Extension != "" {
		typ = "File (." + f.Extension + ")"
	}
	line2 := "  " +
		styles.label.Render("Size: ") + sizeStr +
		styles.dim.Render("   ") +
		styles.label.Render("Modified: ") + f.ModifiedAt.Local().Format("2006-01-02 15:04:05") +
		styles.dim.Render("   ") +
		styles.label.Render("Type: ") + typ

	// Line 3: disk and collection
	coll := f.CollLabel
	if coll == "" {
		coll = styles.dim.Render("—")
	}
	line3 := "  " +
		styles.label.Render("Disk: ") + f.DiskLabel +
		styles.dim.Render("   ") +
		styles.label.Render("Collection: ") + coll

	return line1 + "\n" + line2 + "\n" + line3 + "\n"
}

// formatCommas formats an integer with thousands separators.
func formatCommas(n int64) string {
	s := strconv.FormatInt(n, 10)
	if len(s) <= 3 {
		return s
	}
	var b strings.Builder
	rem := len(s) % 3
	b.WriteString(s[:rem])
	for i := rem; i < len(s); i += 3 {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(s[i : i+3])
	}
	return b.String()
}

// buildDupeSet returns a set of "name|size" keys for files that appear more
// than once in results (potential duplicates across any disk or collection).
// Directories are excluded — same-named dirs are common and not meaningful.
func buildDupeSet(results []search.Result) map[string]bool {
	counts := make(map[string]int, len(results))
	for _, r := range results {
		if r.File.IsDir {
			continue
		}
		key := r.File.Name + "|" + strconv.FormatInt(r.File.Size, 10)
		counts[key]++
	}
	dupes := make(map[string]bool)
	for k, n := range counts {
		if n > 1 {
			dupes[k] = true
		}
	}
	return dupes
}

// applySortMode sorts results in-place according to s.
func applySortMode(results []search.Result, s sortMode) {
	sort.SliceStable(results, func(i, j int) bool {
		a, b := results[i].File, results[j].File
		switch s {
		case sortNameDesc:
			return strings.ToLower(a.Name) > strings.ToLower(b.Name)
		case sortSizeAsc:
			return a.Size < b.Size
		case sortSizeDesc:
			return a.Size > b.Size
		case sortDateAsc:
			return a.ModifiedAt.Before(b.ModifiedAt)
		case sortDateDesc:
			return a.ModifiedAt.After(b.ModifiedAt)
		default: // sortNameAsc
			return strings.ToLower(a.Name) < strings.ToLower(b.Name)
		}
	})
}

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
