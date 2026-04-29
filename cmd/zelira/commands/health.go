package commands

import (
	"fmt"
	"os"

	"github.com/ParkWardRR/zelira/internal/checker"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(healthCmd)
}

var healthCmd = &cobra.Command{
	Use:   "health",
	Short: "Run all health checks",
	Long: `Run the full Zelira health check suite.

Validates containers, systemd services, DNS resolution (Unbound + Pi-hole),
DNSSEC, ad-blocking, listening ports, and any deployed add-ons (NTP, DDNS,
Caddy dashboard).

Use --json for machine-readable output (Prometheus, scripts, etc).`,
	Run: func(cmd *cobra.Command, args []string) {
		report := checker.Run()

		if jsonOut {
			fmt.Println(report.JSON())
		} else {
			fmt.Print(report.Pretty())
		}

		if !report.Healthy {
			os.Exit(1)
		}
	},
}
