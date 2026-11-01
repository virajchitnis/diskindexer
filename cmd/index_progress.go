package cmd

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/viraj/diskindexer/internal/indexer"
)

// formatRate returns a human-readable files/sec rate, or "" if not yet
// calculable (less than one second elapsed).
func formatRate(processed int, elapsed time.Duration) string {
	if elapsed < time.Second || processed == 0 {
		return ""
	}
	rate := float64(processed) / elapsed.Seconds()
	if rate >= 1000 {
		return fmt.Sprintf("%.1fk files/s", rate/1000)
	}
	return fmt.Sprintf("%.0f files/s", rate)
}

// formatETA returns "~Xm Ys remaining" or "" when not calculable.
func formatETA(processed, total int, elapsed time.Duration) string {
	if total <= 0 || processed <= 0 || processed >= total || elapsed < time.Second {
		return ""
	}
	rate := float64(processed) / elapsed.Seconds()
	if rate <= 0 {
		return ""
	}
	remaining := time.Duration(float64(total-processed)/rate) * time.Second
	remaining = remaining.Round(time.Second)
	if remaining < time.Minute {
		return fmt.Sprintf("~%ds remaining", int(remaining.Seconds()))
	}
	mins := int(remaining.Minutes())
	secs := int(remaining.Seconds()) % 60
	if secs == 0 {
		return fmt.Sprintf("~%dm remaining", mins)
	}
	return fmt.Sprintf("~%dm%ds remaining", mins, secs)
}

// ── Message types ─────────────────────────────────────────────────────────────

type progressUpdateMsg indexer.ProgressUpdate

type progressDoneMsg struct {
	stats *indexer.Stats
	err   error
}

// ── Styles ────────────────────────────────────────────────────────────────────

var (
	pBold  = lipgloss.NewStyle().Bold(true)
	pLabel = lipgloss.NewStyle().Foreground(lipgloss.AdaptiveColor{Light: "#666666", Dark: "#888888"})
	pOK    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.AdaptiveColor{Light: "#007700", Dark: "#88dd88"})
	pFail  = lipgloss.NewStyle().Foreground(lipgloss.AdaptiveColor{Light: "#cc0000", Dark: "#ff6666"})
	pNum   = lipgloss.NewStyle().Bold(true)
	pSpin  = lipgloss.NewStyle().Foreground(lipgloss.AdaptiveColor{Light: "#0066cc", Dark: "#7dcfff"})
)

// ── Model ─────────────────────────────────────────────────────────────────────

type progressModel struct {
	spinner   spinner.Model
	diskLabel string
	update    indexer.ProgressUpdate
	startTime time.Time
	done      bool
	stats     *indexer.Stats
	err       error
}

func newProgressModel(diskLabel string) progressModel {
	s := spinner.New()
	s.Spinner = spinner.Dot
	s.Style = pSpin
	return progressModel{
		spinner:   s,
		diskLabel: diskLabel,
		startTime: time.Now(),
	}
}

func (m progressModel) Init() tea.Cmd {
	return m.spinner.Tick
}

func (m progressModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd

	case progressUpdateMsg:
		m.update = indexer.ProgressUpdate(msg)
		return m, nil

	case progressDoneMsg:
		m.done = true
		m.stats = msg.stats
		m.err = msg.err
		return m, tea.Quit
	}
	return m, nil
}

