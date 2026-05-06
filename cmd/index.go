package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
	"github.com/viraj/diskindexer/internal/indexer"
)

var (
	indexDiskLabel   string
	indexDescription string
	indexCollections []string
	indexForce       bool
)

var indexCmd = &cobra.Command{
	Use:   "index <mount-path>",
	Short: "Index a disk (incremental if seen before, full on first run)",
	Long: `Walks the filesystem at <mount-path> and records file metadata into the
index. On the first run this is a full index; subsequent runs update only
changed, new, or deleted files.

Collections are auto-detected as top-level directories. Use --collection to
override with manually specified paths.`,
	Args: cobra.ExactArgs(1),
	RunE: runIndex,
}

var reindexCmd = &cobra.Command{
	Use:   "reindex",
	Short: "Alias for 'index' — explicit incremental re-index of a disk",
	Long:  `Runs an incremental update on a previously indexed disk. Identical to 'index' but makes intent clear in scripts and cron jobs.`,
	Args:  cobra.ExactArgs(1),
	RunE:  runIndex,
}

func init() {
	for _, cmd := range []*cobra.Command{indexCmd, reindexCmd} {
		cmd.Flags().StringVar(&indexDiskLabel, "disk", "", "disk label (required)")
		cmd.Flags().StringVar(&indexDescription, "description", "", "disk description")
		cmd.Flags().StringArrayVar(&indexCollections, "collection", nil,
			"manual collection spec: \"Label:/absolute/path\" (repeatable; disables auto-detect)")
		cmd.Flags().BoolVar(&indexForce, "force", false, "wipe existing index for this disk and re-index from scratch")
		_ = cmd.MarkFlagRequired("disk")
	}
	rootCmd.AddCommand(indexCmd, reindexCmd)
}

func runIndex(cmd *cobra.Command, args []string) error {
	mountPath := args[0]
	info, err := os.Stat(mountPath)
	if err != nil {
		return fmt.Errorf("mount path %q: %w", mountPath, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("mount path %q is a file, not a directory", mountPath)
	}

	var collSpecs []indexer.CollectionSpec
	for _, raw := range indexCollections {
		spec, err := indexer.ParseCollectionSpec(raw)
		if err != nil {
			return err
		}
		if err := spec.ValidateUnderMount(mountPath); err != nil {
			return err
		}
		collSpecs = append(collSpecs, spec)
	}

	cfg := loadConfig()
	dbPath := resolveSingleDB(cfg)
	database := openDB(dbPath)
	defer database.Close()

	fmt.Printf("Indexing %q → %s\n", indexDiskLabel, dbPath)

	stats, err := indexer.Run(database, indexer.Options{
		DiskLabel:   indexDiskLabel,
		Description: indexDescription,
		MountPath:   mountPath,
		Collections: collSpecs,
		Force:       indexForce,
	})
	if err != nil {
		return err
	}

	fmt.Printf("\n  Done in %s\n", stats.Elapsed.Round(1e6))
	fmt.Printf("  Added: %d  Updated: %d  Deleted: %d  Unchanged: %d\n",
		stats.Added, stats.Updated, stats.Deleted, stats.Skipped)
	return nil
}
