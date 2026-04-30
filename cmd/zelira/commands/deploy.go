package commands

import (
	"fmt"
	"os"
	"time"

	"github.com/ParkWardRR/zelira/internal/config"
	"github.com/ParkWardRR/zelira/internal/embedded"
	"github.com/ParkWardRR/zelira/internal/engine"
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

		ui := &engine.UI{}

		// ─── Load + Validate Config ──────────────
		envPath := findFile("config/.env")
		if envPath == "" {
			fmt.Println("Error: config/.env not found. Copy the template first:")
			fmt.Println("  cp config/env.example config/.env")
			os.Exit(1)
		}

		ui.Step("Validating config/.env...")
		cfg, err := config.Load(envPath)
		if err != nil {
			ui.Fail(err.Error())
			os.Exit(1)
		}

		if errs := cfg.Validate(); len(errs) > 0 {
			for _, e := range errs {
				ui.Fail(e)
			}
			os.Exit(1)
		}
		ui.Info("IP addresses and subnet valid")

		if err := engine.CheckInterface(cfg.Interface); err != nil {
			ui.Fail(err.Error())
			os.Exit(1)
		}
		ui.Info(fmt.Sprintf("Interface %s exists", cfg.Interface))

		// ─── systemd-resolved check ──────────────
		if running, on53 := engine.CheckSystemdResolved(); running {
			if on53 {
				ui.Warn("systemd-resolved IS listening on port 53 — this WILL conflict")
				fmt.Println("  To fix: sudo systemctl disable --now systemd-resolved")
			} else {
				ui.Warn("systemd-resolved running but not on port 53 — probably fine")
			}
		}

		// ─── Port conflicts ──────────────────────
		ui.Step("Checking port conflicts...")
		portIssues := 0
		for _, pc := range []struct{ port int; label string }{
			{53, "DNS (Pi-hole)"}, {5335, "Unbound"}, {67, "DHCP (Kea)"}, {80, "Pi-hole Web"},
		} {
			inUse, isZelira := engine.CheckPortConflict(pc.port)
			if inUse && isZelira {
				ui.Info(fmt.Sprintf("Port %d (%s) — Zelira already running (will restart)", pc.port, pc.label))
			} else if inUse {
				ui.Warn(fmt.Sprintf("Port %d (%s) — already in use", pc.port, pc.label))
				portIssues++
			} else {
				ui.Info(fmt.Sprintf("Port %d (%s) — available", pc.port, pc.label))
			}
		}
		if portIssues > 0 {
			ui.Warn(fmt.Sprintf("%d port conflict(s) detected", portIssues))
		}

		// ─── Banner ──────────────────────────────
		fmt.Printf(`
╔══════════════════════════════════════════╗
║         Zelira Deploy v%s            ║
╠══════════════════════════════════════════╣
║  IP:       %s
║  Gateway:  %s
║  Subnet:   %s
║  DHCP:     %s – %s
║  Domain:   %s
║  TZ:       %s
║  NIC:      %s
╚══════════════════════════════════════════╝
`, version, cfg.IP, cfg.Gateway, cfg.Subnet, cfg.PoolStart, cfg.PoolEnd, cfg.Domain, cfg.TZ, cfg.Interface)

		// ─── Dependencies ────────────────────────
		ui.Step("Checking dependencies...")
		podmanVer := engine.PodmanVersion()
		if podmanVer == "" {
			ui.Fail("podman not found")
			pm := engine.DetectPackageManager()
			if pm != "" {
				fmt.Printf("  Install: sudo %s install podman\n", pm)
			}
			os.Exit(1)
		}
		ui.Info(fmt.Sprintf("podman %s", podmanVer))

		for _, dep := range []string{"dig", "envsubst", "python3"} {
			if engine.CheckDependency(dep) {
				ui.Info(fmt.Sprintf("%s available", dep))
			} else {
				ui.Warn(fmt.Sprintf("%s not found — some features may be limited", dep))
			}
		}

		// ─── Data Directories ────────────────────
		ui.Step("Creating data directories...")
		if err := engine.CreateDataDirs(); err != nil {
			ui.Fail(err.Error())
			os.Exit(1)
		}
		ui.Info("/srv/{pihole,unbound,kea}")

		// ─── Deploy Configs ──────────────────────
		ui.Step("Deploying configs...")

		if err := engine.DeployUnboundConf(embedded.UnboundConf); err != nil {
			ui.Fail(fmt.Sprintf("unbound.conf: %v", err))
			os.Exit(1)
		}
		ui.Info("/srv/unbound/unbound.conf")

		if err := engine.DeployKeaConf(embedded.KeaTemplate, cfg); err != nil {
			ui.Fail(fmt.Sprintf("kea-dhcp4.conf: %v", err))
			os.Exit(1)
		}
		ui.Info("/srv/kea/etc-kea/kea-dhcp4.conf")

		if err := engine.DeployPiholeUpstream(); err != nil {
			ui.Fail(fmt.Sprintf("pihole upstream: %v", err))
			os.Exit(1)
		}
		ui.Info("Pi-hole upstream → Unbound (127.0.0.1#5335)")

		// ─── Pull Images ─────────────────────────
		ui.Step("Pulling container images...")
		for _, img := range engine.Images {
			pulled, err := engine.PullImage(img, false)
			if err != nil {
				ui.Fail(fmt.Sprintf("%s: %v", img, err))
				os.Exit(1)
			}
			if pulled {
				ui.Info(fmt.Sprintf("%s (pulled)", img))
			} else {
				ui.Info(fmt.Sprintf("%s (cached)", img))
			}
		}

		// ─── Stop Existing ───────────────────────
		ui.Step("Managing services...")
		for _, svc := range []string{"container-unbound", "container-pihole", "container-kea-dhcp4"} {
			if engine.StopIfActive(svc) {
				ui.Warn(fmt.Sprintf("Stopping existing %s for upgrade...", svc))
			}
		}

		// ─── Install Units ───────────────────────
		ui.Step("Installing systemd services...")
		units := engine.GenerateUnits(cfg)
		for _, u := range units {
			if err := engine.InstallUnit(u); err != nil {
				ui.Fail(fmt.Sprintf("%s: %v", u.Name, err))
				os.Exit(1)
			}
		}
		ui.Info("container-unbound.service")
		ui.Info("container-pihole.service")
		ui.Info("container-kea-dhcp4.service")

		// ─── Health Check Script ─────────────────
		ui.Step("Installing DNS health check...")
		os.WriteFile("/usr/local/bin/dns-healthcheck.sh", []byte(embedded.HealthCheckScript), 0755)
		ui.Info("dns-healthcheck (runs every 2 min)")

		// ─── Start ───────────────────────────────
		ui.Step("Starting services...")
		engine.SystemdAction("daemon-reload")
		engine.SystemdAction("enable", "--now", "container-unbound.service")
		time.Sleep(3 * time.Second) // Let Unbound init before Pi-hole connects
		engine.SystemdAction("enable", "--now", "container-pihole.service")
		engine.SystemdAction("enable", "--now", "container-kea-dhcp4.service")
		engine.SystemdAction("enable", "--now", "dns-healthcheck.timer")

		fmt.Printf(`
╔══════════════════════════════════════════╗
║          ✓ Zelira Deployed               ║
╠══════════════════════════════════════════╣
║  Pi-hole UI:  http://%s/admin
║  DNS:         %s:53
║  DHCP:        %s–%s
║  Unbound:     127.0.0.1:5335
╚══════════════════════════════════════════╝

Next steps:
  1. Open http://%s/admin (password: %s)
  2. Point your router's DNS at %s
  3. Or disable your router's DHCP and let Kea handle it

Verify with: zelira health
`, cfg.IP, cfg.IP, cfg.PoolStart, cfg.PoolEnd, cfg.IP, cfg.PiholePass, cfg.IP)
	},
}
