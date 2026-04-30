package commands

import (
	"fmt"
	"os"

	"github.com/ParkWardRR/zelira/internal/engine"
	"github.com/spf13/cobra"
)

var purgeData bool

func init() {
	uninstallCmd.Flags().BoolVar(&purgeData, "purge", false, "also delete config data in /srv/")
	rootCmd.AddCommand(uninstallCmd)
}

var uninstallCmd = &cobra.Command{
	Use:   "uninstall",
	Short: "Remove Zelira services",
	Long: `Stop all containers, remove systemd services and the health check timer.
Config data in /srv/ is preserved unless --purge is specified.

Requires root (sudo zelira uninstall).`,
	Run: func(cmd *cobra.Command, args []string) {
		if os.Geteuid() != 0 {
			fmt.Println("Error: uninstall requires root. Run: sudo zelira uninstall")
			os.Exit(1)
		}

		ui := &engine.UI{}

		// Stop services
		ui.Step("Stopping services...")
		for _, svc := range []string{"dns-healthcheck.timer", "container-pihole", "container-unbound", "container-kea-dhcp4"} {
			if engine.StopIfActive(svc) {
				ui.Info(fmt.Sprintf("Stopped %s", svc))
			}
			engine.SystemdAction("disable", svc)
		}

		// Remove containers
		ui.Step("Removing containers...")
		for _, name := range []string{"pihole", "unbound", "kea-dhcp4"} {
			if engine.RemoveContainer(name) {
				ui.Info(fmt.Sprintf("Removed %s", name))
			}
		}

		// Remove unit files
		ui.Step("Removing systemd units...")
		units := []string{
			"/etc/systemd/system/container-pihole.service",
			"/etc/systemd/system/container-unbound.service",
			"/etc/systemd/system/container-kea-dhcp4.service",
			"/etc/systemd/system/dns-healthcheck.service",
			"/etc/systemd/system/dns-healthcheck.timer",
		}
		for _, u := range units {
			os.Remove(u)
		}
		engine.SystemdAction("daemon-reload")
		ui.Info("Systemd units removed")

		// Health check script
		os.Remove("/usr/local/bin/dns-healthcheck.sh")
		ui.Info("Health check script removed")

		// Optional purge
		if purgeData {
			ui.Step("Purging data...")
			for _, dir := range []string{"/srv/pihole", "/srv/unbound", "/srv/kea"} {
				os.RemoveAll(dir)
				ui.Info(fmt.Sprintf("Deleted %s", dir))
			}
		} else {
			fmt.Println("\nConfig data preserved at:")
			fmt.Println("  /srv/pihole/")
			fmt.Println("  /srv/unbound/")
			fmt.Println("  /srv/kea/")
			fmt.Println("\nTo fully purge: sudo zelira uninstall --purge")
		}
	},
}
