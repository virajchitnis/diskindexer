package cmd

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
)

var collectionsDiskLabel string

var collectionsCmd = &cobra.Command{
	Use:   "collections",
	Short: "List collections, optionally filtered to a disk",
	RunE:  runCollections,
}

var renameCollectionCmd = &cobra.Command{
	Use:   "rename-collection <id> <new-label>",
	Short: "Rename a collection by its numeric ID",
	Args:  cobra.ExactArgs(2),
	RunE:  runRenameCollection,
}

func init() {
	collectionsCmd.Flags().StringVar(&collectionsDiskLabel, "disk", "", "filter to collections on this disk")
	rootCmd.AddCommand(collectionsCmd, renameCollectionCmd)
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
	fmt.Fprintln(w, "ID\tDISK\tLABEL\tROOT PATH\tLAST INDEXED")
	fmt.Fprintln(w, "──\t────\t─────\t─────────\t────────────")
	for _, c := range colls {
		lastIndexed := "never"
		if c.LastIndexedAt != nil {
			lastIndexed = c.LastIndexedAt.Local().Format(time.DateTime)
		}
		fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\n", c.ID, c.DiskLabel, c.Label, c.RootPath, lastIndexed)
	}
	return w.Flush()
}

func runRenameCollection(_ *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid collection ID %q: must be a number", args[0])
	}
	newLabel := strings.TrimSpace(args[1])
	if newLabel == "" {
		return fmt.Errorf("new label must not be empty")
	}

	cfg := loadConfig()
	database := openDB(resolveSingleDB(cfg))
	defer database.Close()

	if err := database.RenameCollection(id, newLabel); err != nil {
		return err
	}
	fmt.Printf("Collection %d renamed to %q\n", id, newLabel)
	return nil
}
