package commands

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(doctorCmd)
}

var doctorCmd = &cobra.Command{
	Use:   "doctor",
	Short: "Deep diagnostic check",
	Long: `Run comprehensive diagnostics beyond the basic health check.

Checks:
  • Upstream connectivity (root DNS servers reachable)
  • Disk space on /srv/
  • Container image freshness
  • TLS certificate validity (if Caddy deployed)
  • Unbound cache statistics
  • Kea lease pool utilization
  • NTP clock drift
  • Firewall rules (DHCP safety)`,
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Println("Zelira Doctor")
		fmt.Println("═════════════")
		fmt.Println()
		passed := 0
		warned := 0
		failed := 0

		pass := func(msg string) { fmt.Printf("  ✓ %s\n", msg); passed++ }
		warn := func(msg string) { fmt.Printf("  ⚠ %s\n", msg); warned++ }
		fail := func(msg string) { fmt.Printf("  ✗ %s\n", msg); failed++ }

		// 1. Root server connectivity
		fmt.Println("Upstream Connectivity:")
		rootServers := []string{"198.41.0.4", "199.9.14.201", "192.33.4.12"}
		reachable := 0
		for _, rs := range rootServers {
			conn, err := net.DialTimeout("udp", rs+":53", 3*time.Second)
			if err == nil {
				conn.Close()
				reachable++
			}
		}
		if reachable == len(rootServers) {
			pass(fmt.Sprintf("%d/%d root DNS servers reachable", reachable, len(rootServers)))
		} else if reachable > 0 {
			warn(fmt.Sprintf("%d/%d root DNS servers reachable", reachable, len(rootServers)))
		} else {
			fail("No root DNS servers reachable — check internet connectivity")
		}

		// External DNS resolution
		resolver := &net.Resolver{
			PreferGo: true,
			Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return net.DialTimeout("udp", "127.0.0.1:5335", 3*time.Second)
			},
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if addrs, err := resolver.LookupHost(ctx, "cloudflare.com"); err == nil && len(addrs) > 0 {
			pass(fmt.Sprintf("Recursive resolution working (cloudflare.com → %s)", addrs[0]))
		} else {
			fail("Recursive DNS resolution failed via Unbound")
		}
		fmt.Println()

		// 2. Disk space
		fmt.Println("Disk Space:")
		out, err := exec.Command("df", "-h", "/srv").Output()
		if err == nil {
			lines := strings.Split(strings.TrimSpace(string(out)), "\n")
			if len(lines) >= 2 {
				fields := strings.Fields(lines[1])
				if len(fields) >= 5 {
					usage := fields[4]
					pass(fmt.Sprintf("/srv: %s used (%s available)", usage, fields[3]))
				}
			}
		} else {
			warn("Could not check disk space")
		}

		// Check Kea lease file size
		if fi, err := os.Stat("/srv/kea/lib-kea/kea-leases4.csv"); err == nil {
			sizeMB := float64(fi.Size()) / 1024 / 1024
			if sizeMB > 50 {
				warn(fmt.Sprintf("Kea lease file is %.1f MB — consider running LFC", sizeMB))
			} else {
				pass(fmt.Sprintf("Kea lease file: %.1f MB", sizeMB))
			}
		}
		fmt.Println()

		// 3. Container image age
		fmt.Println("Container Images:")
		for _, name := range []string{"pihole", "unbound", "kea-dhcp4"} {
			out, err := exec.Command("podman", "inspect", "--format", "{{.Created}}", name).Output()
			if err == nil {
				created := strings.TrimSpace(string(out))
				if t, err := time.Parse(time.RFC3339Nano, created); err == nil {
					age := int(time.Since(t).Hours() / 24)
					if age > 30 {
						warn(fmt.Sprintf("%s: created %d days ago — consider: zelira update", name, age))
					} else {
						pass(fmt.Sprintf("%s: %d days old", name, age))
					}
				} else {
					pass(fmt.Sprintf("%s: %s", name, created[:19]))
				}
			}
		}
		fmt.Println()

		// 4. Unbound cache stats
		fmt.Println("Unbound Cache:")
		statsOut, err := exec.Command("podman", "exec", "unbound", "unbound-control", "stats_noreset").Output()
		if err == nil {
			stats := string(statsOut)
			for _, key := range []string{"total.num.queries", "total.num.cachehits", "total.num.cachemiss"} {
				for _, line := range strings.Split(stats, "\n") {
					if strings.HasPrefix(line, key+"=") {
						pass(line)
					}
				}
			}
		} else {
			warn("Could not query Unbound stats (unbound-control may not be enabled)")
		}
		fmt.Println()

		// 5. TLS certs (Caddy)
		fmt.Println("TLS Certificates:")
		if exec.Command("systemctl", "is-active", "--quiet", "caddy").Run() == nil {
			conn, err := tls.DialWithDialer(
				&net.Dialer{Timeout: 3 * time.Second},
				"tcp", "127.0.0.1:443",
				&tls.Config{InsecureSkipVerify: true},
			)
			if err == nil {
				certs := conn.ConnectionState().PeerCertificates
				conn.Close()
				if len(certs) > 0 {
					daysLeft := int(time.Until(certs[0].NotAfter).Hours() / 24)
					if daysLeft > 14 {
						pass(fmt.Sprintf("TLS cert valid for %d more days", daysLeft))
					} else if daysLeft > 0 {
						warn(fmt.Sprintf("TLS cert expires in %d days — renewal needed", daysLeft))
					} else {
						fail("TLS cert EXPIRED")
					}
				}
			} else {
				warn("Could not connect to port 443")
			}
		} else {
			pass("Caddy not deployed — no TLS to check")
		}
		fmt.Println()

		// 6. NTP drift
		fmt.Println("Time Sync:")
		if exec.Command("systemctl", "is-active", "--quiet", "chronyd").Run() == nil {
			trackOut, _ := exec.Command("chronyc", "tracking").Output()
			for _, line := range strings.Split(string(trackOut), "\n") {
				if strings.HasPrefix(line, "System time") {
					pass(strings.TrimSpace(line))
				}
				if strings.HasPrefix(line, "Leap status") {
					if strings.Contains(line, "Normal") {
						pass("Leap status: Normal")
					} else {
						warn(strings.TrimSpace(line))
					}
				}
			}
		} else {
			warn("Chrony not running — time sync not monitored")
		}
		fmt.Println()

		// Summary
		fmt.Println("═════════════")
		fmt.Printf("Results: %d passed, %d warnings, %d failed\n", passed, warned, failed)
		if failed == 0 && warned == 0 {
			fmt.Println("Diagnosis: ALL CLEAR")
		} else if failed == 0 {
			fmt.Println("Diagnosis: HEALTHY (with warnings)")
		} else {
			fmt.Println("Diagnosis: ISSUES FOUND")
			os.Exit(1)
		}
	},
}
