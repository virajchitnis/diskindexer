package cmd

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
	"github.com/viraj/diskindexer/internal/db"
	"github.com/viraj/diskindexer/internal/search"
)

var (
	searchDiskLabel string
	searchExt       string
	searchDirsOnly  bool
	searchFilesOnly bool
	searchMinSize   string
	searchMaxSize   string
	searchAfter     string
	searchBefore    string
	searchLimit     int
)

var searchCmd = &cobra.Command{
	Use:   "search [query]",
	Short: "Search the index (Phase 1: text output; Phase 2 will add an interactive TUI)",
	Long: `Search file metadata across all indexed disks.

Without a query, lists all files matching the given filters.
In Phase 2 this command will launch an interactive TUI when run without arguments.`,
	RunE: runSearch,
}

func init() {
	searchCmd.Flags().StringVar(&searchDiskLabel, "disk", "", "filter by disk label")
	searchCmd.Flags().StringVar(&searchExt, "ext", "", "filter by extension (without dot, e.g. jpg)")
	searchCmd.Flags().BoolVar(&searchDirsOnly, "dirs-only", false, "show directories only")
	searchCmd.Flags().BoolVar(&searchFilesOnly, "files-only", false, "show files only")
	searchCmd.Flags().StringVar(&searchMinSize, "min-size", "", "minimum file size (e.g. 1MB, 500KB)")
	searchCmd.Flags().StringVar(&searchMaxSize, "max-size", "", "maximum file size (e.g. 10GB)")
	searchCmd.Flags().StringVar(&searchAfter, "after", "", "modified after date (YYYY-MM-DD)")
	searchCmd.Flags().StringVar(&searchBefore, "before", "", "modified before date (YYYY-MM-DD)")
	searchCmd.Flags().IntVar(&searchLimit, "limit", 50, "maximum results to display")
	rootCmd.AddCommand(searchCmd)
}

func runSearch(_ *cobra.Command, args []string) error {
	if searchDirsOnly && searchFilesOnly {
		return fmt.Errorf("--dirs-only and --files-only are mutually exclusive")
	}

	var query string
	if len(args) > 0 {
		query = strings.Join(args, " ")
	}

	params := db.SearchParams{
		Query:  query,
		Limit:  searchLimit,
		Offset: 0,
	}

	if searchExt != "" {
		params.Extension = strings.ToLower(strings.TrimPrefix(searchExt, "."))
	}
	if searchDirsOnly {
		t := true
		params.IsDir = &t
	} else if searchFilesOnly {
		f := false
		params.IsDir = &f
	}

	var err error
	if searchMinSize != "" {
		params.MinSize, err = parseSize(searchMinSize)
		if err != nil {
			return fmt.Errorf("--min-size: %w", err)
		}
	}
	if searchMaxSize != "" {
		params.MaxSize, err = parseSize(searchMaxSize)
		if err != nil {
			return fmt.Errorf("--max-size: %w", err)
		}
	}
	if searchAfter != "" {
		params.ModAfter, err = time.Parse("2006-01-02", searchAfter)
		if err != nil {
			return fmt.Errorf("--after: expected YYYY-MM-DD, got %q", searchAfter)
		}
	}
	if searchBefore != "" {
		params.ModBefore, err = time.Parse("2006-01-02", searchBefore)
		if err != nil {
			return fmt.Errorf("--before: expected YYYY-MM-DD, got %q", searchBefore)
		}
		// Include the full before-day.
		params.ModBefore = params.ModBefore.Add(24*time.Hour - time.Second)
	}

	params.DiskLabel = searchDiskLabel

	cfg := loadConfig()
	dbs := openDBs(resolveSearchDBs(cfg))
	if len(dbs) == 0 {
		return fmt.Errorf("no index files found; run 'diskindexer index' first")
	}
	defer closeDBs(dbs)

	results, err := search.Across(dbs, params)
	if err != nil {
		return err
	}

	if len(results) == 0 {
		fmt.Println("No results found.")
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tDISK\tCOLLECTION\tSIZE\tMODIFIED\tPATH")
	fmt.Fprintln(w, "────\t────\t──────────\t────\t────────\t────")
	for _, r := range results {
		f := r.File
		kind := ""
		if f.IsDir {
			kind = "/"
		}
		fmt.Fprintf(w, "%s%s\t%s\t%s\t%s\t%s\t%s\n",
			f.Name, kind,
			f.DiskLabel,
			f.CollLabel,
			formatSize(f.Size),
			f.ModifiedAt.Local().Format("2006-01-02"),
			f.Path,
		)
	}
	if err := w.Flush(); err != nil {
		return err
	}
	fmt.Printf("\n%d result(s)", len(results))
	if len(results) == searchLimit {
		fmt.Printf(" (limit reached — use --limit to see more)")
	}
	fmt.Println()
	return nil
}

// formatSize returns a human-readable file size string.
func formatSize(bytes int64) string {
	const (
		kb = 1 << 10
		mb = 1 << 20
		gb = 1 << 30
		tb = 1 << 40
	)
	switch {
	case bytes < 0:
		return "-"
	case bytes == 0:
		return "0 B"
	case bytes >= tb:
		return fmt.Sprintf("%.1f TB", float64(bytes)/tb)
	case bytes >= gb:
		return fmt.Sprintf("%.1f GB", float64(bytes)/gb)
	case bytes >= mb:
		return fmt.Sprintf("%.1f MB", float64(bytes)/mb)
	case bytes >= kb:
		return fmt.Sprintf("%.1f KB", float64(bytes)/kb)
	default:
		return fmt.Sprintf("%d B", bytes)
	}
}

// parseSize parses strings like "1MB", "500KB", "2GB", "1.5TB".
func parseSize(s string) (int64, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("empty size string")
	}

	multipliers := []struct {
		suffix string
		factor int64
	}{
		{"TB", 1 << 40}, {"GB", 1 << 30}, {"MB", 1 << 20}, {"KB", 1 << 10}, {"B", 1},
	}

	upper := strings.ToUpper(s)
	for _, m := range multipliers {
		if strings.HasSuffix(upper, m.suffix) {
			numStr := strings.TrimSuffix(upper, m.suffix)
			f, err := strconv.ParseFloat(strings.TrimSpace(numStr), 64)
			if err != nil {
				return 0, fmt.Errorf("cannot parse %q", s)
			}
			return int64(f * float64(m.factor)), nil
		}
	}
	// Plain number treated as bytes.
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("cannot parse %q: expected a number with optional suffix (B, KB, MB, GB, TB)", s)
	}
	return n, nil
}
