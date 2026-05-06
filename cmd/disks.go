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

func init() {
	rootCmd.AddCommand(disksCmd)
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
