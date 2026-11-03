package cmd

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
	"github.com/viraj/diskindexer/internal/api"
)

var scheduleCmd = &cobra.Command{
	Use:   "schedule",
	Short: "Reindex disks or collections periodically (run by 'diskindexer serve')",
	Long: `Schedules are saved in the index and run by 'diskindexer serve', so they only
run while the server does: with the systemd service and linger, around the
clock; without linger, only while you're logged in.

A run is skipped, and nothing is removed from the index, when its folder isn't
there, is empty, or its disk isn't mounted.`,
}

var (
	scheduleDisk       string
	scheduleCollection string
	schedulePath       string
	scheduleEvery      string
	scheduleAt         string
	scheduleDisabled   bool
)

var scheduleAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Add a schedule for a disk or one of its collections",
	Long: `Adds a schedule. For a whole disk, --path is its mount path. For a collection
(--collection), --path is optional: the folder to read it from instead of its
saved location, e.g. a copy on this machine; the collection keeps its saved
location. The folder must be available when the schedule is added.

--every takes hours, days or weeks: 6h, 1d, 2w. --at sets a time of day
(HH:MM, this machine's time zone) for intervals of whole days.`,
	Args: cobra.NoArgs,
	RunE: runScheduleAdd,
}

var scheduleListCmd = &cobra.Command{
	Use:   "list",
	Short: "List schedules with their last and next runs",
	Args:  cobra.NoArgs,
	RunE:  runScheduleList,
}

var scheduleRemoveCmd = &cobra.Command{
	Use:   "remove <id>",
	Short: "Remove a schedule",
	Args:  cobra.ExactArgs(1),
	RunE:  runScheduleRemove,
}

func init() {
	f := scheduleAddCmd.Flags()
	f.StringVar(&scheduleDisk, "disk", "", "disk label (required)")
	f.StringVar(&scheduleCollection, "collection", "", "collection label (default: the whole disk)")
	f.StringVar(&schedulePath, "path", "", "mount path of the disk, or folder to read the collection from")
	f.StringVar(&scheduleEvery, "every", "", "interval: e.g. 6h, 1d, 1w (required)")
	f.StringVar(&scheduleAt, "at", "", "time of day, HH:MM (whole-day intervals only)")
	f.BoolVar(&scheduleDisabled, "disabled", false, "add it switched off")
	_ = scheduleAddCmd.MarkFlagRequired("disk")
	_ = scheduleAddCmd.MarkFlagRequired("every")
	scheduleCmd.AddCommand(scheduleAddCmd, scheduleListCmd, scheduleRemoveCmd)
	rootCmd.AddCommand(scheduleCmd)
}

// parseEvery reads "6h", "1d" or "2w" as hours.
func parseEvery(s string) (int, error) {
	s = strings.TrimSpace(strings.ToLower(s))
	units := map[string]int{"h": 1, "d": 24, "w": 168}
	if len(s) >= 2 {
		if mult, ok := units[s[len(s)-1:]]; ok {
			if n, err := strconv.Atoi(s[:len(s)-1]); err == nil && n > 0 {
				return n * mult, nil
			}
		}
	}
	return 0, fmt.Errorf("--every %q: use hours, days or weeks, e.g. 6h, 1d, 1w", s)
}

func scheduleService() (*api.Service, error) {
	return api.NewService(version, resolveSingleDB(loadConfig()), nil)
}

func runScheduleAdd(_ *cobra.Command, _ []string) error {
	hours, err := parseEvery(scheduleEvery)
	if err != nil {
		return err
	}
	svc, err := scheduleService()
	if err != nil {
		return err
	}
	defer svc.Close()
	sc, err := svc.SaveSchedule("", 0, api.ScheduleRequest{Disk: scheduleDisk, Collection: scheduleCollection,
		Path: expandHome(schedulePath), IntervalHours: hours, At: scheduleAt, Enabled: !scheduleDisabled})
	if err != nil {
		return err
	}
	fmt.Printf("Schedule %d added: %s, %s.\n", sc.ID, scheduleTarget(sc), describeInterval(sc))
	if sc.NextRunAt != nil {
		fmt.Printf("Next run %s, while 'diskindexer serve' is running.\n", sc.NextRunAt.Local().Format(time.DateTime))
	}
	return nil
}

func runScheduleList(_ *cobra.Command, _ []string) error {
	svc, err := scheduleService()
	if err != nil {
		return err
	}
	defer svc.Close()
	list, err := svc.Schedules()
	if err != nil {
		return err
	}
	if len(list) == 0 {
		fmt.Println("No schedules.")
		return nil
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tTARGET\tFROM\tEVERY\tLAST RUN\tNEXT RUN")
	for _, sc := range list {
		from := sc.Path
		if from == "" {
			from = "(saved location)"
		}
		last := "never"
		if sc.LastRunAt != nil {
			last = sc.LastRunAt.Local().Format(time.DateTime) + " " + sc.LastStatus
			if sc.LastMessage != "" {
				last += ": " + sc.LastMessage
			}
		}
		next := "off"
		if sc.NextRunAt != nil {
			next = sc.NextRunAt.Local().Format(time.DateTime)
		}
		fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\t%s\n", sc.ID, scheduleTarget(sc), from, describeInterval(sc), last, next)
	}
	return w.Flush()
}

func runScheduleRemove(_ *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid schedule id %q", args[0])
	}
	svc, err := scheduleService()
	if err != nil {
		return err
	}
	defer svc.Close()
	if err := svc.DeleteSchedule("", id); err != nil {
		return err
	}
	fmt.Printf("Schedule %d removed.\n", id)
	return nil
}

func scheduleTarget(sc api.Schedule) string {
	if sc.Collection == "" {
		return sc.Disk
	}
	return sc.Disk + "/" + sc.Collection
}

func describeInterval(sc api.Schedule) string {
	var every string
	switch h := sc.IntervalHours; {
	case h%168 == 0:
		every = plural(h/168, "week")
	case h%24 == 0:
		every = plural(h/24, "day")
	default:
		every = plural(h, "hour")
	}
	if sc.At != "" {
		every += " at " + sc.At
	}
	return every
}

func plural(n int, unit string) string {
	if n == 1 {
		return "every " + unit
	}
	return fmt.Sprintf("every %d %ss", n, unit)
}
