package commands

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(uninstallCmd)
}

var uninstallCmd = &cobra.Command{
	Use:   "uninstall",
	Short: "Remove Zelira services",
	Long: `Stop all containers, remove systemd services and the health check timer.
Config data in /srv/ is preserved for re-deployment.

Requires root (sudo zelira uninstall).`,
	Run: func(cmd *cobra.Command, args []string) {
		if os.Geteuid() != 0 {
			fmt.Println("Error: uninstall requires root. Run: sudo zelira uninstall")
			os.Exit(1)
		}

		scriptDir := findScriptDir()
		script := filepath.Join(scriptDir, "scripts", "uninstall.sh")

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
