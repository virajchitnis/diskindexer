package cmd

import (
	"fmt"
	"os"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
)

var disksCmd = &cobra.Command{
	Use:   "disks",
	Short: "List all indexed disks",
	RunE:  runDisks,
}

var deleteDiskCmd = &cobra.Command{
	Use:   "delete-disk",
	Short: "Remove a disk and all its files from the index",
	Long: `Removes the disk entry and all associated collections and files from the
index. This only affects the index — files on the actual disk are untouched.`,
	RunE: runDeleteDisk,
}

var deleteDiskLabel string

func init() {
	deleteDiskCmd.Flags().StringVar(&deleteDiskLabel, "disk", "", "disk label to delete (required)")
	_ = deleteDiskCmd.MarkFlagRequired("disk")
	rootCmd.AddCommand(disksCmd, deleteDiskCmd)
}

func runDisks(_ *cobra.Command, _ []string) error {
	cfg := loadConfig()
	dbPath := resolveSingleDB(cfg)
	database := openDB(dbPath)
	defer database.Close()

	disks, err := database.ListDisks()
	if err != nil {
		return err
	}

	if len(disks) == 0 {
		fmt.Println("No disks indexed yet. Run 'diskindexer index' to get started.")
		return nil
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tLABEL\tDESCRIPTION\tLAST INDEXED")
	fmt.Fprintln(w, "──\t─────\t───────────\t────────────")
	for _, d := range disks {
		lastIndexed := "never"
		if d.LastIndexedAt != nil {
			lastIndexed = d.LastIndexedAt.Local().Format(time.DateTime)
		}
		fmt.Fprintf(w, "%d\t%s\t%s\t%s\n", d.ID, d.Label, d.Description, lastIndexed)
	}
	return w.Flush()
}

func runDeleteDisk(_ *cobra.Command, _ []string) error {
	cfg := loadConfig()
	database := openDB(resolveSingleDB(cfg))
	defer database.Close()

	found, err := database.DeleteDisk(deleteDiskLabel)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("disk %q not found", deleteDiskLabel)
	}
	fmt.Printf("Disk %q and all its collections and files removed from the index.\n", deleteDiskLabel)
	return nil
}
