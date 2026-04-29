package commands

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(statusCmd)
}

// ServiceStatus represents the status of a single service.
type ServiceStatus struct {
	Name      string `json:"name"`
	Type      string `json:"type"`      // "container", "systemd", "host"
	Running   bool   `json:"running"`
	Detail    string `json:"detail,omitempty"`
}

// StatusReport is the full status output.
type StatusReport struct {
	Services []ServiceStatus `json:"services"`
}

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show service status",
	Long:  `Show the running status of all Zelira services (containers, systemd units, add-ons).`,
	Run: func(cmd *cobra.Command, args []string) {
		report := StatusReport{}

		// Core containers
		for _, name := range []string{"unbound", "pihole", "kea-dhcp4"} {
			s := ServiceStatus{Name: name, Type: "container"}
			status := podmanContainerStatus(name)
			if status != "" {
				s.Running = true
				s.Detail = status
			}
			report.Services = append(report.Services, s)
		}

		// Systemd services
		for _, unit := range []string{"container-unbound", "container-pihole", "container-kea-dhcp4", "dns-healthcheck.timer"} {
			s := ServiceStatus{Name: unit, Type: "systemd"}
			s.Running = systemdIsActive(unit)
			report.Services = append(report.Services, s)
		}

		// Add-on services
		addons := []struct {
			unit string
			kind string
		}{
			{"chronyd", "host"},
			{"chrony", "host"},
			{"caddy", "host"},
			{"container-ddns", "container"},
		}
		for _, addon := range addons {
			if systemdIsEnabled(addon.unit) {
				s := ServiceStatus{Name: addon.unit, Type: addon.kind}
				s.Running = systemdIsActive(addon.unit)
				report.Services = append(report.Services, s)
			}
		}

		if jsonOut {
			b, _ := json.MarshalIndent(report, "", "  ")
			fmt.Println(string(b))
		} else {
			fmt.Println("Zelira Status")
			fmt.Println("═════════════")
			fmt.Println()
			for _, s := range report.Services {
				icon := "✗"
				if s.Running {
					icon = "✓"
				}
				detail := ""
				if s.Detail != "" {
					detail = " (" + s.Detail + ")"
				}
				fmt.Printf("  %s %-30s %s%s\n", icon, s.Name, s.Type, detail)
			}
		}
	},
}

func podmanContainerStatus(name string) string {
	for _, sudo := range []bool{false, true} {
		args := []string{"ps", "--filter", "name=^" + name + "$", "--format", "{{.Status}}"}
		var cmd *exec.Cmd
		if sudo {
			cmd = exec.Command("sudo", append([]string{"podman"}, args...)...)
		} else {
			cmd = exec.Command("podman", args...)
		}
		out, err := cmd.Output()
		if err == nil {
			s := strings.TrimSpace(string(out))
			if s != "" {
				return s
			}
		}
	}
	return ""
}

func systemdIsActive(unit string) bool {
	return exec.Command("systemctl", "is-active", "--quiet", unit).Run() == nil
}

func systemdIsEnabled(unit string) bool {
	return exec.Command("systemctl", "is-enabled", "--quiet", unit).Run() == nil
}
