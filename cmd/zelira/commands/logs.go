package commands

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"
)

func init() {
	logsCmd.Flags().StringVarP(&logsService, "service", "s", "", "filter by service (pihole, unbound, kea, health)")
	logsCmd.Flags().IntVarP(&logsLines, "lines", "n", 50, "number of lines to show")
	logsCmd.Flags().BoolVarP(&logsFollow, "follow", "f", false, "follow log output")
	rootCmd.AddCommand(logsCmd)
}

var (
	logsService string
	logsLines   int
	logsFollow  bool
)

var serviceToUnit = map[string]string{
	"pihole":  "container-pihole",
	"unbound": "container-unbound",
	"kea":     "container-kea-dhcp4",
	"dhcp":    "container-kea-dhcp4",
	"health":  "dns-healthcheck",
}

var logsCmd = &cobra.Command{
	Use:   "logs",
	Short: "View Zelira service logs",
	Long: `View unified or per-service logs from journald.

Examples:
  zelira logs                    # all Zelira services, last 50 lines
  zelira logs -s pihole          # Pi-hole only
  zelira logs -s unbound -f      # follow Unbound logs
  zelira logs -n 200             # last 200 lines`,
	Run: func(cmd *cobra.Command, args []string) {
		var units []string
		if logsService != "" {
			unit, ok := serviceToUnit[strings.ToLower(logsService)]
			if !ok {
				fmt.Printf("Unknown service: %s\nAvailable: pihole, unbound, kea, health\n", logsService)
				os.Exit(1)
			}
			units = []string{unit}
		} else {
			units = []string{"container-unbound", "container-pihole", "container-kea-dhcp4", "dns-healthcheck"}
		}

		jArgs := []string{"--no-pager", fmt.Sprintf("--lines=%d", logsLines)}
		if logsFollow {
			jArgs = append(jArgs, "--follow")
		}
		for _, u := range units {
			jArgs = append(jArgs, "-u", u)
		}

		c := exec.Command("journalctl", jArgs...)
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		c.Run()
	},
}
