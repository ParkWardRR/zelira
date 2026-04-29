package commands

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(deployCmd)
}

var deployCmd = &cobra.Command{
	Use:   "deploy",
	Short: "Deploy the full DNS/DHCP stack",
	Long: `Deploy Pi-hole, Unbound, and Kea DHCP containers with systemd services.

Reads configuration from config/.env. Idempotent — safe to run multiple times.
Requires root (sudo zelira deploy).`,
	Run: func(cmd *cobra.Command, args []string) {
		if os.Geteuid() != 0 {
			fmt.Println("Error: deploy requires root. Run: sudo zelira deploy")
			os.Exit(1)
		}

		scriptDir := findScriptDir()
		script := filepath.Join(scriptDir, "deploy.sh")

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

// findScriptDir locates the Zelira repo root by walking up from the binary
// or checking common locations.
func findScriptDir() string {
	// Check if we're running from the repo
	if _, err := os.Stat("deploy.sh"); err == nil {
		cwd, _ := os.Getwd()
		return cwd
	}

	// Check common install locations
	for _, dir := range []string{
		"/opt/zelira",
		"/usr/local/share/zelira",
		filepath.Join(os.Getenv("HOME"), "zelira"),
	} {
		if _, err := os.Stat(filepath.Join(dir, "deploy.sh")); err == nil {
			return dir
		}
	}

	// Fall back to cwd
	cwd, _ := os.Getwd()
	return cwd
}
