package checker

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Result represents a single health check result.
type Result struct {
	Name    string `json:"name"`
	Group   string `json:"group"`
	Status  string `json:"status"` // "pass", "fail", "warn", "skip"
	Detail  string `json:"detail,omitempty"`
}

// Report is the full health check output.
type Report struct {
	Timestamp string   `json:"timestamp"`
	Results   []Result `json:"results"`
	Passed    int      `json:"passed"`
	Failed    int      `json:"failed"`
	Warnings  int      `json:"warnings"`
	Healthy   bool     `json:"healthy"`
}

func (r *Report) add(group, name, status, detail string) {
	r.Results = append(r.Results, Result{
		Name:   name,
		Group:  group,
		Status: status,
		Detail: detail,
	})
	switch status {
	case "pass":
		r.Passed++
	case "fail":
		r.Failed++
	case "warn":
		r.Warnings++
	}
}

// Run executes all health checks and returns a Report.
func Run() *Report {
	r := &Report{
		Timestamp: time.Now().UTC().Format(time.RFC3339),
	}

	checkContainers(r)
	checkSystemd(r)
	checkDNS(r)
	checkPorts(r)
	checkNTP(r)
	checkCaddy(r)

	r.Healthy = r.Failed == 0
	return r
}

// JSON returns the report as formatted JSON.
func (r *Report) JSON() string {
	b, _ := json.MarshalIndent(r, "", "  ")
	return string(b)
}

// Pretty returns the report as a human-readable string.
func (r *Report) Pretty() string {
	var sb strings.Builder
	sb.WriteString("Zelira Health Check\n")
	sb.WriteString("═══════════════════\n\n")

	currentGroup := ""
	for _, res := range r.Results {
		if res.Group != currentGroup {
			if currentGroup != "" {
				sb.WriteString("\n")
			}
			currentGroup = res.Group
			sb.WriteString(currentGroup + ":\n")
		}
		icon := "✓"
		switch res.Status {
		case "fail":
			icon = "✗"
		case "warn":
			icon = "⚠"
		case "skip":
			icon = "─"
		}
		detail := res.Detail
		if detail != "" {
			detail = " (" + detail + ")"
		}
		sb.WriteString(fmt.Sprintf("  %s %s%s\n", icon, res.Name, detail))
	}

	sb.WriteString("\n═══════════════════\n")
	sb.WriteString(fmt.Sprintf("Results: %d passed, %d failed, %d warnings\n", r.Passed, r.Failed, r.Warnings))
	if r.Healthy {
		sb.WriteString("Status: HEALTHY\n")
	} else {
		sb.WriteString("Status: UNHEALTHY\n")
	}
	return sb.String()
}

// ─── Container Checks ────────────────────────────────

func checkContainers(r *Report) {
	for _, name := range []string{"unbound", "pihole", "kea-dhcp4"} {
		status := podmanStatus(name)
		if status != "" {
			r.add("Containers", name, "pass", status)
		} else {
			r.add("Containers", name+" — NOT RUNNING", "fail", "")
		}
	}
}

