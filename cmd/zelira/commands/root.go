package commands

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"
)

var (
	version = "0.2.0"
	jsonOut bool
)

var rootCmd = &cobra.Command{
	Use:   "zelira",
	Short: "Production-hardened DNS + DHCP for homelabs",
	Long: `Zelira — Production-hardened DNS + DHCP for homelabs.
Pi-hole · Unbound · Kea · NTP · DDNS · Dashboard — one command.

Commands:
  zelira deploy            Deploy the full DNS/DHCP stack
  zelira health            Run all health checks
  zelira status            Show service status
  zelira addon <name>      Deploy an add-on (ntp, ddns, dashboard)
  zelira validate          Pre-flight config check (no deploy)
  zelira init              Interactive setup wizard
  zelira logs              View service logs
  zelira update            Pull images + restart + verify
  zelira backup            Export config to tarball
  zelira restore           Restore from backup
  zelira doctor            Deep diagnostic check
  zelira uninstall         Remove Zelira services`,
}

func Execute() error {
	return rootCmd.Execute()
}

func init() {
	rootCmd.PersistentFlags().BoolVar(&jsonOut, "json", false, "output in JSON format")
	rootCmd.AddCommand(versionCmd)
}

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print the version",
	Run: func(cmd *cobra.Command, args []string) {
		if jsonOut {
			fmt.Printf(`{"version":"%s"}`+"\n", version)
		} else {
			fmt.Printf("zelira v%s\n", version)
		}
	},
}

// findFile locates a file relative to the zelira repo root.
// Checks cwd, then common install locations.
func findFile(relPath string) string {
	// Check cwd
	if _, err := os.Stat(relPath); err == nil {
		abs, _ := filepath.Abs(relPath)
		return abs
	}

	// Check common locations
	for _, base := range []string{
		"/opt/zelira",
		"/usr/local/share/zelira",
		filepath.Join(os.Getenv("HOME"), "zelira"),
	} {
		full := filepath.Join(base, relPath)
		if _, err := os.Stat(full); err == nil {
			return full
		}
	}
	return ""
}
