package tui

import "github.com/charmbracelet/lipgloss"

type styleSet struct {
	title      lipgloss.Style
	label      lipgloss.Style
	filterKey  lipgloss.Style
	filterVal  lipgloss.Style
	colHeader  lipgloss.Style
	selected   lipgloss.Style
	dim        lipgloss.Style
	divider    lipgloss.Style
	count      lipgloss.Style
	statusMsg  lipgloss.Style
	errStyle   lipgloss.Style
	detailPath lipgloss.Style
	dupe       lipgloss.Style
}

var styles = styleSet{
	title: lipgloss.NewStyle().Bold(true).
		Foreground(lipgloss.AdaptiveColor{Light: "#005f87", Dark: "#7dcfff"}),

	label: lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#666666", Dark: "#888888"}),

	filterKey: lipgloss.NewStyle().Bold(true).
		Foreground(lipgloss.AdaptiveColor{Light: "#0066cc", Dark: "#7dcfff"}),

	filterVal: lipgloss.NewStyle().Bold(true).
		Foreground(lipgloss.AdaptiveColor{Light: "#111111", Dark: "#eeeeee"}),

	colHeader: lipgloss.NewStyle().Bold(true).
		Foreground(lipgloss.AdaptiveColor{Light: "#444444", Dark: "#aaaaaa"}),

	selected: lipgloss.NewStyle().
		Background(lipgloss.AdaptiveColor{Light: "#0066cc", Dark: "#264f78"}).
		Foreground(lipgloss.Color("#ffffff")),

	dim: lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#999999", Dark: "#555555"}),

	divider: lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#cccccc", Dark: "#333333"}),

	count: lipgloss.NewStyle().Bold(true),

	statusMsg: lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#007700", Dark: "#88dd88"}),

	errStyle: lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#cc0000", Dark: "#ff6666"}),

	detailPath: lipgloss.NewStyle().Bold(true).
		Foreground(lipgloss.AdaptiveColor{Light: "#111111", Dark: "#eeeeee"}),

	dupe: lipgloss.NewStyle().
		Foreground(lipgloss.AdaptiveColor{Light: "#b35900", Dark: "#ffb347"}),
}
