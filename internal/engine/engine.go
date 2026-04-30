package engine

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"text/template"

	"github.com/ParkWardRR/zelira/internal/config"
)

// UI provides colored terminal output.
type UI struct{}

func (u *UI) Info(msg string)  { fmt.Printf("  \033[0;32m✓\033[0m %s\n", msg) }
func (u *UI) Warn(msg string)  { fmt.Printf("  \033[1;33m⚠\033[0m %s\n", msg) }
func (u *UI) Fail(msg string)  { fmt.Printf("  \033[0;31m✗\033[0m %s\n", msg) }
func (u *UI) Step(msg string)  { fmt.Printf("\n\033[0;36m→\033[0m %s\n", msg) }

// CheckInterface verifies the network interface exists.
func CheckInterface(name string) error {
	ifaces, err := net.Interfaces()
	if err != nil {
		return err
	}
	for _, iface := range ifaces {
		if iface.Name == name {
			return nil
		}
	}
	var names []string
	for _, iface := range ifaces {
		if iface.Name != "lo" {
			names = append(names, iface.Name)
		}
	}
	return fmt.Errorf("interface '%s' not found. Available: %s", name, strings.Join(names, ", "))
}

// ListInterfaces returns non-loopback interfaces.
func ListInterfaces() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var names []string
	for _, iface := range ifaces {
		if iface.Name != "lo" && iface.Flags&net.FlagLoopback == 0 {
			names = append(names, iface.Name)
		}
	}
	return names
}

// CheckPortConflict checks if a port is in use (and if it's Zelira's own service).
func CheckPortConflict(port int) (inUse bool, zelira bool) {
	out, err := exec.Command("ss", "-tlnp").Output()
	if err != nil {
		return false, false
	}
	portStr := fmt.Sprintf(":%d ", port)
	lines := string(out)
	if !strings.Contains(lines, portStr) {
		// Also check UDP
		outUDP, _ := exec.Command("ss", "-ulnp").Output()
		if !strings.Contains(string(outUDP), portStr) {
			return false, false
		}
	}
	// Check if it's a Zelira container
	for _, name := range []string{"pihole", "unbound", "kea"} {
		if strings.Contains(lines, name) {
			return true, true
		}
	}
	return true, false
}

// CheckSystemdResolved checks if systemd-resolved conflicts.
func CheckSystemdResolved() (running bool, onPort53 bool) {
	if exec.Command("systemctl", "is-active", "--quiet", "systemd-resolved").Run() != nil {
		return false, false
	}
	out, _ := exec.Command("ss", "-tlnp").Output()
	return true, strings.Contains(string(out), ":53 ") && strings.Contains(string(out), "systemd-resolve")
}

// DetectPackageManager returns the system package manager.
func DetectPackageManager() string {
	for _, pm := range []string{"apt", "dnf", "zypper"} {
		if _, err := exec.LookPath(pm); err == nil {
			return pm
		}
	}
	return ""
}

// CheckDependency verifies a command exists.
func CheckDependency(cmd string) bool {
	_, err := exec.LookPath(cmd)
	return err == nil
}

// PodmanVersion returns the podman version string.
func PodmanVersion() string {
	out, err := exec.Command("podman", "--version").Output()
	if err != nil {
		return ""
	}
	parts := strings.Fields(strings.TrimSpace(string(out)))
	if len(parts) >= 3 {
		return parts[2]
	}
	return strings.TrimSpace(string(out))
}

// ─── Directory + Config Management ───────────────────

// CreateDataDirs creates /srv/{pihole,unbound,kea} directories.
func CreateDataDirs() error {
	dirs := []string{
		"/srv/pihole/etc-pihole",
		"/srv/pihole/etc-dnsmasq.d",
		"/srv/unbound",
		"/srv/kea/etc-kea",
		"/srv/kea/lib-kea",
		"/srv/kea/sockets",
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0755); err != nil {
			return fmt.Errorf("mkdir %s: %w", d, err)
		}
	}
	return os.Chmod("/srv/kea/sockets", 0750)
}

// DeployUnboundConf writes the unbound config.
func DeployUnboundConf(confContent string) error {
	return os.WriteFile("/srv/unbound/unbound.conf", []byte(confContent), 0644)
}

// DeployKeaConf templates and writes the Kea config.
func DeployKeaConf(templateContent string, cfg *config.Config) error {
	// Replace ${VAR} with values
	result := templateContent
	for k, v := range cfg.Vars() {
		result = strings.ReplaceAll(result, "${"+k+"}", v)
	}
	// Strip comment lines (// ...)
	var lines []string
	for _, line := range strings.Split(result, "\n") {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "//") {
			lines = append(lines, line)
		}
	}
	result = strings.Join(lines, "\n")
	return os.WriteFile("/srv/kea/etc-kea/kea-dhcp4.conf", []byte(result), 0644)
}

// DeployPiholeUpstream writes the upstream config file.
func DeployPiholeUpstream() error {
	content := `# Zelira: Pi-hole forwards exclusively to local Unbound
# Do NOT use any third-party upstream DNS
server=127.0.0.1#5335
`
	return os.WriteFile("/srv/pihole/etc-dnsmasq.d/99-zelira-upstream.conf", []byte(content), 0644)
}

// ─── Container Images ────────────────────────────────

