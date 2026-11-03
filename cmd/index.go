package cmd

import (
	"fmt"
	"os"
	"path/filepath"
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

var (
	reindexCollLabel    string
	reindexCollDisk     string
	reindexCollFrom     string
	reindexCollRemember bool
)

var reindexCollectionCmd = &cobra.Command{
	Use:   "reindex-collection",
	Short: "Reindex one collection, optionally from another folder",
	Long: `Reindexes a single collection without walking the rest of its disk. The
disk's other collections and its root-level files are left untouched.

By default the collection is read from the folder it was last indexed from.
--from reads it from another folder instead, such as a copy on this machine
while the disk itself is unplugged; the index then reflects that folder. The
collection keeps its saved location unless --remember-location is given.`,
	Args: cobra.NoArgs,
	RunE: runReindexCollection,
}

func init() {
	reindexCollectionCmd.Flags().StringVar(&reindexCollLabel, "collection", "", "collection label (required)")
	reindexCollectionCmd.Flags().StringVar(&reindexCollDisk, "disk", "", "disk label to disambiguate when multiple collections share the same name")
	reindexCollectionCmd.Flags().StringVar(&reindexCollFrom, "from", "", "folder to read the collection from (default: its saved location)")
	reindexCollectionCmd.Flags().BoolVar(&reindexCollRemember, "remember-location", false, "save --from as the collection's location")
	reindexCollectionCmd.Flags().StringArrayVar(&indexExcludes, "exclude", nil,
		"file or folder name or glob pattern to skip (repeatable). Saved with the disk; omit to reuse the saved ones")
	reindexCollectionCmd.Flags().BoolVar(&indexNoDefaults, "no-default-excludes", false,
		"don't apply default_excludes from the config file for this run")
	_ = reindexCollectionCmd.MarkFlagRequired("collection")
	rootCmd.AddCommand(reindexCollectionCmd)

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

func runReindexCollection(cmd *cobra.Command, _ []string) error {
	cfg := loadConfig()
	database := openDB(resolveSingleDB(cfg))
	coll, err := resolveCollection(database, reindexCollLabel, reindexCollDisk)
	database.Close()
	if err != nil {
		return err
	}
	spec := indexer.CollectionSpec{Label: coll.Label, RootPath: coll.RootPath}
	if reindexCollFrom != "" {
		from, err := filepath.Abs(reindexCollFrom)
		if err != nil {
			return err
		}
		spec.RootPath = from
		spec.KeepRootPath = !reindexCollRemember
	}
	if info, err := os.Stat(spec.RootPath); err != nil || !info.IsDir() {
		return fmt.Errorf("collection %q: %s is not an available folder (is the disk plugged in? use --from to read a copy)", coll.Label, spec.RootPath)
	}
	// Reuse runIndex with this one collection and no mount path.
	indexDiskLabel = coll.DiskLabel
	indexDescription = ""
	indexCollections = nil
	indexForce = false
	return runIndexWith(cmd, "", []indexer.CollectionSpec{spec})
}

func runIndex(cmd *cobra.Command, args []string) error {
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
	return runIndexWith(cmd, mountPath, collSpecs)
}

func runIndexWith(cmd *cobra.Command, mountPath string, collSpecs []indexer.CollectionSpec) error {
	// No --exclude flags: reuse the excludes saved with the disk (nil).
	var excludes []string
	if cmd.Flags().Changed("exclude") {
		excludes = append([]string{}, indexExcludes...)
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