func (m progressModel) View() string {
	var b strings.Builder

	if m.done {
		if m.err != nil {
			b.WriteString(pFail.Render("✗") + "  " + pBold.Render(m.diskLabel) +
				pLabel.Render("  indexing failed"))
			b.WriteByte('\n')
			return b.String()
		}
		elapsed := m.stats.Elapsed.Round(time.Millisecond)
		b.WriteString(pOK.Render("✓") + "  " + pBold.Render(m.diskLabel) +
			pLabel.Render("  indexed in ") + elapsed.String())
		b.WriteByte('\n')
		b.WriteString("   " +
			pLabel.Render("Added: ") + pNum.Render(fmt.Sprintf("%d", m.stats.Added)) + "  " +
			pLabel.Render("Updated: ") + pNum.Render(fmt.Sprintf("%d", m.stats.Updated)) + "  " +
			pLabel.Render("Deleted: ") + pNum.Render(fmt.Sprintf("%d", m.stats.Deleted)) + "  " +
			pLabel.Render("Unchanged: ") + pNum.Render(fmt.Sprintf("%d", m.stats.Skipped)))
		b.WriteByte('\n')
		b.WriteString(formatPathErrors(m.stats, func(s string) string { return pFail.Render(s) }))
		return b.String()
	}

	elapsed := time.Since(m.startTime).Round(time.Second)

	// Phase label
	phaseStr := phaseLabel(m.update.Phase)

	// Line 1: spinner + disk label + phase
	b.WriteString(m.spinner.View() + "  " + pBold.Render(m.diskLabel) +
		"  " + pLabel.Render(phaseStr))
	b.WriteByte('\n')

	// Line 2: current collection
	coll := m.update.Collection
	if coll == "" {
		coll = pLabel.Render("—")
	}
	b.WriteString("   " + pLabel.Render("Collection: ") + coll)
	b.WriteByte('\n')

	// Line 3: phase-specific progress details
	switch m.update.Phase {
	case "loading", "clearing", "root":
		b.WriteString("   " + pLabel.Render("Elapsed: ") + elapsed.String())
	case "deleting":
		b.WriteString("   " + pNum.Render(fmt.Sprintf("%d", m.update.Deleting)) +
			pLabel.Render(" files no longer on disk  Elapsed: ") + elapsed.String())
	case "sizes":
		dirsTotal := m.update.DirsTotal
		dirsDone := m.update.DirsDone
		if dirsTotal > 0 {
			pct := 100 * dirsDone / dirsTotal
			b.WriteString("   " +
				pNum.Render(fmt.Sprintf("%d", dirsDone)) +
				pLabel.Render(" / ") +
				pNum.Render(fmt.Sprintf("%d", dirsTotal)) +
				pLabel.Render(" directories  ") +
				pLabel.Render(fmt.Sprintf("[%d%%]", pct)) +
				pLabel.Render("  Elapsed: ") + elapsed.String())
		} else {
			b.WriteString("   " + pLabel.Render("scanning…  Elapsed: ") + elapsed.String())
		}
	default:
		// Indexing / clearing phase.
		processed := m.update.Added + m.update.Updated + m.update.Skipped
		total := m.update.Total

		var parts []string
		// Counts
		parts = append(parts,
			pLabel.Render("Added: ")+pNum.Render(fmt.Sprintf("%d", m.update.Added))+"  "+
				pLabel.Render("Updated: ")+pNum.Render(fmt.Sprintf("%d", m.update.Updated))+"  "+
				pLabel.Render("Unchanged: ")+pNum.Render(fmt.Sprintf("%d", m.update.Skipped)))
		// Percentage (only when total is known and we haven't exceeded it)
		if total > 0 && processed <= total {
			pct := 100 * processed / total
			parts = append(parts, pLabel.Render(fmt.Sprintf("[%d%%]", pct)))
		}
		// Rate
		if r := formatRate(processed, elapsed); r != "" {
			parts = append(parts, pLabel.Render(r))
		}
		// ETA
		if eta := formatETA(processed, total, elapsed); eta != "" {
			parts = append(parts, pLabel.Render(eta))
		}
		// Elapsed
		parts = append(parts, pLabel.Render("Elapsed: ")+elapsed.String())

		b.WriteString("   " + strings.Join(parts, pLabel.Render("  ")))
	}
	b.WriteByte('\n')
	if m.update.Errors > 0 {
		b.WriteString("   " + pFail.Render(fmt.Sprintf("%d unreadable (listed when done)", m.update.Errors)) + "\n")
	}

	return b.String()
}

func phaseLabel(phase string) string {
	switch phase {
	case "loading":
		return "Loading existing index…"
	case "clearing":
		return "Clearing existing index…"
	case "root":
		return "Indexing files at the top of the disk…"
	case "deleting":
		return "Removing files no longer on disk…"
	case "sizes":
		return "Computing directory sizes…"
	default:
		return "Indexing"
	}
}

// formatPathErrors lists the paths a run couldn't read, or "" if none. warn
// styles the heading.
func formatPathErrors(stats *indexer.Stats, warn func(string) string) string {
	if stats == nil || stats.ErrorCount == 0 {
		return ""
	}
	var b strings.Builder
	noun := "path"
	if stats.ErrorCount != 1 {
		noun = "paths"
	}
	b.WriteString("   " + warn(fmt.Sprintf("Couldn't read %d %s; what was indexed there before was kept:", stats.ErrorCount, noun)) + "\n")
	for _, e := range stats.Errors {
		b.WriteString("     " + e.Path + ": " + e.Err + "\n")
	}
	if more := stats.ErrorCount - len(stats.Errors); more > 0 {
		b.WriteString(fmt.Sprintf("     … and %d more\n", more))
	}
	return b.String()
}