var Images = []string{
	"docker.io/pihole/pihole:latest",
	"docker.io/klutchell/unbound:latest",
	"docker.io/jonasal/kea-dhcp4:2.6",
}

// PullImage pulls a container image if not cached.
func PullImage(image string, force bool) (pulled bool, err error) {
	if !force {
		if exec.Command("podman", "image", "exists", image).Run() == nil {
			return false, nil
		}
	}
	cmd := exec.Command("podman", "pull", image)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return true, cmd.Run()
}

// ─── Systemd Services ────────────────────────────────

type ServiceUnit struct {
	Name     string
	Content  string
}

// GenerateUnits creates systemd unit file contents.
func GenerateUnits(cfg *config.Config) []ServiceUnit {
	unboundUnit := `[Unit]
Description=Zelira — Unbound Recursive DNS
Wants=network-online.target
After=network-online.target

[Service]
Restart=always
RestartSec=5
TimeoutStopSec=30
ExecStartPre=-/usr/bin/podman rm -f unbound
ExecStart=/usr/bin/podman run \
    --rm \
    --name unbound \
    --network host \
    -v /srv/unbound/unbound.conf:/etc/unbound/unbound.conf:ro,Z \
    docker.io/klutchell/unbound:latest \
    -d -c /etc/unbound/unbound.conf
ExecStop=/usr/bin/podman stop -t 10 unbound
Type=simple

[Install]
WantedBy=multi-user.target
`
	piholeUnit := fmt.Sprintf(`[Unit]
Description=Zelira — Pi-hole DNS Ad-Blocker
Wants=network-online.target
After=network-online.target container-unbound.service
Requires=container-unbound.service

[Service]
Restart=always
RestartSec=5
TimeoutStopSec=30
ExecStartPre=-/usr/bin/podman rm -f pihole
ExecStart=/usr/bin/podman run \
    --rm \
    --name pihole \
    --network host \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    -e TZ=%s \
    -e FTLCONF_webserver_api_password=%s \
    -v /srv/pihole/etc-pihole:/etc/pihole:Z \
    -v /srv/pihole/etc-dnsmasq.d:/etc/dnsmasq.d:Z \
    --dns 127.0.0.1 \
    --dns %s \
    docker.io/pihole/pihole:latest
ExecStop=/usr/bin/podman stop -t 10 pihole
Type=simple

[Install]
WantedBy=multi-user.target
`, cfg.TZ, cfg.PiholePass, cfg.FallbackDNS)

	keaUnit := `[Unit]
Description=Zelira — Kea DHCPv4 Server
Wants=network-online.target
After=network-online.target

[Service]
Restart=always
RestartSec=5
TimeoutStopSec=30
ExecStartPre=-/usr/bin/podman rm -f kea-dhcp4
ExecStart=/usr/bin/podman run \
    --rm \
    --name kea-dhcp4 \
    --network host \
    --pid host \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    -v /srv/kea/etc-kea:/etc/kea:Z \
    -v /srv/kea/lib-kea:/kea/leases:Z \
    -v /srv/kea/sockets:/kea/sockets:Z \
    docker.io/jonasal/kea-dhcp4:2.6 \
    -c /etc/kea/kea-dhcp4.conf
ExecStop=/usr/bin/podman stop -t 10 kea-dhcp4
Type=simple

[Install]
WantedBy=multi-user.target
`
	healthService := `[Unit]
Description=Zelira — DNS Health Check
After=container-unbound.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dns-healthcheck.sh
`
	healthTimer := `[Unit]
Description=Zelira — DNS Health Check Timer (every 2 min)

[Timer]
OnBootSec=60
OnUnitActiveSec=120
AccuracySec=10

[Install]
WantedBy=timers.target
`
	return []ServiceUnit{
		{Name: "container-unbound.service", Content: unboundUnit},
		{Name: "container-pihole.service", Content: piholeUnit},
		{Name: "container-kea-dhcp4.service", Content: keaUnit},
		{Name: "dns-healthcheck.service", Content: healthService},
		{Name: "dns-healthcheck.timer", Content: healthTimer},
	}
}

// InstallUnit writes a systemd unit file.
func InstallUnit(unit ServiceUnit) error {
	path := "/etc/systemd/system/" + unit.Name
	return os.WriteFile(path, []byte(unit.Content), 0644)
}

// SystemdAction runs a systemctl command.
func SystemdAction(action string, units ...string) error {
	args := append([]string{action}, units...)
	cmd := exec.Command("systemctl", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// StopIfActive stops a systemd unit if it's running.
func StopIfActive(unit string) bool {
	if exec.Command("systemctl", "is-active", "--quiet", unit).Run() == nil {
		exec.Command("systemctl", "stop", unit).Run()
		return true
	}
	return false
}

// RemoveContainer force-removes a podman container.
func RemoveContainer(name string) bool {
	return exec.Command("podman", "rm", "-f", name).Run() == nil
}

// ─── Templating ──────────────────────────────────────

// ExpandTemplate processes a Go template string with config vars.
func ExpandTemplate(name, tmpl string, data interface{}) (string, error) {
	t, err := template.New(name).Parse(tmpl)
	if err != nil {
		return "", err
	}
	var sb strings.Builder
	if err := t.Execute(&sb, data); err != nil {
		return "", err
	}
	return sb.String(), nil
}