func podmanStatus(name string) string {
	// Try rootless first, then root
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

// ─── Systemd Checks ──────────────────────────────────

func checkSystemd(r *Report) {
	for _, svc := range []string{"container-unbound", "container-pihole", "container-kea-dhcp4", "dns-healthcheck.timer"} {
		if systemdActive(svc) {
			r.add("Systemd", svc, "pass", "")
		} else {
			r.add("Systemd", svc, "fail", "")
		}
	}
}

func systemdActive(unit string) bool {
	cmd := exec.Command("systemctl", "is-active", "--quiet", unit)
	return cmd.Run() == nil
}

// ─── DNS Checks ──────────────────────────────────────

func checkDNS(r *Report) {
	// Unbound direct
	if result := dnsLookup("google.com", "127.0.0.1", 5335); result != "" {
		r.add("DNS", fmt.Sprintf("Unbound (127.0.0.1:5335) → %s", result), "pass", "")
	} else {
		r.add("DNS", "Unbound (127.0.0.1:5335) — FAILED", "fail", "")
	}

	// Pi-hole chain
	if result := dnsLookup("google.com", "127.0.0.1", 53); result != "" {
		r.add("DNS", fmt.Sprintf("Pi-hole (127.0.0.1:53) → %s", result), "pass", "")
	} else {
		r.add("DNS", "Pi-hole (127.0.0.1:53) — FAILED", "fail", "")
	}

	// DNSSEC
	if result := dnsLookup("sigok.verteiltesysteme.net", "127.0.0.1", 5335); result != "" {
		r.add("DNS", "DNSSEC validation working", "pass", "")
	} else {
		r.add("DNS", "DNSSEC test inconclusive", "warn", "")
	}

	// Ad-blocking
	adResult := dnsLookup("ads.google.com", "127.0.0.1", 53)
	if adResult == "0.0.0.0" || adResult == "" {
		r.add("DNS", "Ad-blocking active (ads.google.com → blocked)", "pass", "")
	} else {
		r.add("DNS", "Ad-blocking may not be configured", "warn", adResult)
	}
}

func dnsLookup(domain, server string, port int) string {
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			d := net.Dialer{Timeout: 3 * time.Second}
			return d.DialContext(ctx, "udp", fmt.Sprintf("%s:%d", server, port))
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	addrs, err := resolver.LookupHost(ctx, domain)
	if err != nil || len(addrs) == 0 {
		return ""
	}
	return addrs[0]
}

// ─── Port Checks ─────────────────────────────────────

func checkPorts(r *Report) {
	ports := []struct {
		port  int
		label string
		proto string
	}{
		{53, "DNS", "tcp"},
		{80, "Pi-hole Web", "tcp"},
		{5335, "Unbound", "tcp"},
		{67, "DHCP", "udp"},
	}
	for _, p := range ports {
		if portOpen(p.port, p.proto) {
			r.add("Ports", fmt.Sprintf("Port %d (%s)", p.port, p.label), "pass", "")
		} else {
			r.add("Ports", fmt.Sprintf("Port %d (%s) — NOT LISTENING", p.port, p.label), "fail", "")
		}
	}
}

func portOpen(port int, proto string) bool {
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	conn, err := net.DialTimeout(proto, addr, 1*time.Second)
	if err != nil {
		// For UDP, try ss as fallback since UDP "connect" can succeed even if nothing listens
		if proto == "udp" {
			out, _ := exec.Command("ss", "-ulnp").Output()
			return strings.Contains(string(out), fmt.Sprintf(":%d ", port))
		}
		return false
	}
	conn.Close()
	return true
}

// ─── NTP Checks ──────────────────────────────────────

func checkNTP(r *Report) {
	if !systemdActive("chronyd") && !systemdActive("chrony") {
		return // not deployed
	}

	// Source count
	out, err := exec.Command("chronyc", "sources").Output()
	if err != nil {
		r.add("NTP (Chrony)", "chronyc failed", "fail", err.Error())
		return
	}
	lines := strings.Split(string(out), "\n")
	sources := 0
	reachable := 0
	for _, line := range lines {
		if strings.HasPrefix(line, "^") {
			sources++
			fields := strings.Fields(line)
			if len(fields) >= 3 && fields[2] != "?" {
				reachable++
			}
		}
	}
	if sources > 0 {
		r.add("NTP (Chrony)", fmt.Sprintf("%d source(s) configured, %d reachable", sources, reachable), "pass", "")
	} else {
		r.add("NTP (Chrony)", "No NTP sources configured", "fail", "")
	}

	// Stratum
	trackOut, err := exec.Command("chronyc", "tracking").Output()
	if err == nil {
		for _, line := range strings.Split(string(trackOut), "\n") {
			if strings.HasPrefix(line, "Stratum") {
				fields := strings.Fields(line)
				if len(fields) >= 3 {
					stratum, _ := strconv.Atoi(fields[2])
					if stratum > 0 && stratum <= 15 {
						r.add("NTP (Chrony)", fmt.Sprintf("Stratum %d (valid)", stratum), "pass", "")
					} else if stratum == 0 {
						r.add("NTP (Chrony)", "Stratum 0 — not synced", "fail", "")
					}
				}
			}
			if strings.HasPrefix(line, "System time") {
				fields := strings.Fields(line)
				if len(fields) >= 4 {
					offsetSec, _ := strconv.ParseFloat(fields[3], 64)
					offsetMs := offsetSec * 1000
					r.add("NTP (Chrony)", fmt.Sprintf("Clock offset: %.3fms", offsetMs), "pass", "")
				}
			}
		}
	}

	// Port 123
	if portOpen(123, "udp") {
		r.add("NTP (Chrony)", "Port 123/UDP (NTP) listening", "pass", "")
	} else {
		r.add("NTP (Chrony)", "Port 123/UDP not listening", "warn", "LAN clients can't sync")
	}
}

// ─── Caddy Checks ────────────────────────────────────

func checkCaddy(r *Report) {
	if !systemdActive("caddy") {
		return // not deployed
	}

	r.add("Dashboard (Caddy)", "Caddy service running", "pass", "")

	// Check HTTPS port
	if portOpen(443, "tcp") {
		r.add("Dashboard (Caddy)", "Port 443/TCP (HTTPS) listening", "pass", "")

		// TLS cert check
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
					r.add("Dashboard (Caddy)", fmt.Sprintf("TLS cert expires in %d days", daysLeft), "pass", "")
				} else if daysLeft > 0 {
					r.add("Dashboard (Caddy)", fmt.Sprintf("TLS cert expires in %d days", daysLeft), "warn", "renewal needed soon")
				} else {
					r.add("Dashboard (Caddy)", "TLS cert EXPIRED", "fail", "")
				}
			}
		}
	} else if portOpen(8083, "tcp") {
		r.add("Dashboard (Caddy)", "Port 8083/TCP (Dashboard HTTP) listening", "pass", "")
	}

	// HTTP check
	dashURL := "http://127.0.0.1:8083"
	if portOpen(443, "tcp") {
		dashURL = "https://127.0.0.1"
	}
	client := &http.Client{
		Timeout: 3 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}
	resp, err := client.Get(dashURL)
	if err == nil {
		resp.Body.Close()
		if resp.StatusCode == 200 {
			r.add("Dashboard (Caddy)", fmt.Sprintf("Dashboard responding (HTTP %d)", resp.StatusCode), "pass", "")
		} else {
			r.add("Dashboard (Caddy)", fmt.Sprintf("Dashboard returned HTTP %d", resp.StatusCode), "warn", "")
		}
	} else {
		r.add("Dashboard (Caddy)", "Dashboard unreachable", "warn", "")
	}
}
