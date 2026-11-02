package cmd

import (
	"fmt"
	"os"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/term"
	"github.com/spf13/cobra"
	"github.com/viraj/diskindexer/internal/indexer"
)

var (
	indexDiskLabel   string
	indexDescription string
	indexCollections []string
	indexExcludes    []string
	indexForce       bool
	indexNoDefaults  bool
)

var indexCmd = &cobra.Command{
	Use:   "index [mount-path]",
	Short: "Index a disk (incremental if seen before, full on first run)",
	Long: `Walks the filesystem at <mount-path> and records file metadata into the
index. On the first run this is a full index; subsequent runs update only
changed, new, or deleted files.

Collections are auto-detected as top-level directories. Use --collection to
override with manually specified paths.

The mount path may be omitted when --collection is given, e.g. to add a copy
of a collection stored elsewhere to a disk that isn't plugged in. The disk's
other collections and its root-level files are left untouched.`,
	Args: cobra.MaximumNArgs(1),
	RunE: runIndex,
}

var reindexCmd = &cobra.Command{
	Use:   "reindex [mount-path]",
	Short: "Alias for 'index' — explicit incremental re-index of a disk",
	Long:  `Runs an incremental update on a previously indexed disk. Identical to 'index' but makes intent clear in scripts and cron jobs.`,
	Args:  cobra.MaximumNArgs(1),
	RunE:  runIndex,
}

func init() {
	for _, cmd := range []*cobra.Command{indexCmd, reindexCmd} {
		cmd.Flags().StringVar(&indexDiskLabel, "disk", "", "disk label (required)")
		cmd.Flags().StringVar(&indexDescription, "description", "", "disk description")
		cmd.Flags().StringArrayVar(&indexCollections, "collection", nil,
			"manual collection spec: \"Label:/absolute/path\" (repeatable; disables auto-detect)")
		cmd.Flags().StringArrayVar(&indexExcludes, "exclude", nil,
			"file or folder name or glob pattern to skip at any depth (repeatable; e.g. --exclude .snapshots). Saved with the disk; omit to reuse the saved ones")
		cmd.Flags().BoolVar(&indexNoDefaults, "no-default-excludes", false,
			"don't apply default_excludes from the config file for this run")
		cmd.Flags().BoolVar(&indexForce, "force", false, "wipe existing index for this disk and re-index from scratch")
		_ = cmd.MarkFlagRequired("disk")
	}
	rootCmd.AddCommand(indexCmd, reindexCmd)
}

func runIndex(cmd *cobra.Command, args []string) error {
	// No --exclude flags: reuse the excludes saved with the disk (nil).
	var excludes []string
	if cmd.Flags().Changed("exclude") {
		excludes = append([]string{}, indexExcludes...)
	}
	var mountPath string
	if len(args) == 1 {
		mountPath = args[0]
		info, err := os.Stat(mountPath)
		if err != nil {
			return fmt.Errorf("mount path %q: %w", mountPath, err)
		}
		if !info.IsDir() {
			return fmt.Errorf("mount path %q is a file, not a directory", mountPath)
		}
	} else if len(indexCollections) == 0 {
		return fmt.Errorf("a mount path is required unless --collection is given")
	}

	var collSpecs []indexer.CollectionSpec
	for _, raw := range indexCollections {
		spec, err := indexer.ParseCollectionSpec(raw)
		if err != nil {
			return err
		}
		collSpecs = append(collSpecs, spec)
	}

	cfg := loadConfig()
	dbPath := resolveSingleDB(cfg)
	database := openDB(dbPath)
	defer database.Close()

	opts := indexer.Options{
		DiskLabel:   indexDiskLabel,
		Description: indexDescription,
		MountPath:   mountPath,
		Collections: collSpecs,
		Excludes:    excludes,
		Force:       indexForce,
	}
	if !indexNoDefaults {
		opts.DefaultExcludes = cfg.DefaultExcludes
	}

	fmt.Printf("Indexing %q → %s\n", indexDiskLabel, dbPath)

	// Interactive terminal: run the bubbletea progress display.
	if term.IsTerminal(os.Stdout.Fd()) {
		prog := newProgressModel(indexDiskLabel)
		p := tea.NewProgram(prog)

		opts.ProgressFn = func(u indexer.ProgressUpdate) {
			p.Send(progressUpdateMsg(u))
		}

		var (
			indexStats *indexer.Stats
			indexErr   error
		)
		go func() {
			indexStats, indexErr = indexer.Run(database, opts)
			p.Send(progressDoneMsg{stats: indexStats, err: indexErr})
		}()

		if _, err := p.Run(); err != nil {
			return err
		}
		return indexErr
	}

	// Non-interactive (piped / scripted): plain text output.
	if indexForce {
		fmt.Println("  Force mode: clearing existing index...")
	}
	stats, err := indexer.Run(database, opts)
	if err != nil {
		return err
	}
	fmt.Printf("  Done in %s\n", stats.Elapsed.Round(1e6))
	fmt.Printf("  Added: %d  Updated: %d  Deleted: %d  Unchanged: %d\n",
		stats.Added, stats.Updated, stats.Deleted, stats.Skipped)
	if len(stats.Excludes) > 0 {
		fmt.Printf("  Skipped anything named: %s\n", strings.Join(stats.Excludes, ", "))
	}
	fmt.Print(formatPathErrors(stats, func(s string) string { return s }))
	return nil
}
