package cmd

import (
	"fmt"
	"os"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
	"github.com/viraj/diskindexer/internal/db"
)

var collectionsDiskLabel string

var collectionsCmd = &cobra.Command{
	Use:   "collections",
	Short: "List collections, optionally filtered to a disk",
	RunE:  runCollections,
}

var (
	renameCollectionLabel     string
	renameCollectionDiskLabel string
)

var renameCollectionCmd = &cobra.Command{
	Use:   "rename-collection <new-label>",
	Short: "Rename a collection",
	Args:  cobra.ExactArgs(1),
	RunE:  runRenameCollection,
}

var (
	deleteCollectionLabel     string
	deleteCollectionDiskLabel string
)

var deleteCollectionCmd = &cobra.Command{
	Use:   "delete-collection",
	Short: "Remove a collection and all its files from the index",
	Long: `Removes the collection entry and all files belonging to it from the index.
This only affects the index — files on the actual disk are untouched.`,
	RunE: runDeleteCollection,
}

func init() {
	collectionsCmd.Flags().StringVar(&collectionsDiskLabel, "disk", "", "filter to collections on this disk")

	renameCollectionCmd.Flags().StringVar(&renameCollectionLabel, "collection", "", "collection label to rename (required)")
	renameCollectionCmd.Flags().StringVar(&renameCollectionDiskLabel, "disk", "", "disk label to disambiguate when multiple collections share the same name")
	_ = renameCollectionCmd.MarkFlagRequired("collection")

	deleteCollectionCmd.Flags().StringVar(&deleteCollectionLabel, "collection", "", "collection label to delete (required)")
	deleteCollectionCmd.Flags().StringVar(&deleteCollectionDiskLabel, "disk", "", "disk label to disambiguate when multiple collections share the same name")
	_ = deleteCollectionCmd.MarkFlagRequired("collection")

	rootCmd.AddCommand(collectionsCmd, renameCollectionCmd, deleteCollectionCmd)
}

func runCollections(_ *cobra.Command, _ []string) error {
	cfg := loadConfig()
	database := openDB(resolveSingleDB(cfg))
	defer database.Close()

	var diskID int64
	if collectionsDiskLabel != "" {
		disk, err := database.GetDiskByLabel(collectionsDiskLabel)
		if err != nil {
			return err
		}
		if disk == nil {
			return fmt.Errorf("disk %q not found", collectionsDiskLabel)
		}
		diskID = disk.ID
	}

	colls, err := database.ListCollections(diskID)
	if err != nil {
		return err
	}
	if len(colls) == 0 {
		fmt.Println("No collections found.")
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "DISK\tLABEL\tROOT PATH\tLAST INDEXED")
	fmt.Fprintln(w, "────\t─────\t─────────\t────────────")
	for _, c := range colls {
		lastIndexed := "never"
		if c.LastIndexedAt != nil {
			lastIndexed = c.LastIndexedAt.Local().Format(time.DateTime)
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", c.DiskLabel, c.Label, c.RootPath, lastIndexed)
	}
	return w.Flush()
}

// resolveCollection looks up a collection by label (and optionally disk label),
// returning an error if none or more than one match is found.
func resolveCollection(database *db.DB, collLabel, diskLabel string) (*db.Collection, error) {
	colls, err := database.GetCollectionsByLabel(collLabel, diskLabel)
	if err != nil {
		return nil, err
	}
	switch len(colls) {
	case 0:
		if diskLabel != "" {
			return nil, fmt.Errorf("collection %q not found on disk %q", collLabel, diskLabel)
		}
		return nil, fmt.Errorf("collection %q not found", collLabel)
	case 1:
		return colls[0], nil
	default:
		// Multiple matches — ask the user to specify a disk.
		var b strings.Builder
		fmt.Fprintf(&b, "collection %q exists on multiple disks; use --disk to disambiguate:\n", collLabel)
		for _, c := range colls {
			fmt.Fprintf(&b, "  disk %q\n", c.DiskLabel)
		}
		return nil, fmt.Errorf("%s", strings.TrimRight(b.String(), "\n"))
	}
}

func runRenameCollection(_ *cobra.Command, args []string) error {
	newLabel := strings.TrimSpace(args[0])
	if newLabel == "" {
		return fmt.Errorf("new label must not be empty")
	}

	cfg := loadConfig()
	database := openDB(resolveSingleDB(cfg))
	defer database.Close()

	coll, err := resolveCollection(database, renameCollectionLabel, renameCollectionDiskLabel)
	if err != nil {
		return err
	}

	if err := database.RenameCollection(coll.ID, newLabel); err != nil {
		return err
	}
	fmt.Printf("Collection %q on disk %q renamed to %q.\n", renameCollectionLabel, coll.DiskLabel, newLabel)
	return nil
}

func runDeleteCollection(_ *cobra.Command, _ []string) error {
	cfg := loadConfig()
	database := openDB(resolveSingleDB(cfg))
	defer database.Close()

	coll, err := resolveCollection(database, deleteCollectionLabel, deleteCollectionDiskLabel)
	if err != nil {
		return err
	}

	found, err := database.DeleteCollection(coll.ID)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("collection %q not found", deleteCollectionLabel)
	}
	fmt.Printf("Collection %q on disk %q and all its files removed from the index.\n", deleteCollectionLabel, coll.DiskLabel)
	return nil
}
