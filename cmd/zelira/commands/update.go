package commands

import (
	"fmt"
	"os"
	"time"

	"github.com/ParkWardRR/zelira/internal/checker"
	"github.com/ParkWardRR/zelira/internal/engine"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(updateCmd)
}

var updateCmd = &cobra.Command{
	Use:   "update",
	Short: "Pull latest images and restart services",
	Long: `Pull the latest container images, restart services in dependency order,
and verify health.

Sequence:
  1. Pull latest images (pihole, unbound, kea)
  2. Stop services (reverse order: kea → pihole → unbound)
  3. Start services (forward order: unbound → pihole → kea)
  4. Run health check`,
	Run: func(cmd *cobra.Command, args []string) {
		if os.Geteuid() != 0 {
			fmt.Println("Error: update requires root. Run: sudo zelira update")
			os.Exit(1)
		}

		ui := &engine.UI{}

		// Pull
		ui.Step("Pulling latest images...")
		for _, img := range engine.Images {
			_, err := engine.PullImage(img, true)
			if err != nil {
				ui.Fail(fmt.Sprintf("%s: %v", img, err))
				os.Exit(1)
			}
			ui.Info(img)
		}

		// Stop in reverse dependency order
		ui.Step("Stopping services...")
		for _, svc := range []string{"container-kea-dhcp4", "container-pihole", "container-unbound"} {
			engine.SystemdAction("stop", svc)
			ui.Info(fmt.Sprintf("Stopped %s", svc))
		}

		// Start in forward dependency order
		ui.Step("Starting services...")
		engine.SystemdAction("start", "container-unbound")
		ui.Info("container-unbound")
		time.Sleep(3 * time.Second)
		engine.SystemdAction("start", "container-pihole")
		ui.Info("container-pihole")
		engine.SystemdAction("start", "container-kea-dhcp4")
		ui.Info("container-kea-dhcp4")

		// Health check
		ui.Step("Verifying health...")
		time.Sleep(2 * time.Second)
		report := checker.Run()
		fmt.Println()
		fmt.Print(report.Pretty())
	},
}
