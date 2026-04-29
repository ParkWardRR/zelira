package commands

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(addonCmd)
}

var validAddons = map[string]string{
	"ntp":       "deploy-ntp.sh",
	"ddns":      "deploy-ddns.sh",
	"dashboard": "deploy-dashboard.sh",
}

var addonCmd = &cobra.Command{
	Use:   "addon <name>",
	Short: "Deploy an add-on (ntp, ddns, dashboard)",
	Long: `Deploy an optional Zelira add-on.

Available add-ons:
  ntp         Chrony NTP time server (auto-injects DHCP Option 42)
  ddns        Dynamic DNS updater (Namecheap, Cloudflare, DuckDNS)
  dashboard   Caddy reverse proxy + dashboard with auto-TLS

Requires root (sudo zelira addon ntp).`,
	Args: cobra.ExactArgs(1),
	ValidArgs: []string{"ntp", "ddns", "dashboard"},
	Run: func(cmd *cobra.Command, args []string) {
		if os.Geteuid() != 0 {
			fmt.Println("Error: addon requires root. Run: sudo zelira addon <name>")
			os.Exit(1)
		}

		name := args[0]
		scriptName, ok := validAddons[name]
		if !ok {
			fmt.Printf("Error: unknown add-on '%s'. Available: ntp, ddns, dashboard\n", name)
			os.Exit(1)
		}

		scriptDir := findScriptDir()
		script := filepath.Join(scriptDir, "scripts", scriptName)

		if _, err := os.Stat(script); os.IsNotExist(err) {
			fmt.Printf("Error: %s not found\n", script)
			os.Exit(1)
		}

		c := exec.Command("bash", script)
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		c.Stdin = os.Stdin
		if err := c.Run(); err != nil {
			os.Exit(1)
		}
	},
}
