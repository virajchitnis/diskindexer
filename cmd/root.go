package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
	"github.com/viraj/diskindexer/internal/config"
	"github.com/viraj/diskindexer/internal/db"
)

var dbFlags []string // values from --db flags

var rootCmd = &cobra.Command{
	Use:   "diskindexer",
	Short: "Create and search offline indexes of external hard disks",
	Long: `diskindexer indexes the file metadata of external disks into a portable
.diskindex file (SQLite) so you can search them without the disk plugged in.`,
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func init() {
	rootCmd.PersistentFlags().StringArrayVar(&dbFlags, "db", nil,
		"path to a .diskindex file (can be repeated for multi-DB operations)")
}

// loadConfig loads config and exits on error.
func loadConfig() *config.Config {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error loading config: %v\n", err)
		os.Exit(1)
	}
	return cfg
}

// resolveSingleDB returns the one DB path to use for write operations.
// --db overrides config; falls back to default_db.
func resolveSingleDB(cfg *config.Config) string {
	if len(dbFlags) > 0 {
		return dbFlags[0]
	}
	return cfg.DefaultDB
}

// resolveSearchDBs returns all DB paths to search across.
// --db overrides config; falls back to all known_dbs (or default_db).
func resolveSearchDBs(cfg *config.Config) []string {
	if len(dbFlags) > 0 {
		return dbFlags
	}
	if len(cfg.KnownDBs) > 0 {
		return cfg.KnownDBs
	}
	return []string{cfg.DefaultDB}
}

// openDB opens a single database, printing an error and exiting on failure.
func openDB(path string) *db.DB {
	d, err := db.Open(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error opening index %s: %v\n", path, err)
		os.Exit(1)
	}
	return d
}

// openDBs opens multiple databases for search, skipping ones that fail to open
// with a warning. Returns nil if none could be opened.
func openDBs(paths []string) []*db.DB {
	var dbs []*db.DB
	for _, p := range paths {
		d, err := db.Open(p)
		if err != nil {
			fmt.Fprintf(os.Stderr, "warning: skipping %s: %v\n", p, err)
			continue
		}
		dbs = append(dbs, d)
	}
	return dbs
}

func closeDBs(dbs []*db.DB) {
	for _, d := range dbs {
		d.Close()
	}
}
