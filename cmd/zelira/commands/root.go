package commands

import (
	"fmt"

	"github.com/spf13/cobra"
)

var (
	version = "0.1.0"
	jsonOut bool
)

var rootCmd = &cobra.Command{
	Use:   "zelira",
	Short: "Production-hardened DNS + DHCP for homelabs",
	Long: `Zelira — Production-hardened DNS + DHCP for homelabs.
Pi-hole · Unbound · Kea · NTP · DDNS · Dashboard — one command.

Usage:
  zelira deploy            Deploy the full DNS/DHCP stack
  zelira health            Run all health checks
  zelira status            Show service status
  zelira addon <name>      Deploy an add-on (ntp, ddns, dashboard)
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
