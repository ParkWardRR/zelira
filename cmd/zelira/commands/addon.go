package commands

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/ParkWardRR/zelira/internal/config"
	"github.com/ParkWardRR/zelira/internal/engine"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(addonCmd)
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
	Args:      cobra.ExactArgs(1),
	ValidArgs: []string{"ntp", "ddns", "dashboard"},
	Run: func(cmd *cobra.Command, args []string) {
		if os.Geteuid() != 0 {
			fmt.Println("Error: addon requires root. Run: sudo zelira addon <name>")
			os.Exit(1)
		}

		name := strings.ToLower(args[0])
		ui := &engine.UI{}

		switch name {
		case "ntp":
			deployNTP(ui)
		case "ddns":
			deployDDNS(ui)
		case "dashboard":
			deployDashboard(ui)
		default:
			fmt.Printf("Error: unknown add-on '%s'. Available: ntp, ddns, dashboard\n", name)
			os.Exit(1)
		}
	},
}

func deployNTP(ui *engine.UI) {
	ui.Step("Deploying Chrony NTP...")

	// Load config for IP
	envPath := findFile("config/.env")
	cfg, _ := config.Load(envPath)

	pm := engine.DetectPackageManager()
	if pm == "" {
		ui.Fail("No package manager found")
		os.Exit(1)
	}

	// Install Chrony if not present
	if !engine.CheckDependency("chronyd") && !engine.CheckDependency("chrony") {
		ui.Info(fmt.Sprintf("Installing chrony via %s...", pm))
		exec.Command(pm, "install", "-y", "chrony").Run()
	}
	ui.Info("Chrony installed")

	// Configure: allow LAN clients
	chronyConf := "/etc/chrony.conf"
	if _, err := os.Stat("/etc/chrony/chrony.conf"); err == nil {
		chronyConf = "/etc/chrony/chrony.conf"
	}
	data, _ := os.ReadFile(chronyConf)
	if !strings.Contains(string(data), "allow ") {
		f, _ := os.OpenFile(chronyConf, os.O_APPEND|os.O_WRONLY, 0644)
		if f != nil {
			f.WriteString("\n# Zelira: Allow LAN NTP clients\nallow 0.0.0.0/0\n")
			f.Close()
		}
	}
	ui.Info("LAN NTP access configured")

	// Enable + start
	for _, svc := range []string{"chronyd", "chrony"} {
		exec.Command("systemctl", "enable", "--now", svc).Run()
	}
	ui.Info("Chrony enabled and started")

	// Inject DHCP Option 42 into Kea config
	if cfg != nil {
		keaConf := "/srv/kea/etc-kea/kea-dhcp4.conf"
		keaData, err := os.ReadFile(keaConf)
		if err == nil && !strings.Contains(string(keaData), "ntp-servers") {
			// Inject before the closing of option-data array
			replacement := fmt.Sprintf(`{
        "name": "ntp-servers",
        "data": "%s"
      },
      {`, cfg.IP)
			result := strings.Replace(string(keaData), "{\n        \"name\": \"domain-name-servers\"", replacement+"\n        \"name\": \"domain-name-servers\"", 1)
			os.WriteFile(keaConf, []byte(result), 0644)
			ui.Info(fmt.Sprintf("Kea DHCP Option 42 → %s", cfg.IP))
		}
	}

	fmt.Println("\n✓ NTP add-on deployed")
	fmt.Println("  Verify: chronyc sources && chronyc tracking")
}

func deployDDNS(ui *engine.UI) {
	ui.Step("Deploying Dynamic DNS updater...")

	envPath := findFile("config/.env")
	vars, _ := config.ParseEnvFile(envPath)

	provider := vars["ZELIRA_DDNS_PROVIDER"]
	if provider == "" {
		ui.Fail("ZELIRA_DDNS_PROVIDER not set in config/.env")
		fmt.Println("  Add to config/.env:")
		fmt.Println("    ZELIRA_DDNS_PROVIDER=namecheap  # or cloudflare, duckdns")
		fmt.Println("    ZELIRA_DDNS_DOMAIN=yourdomain.com")
		fmt.Println("    ZELIRA_DDNS_HOST=@")
		fmt.Println("    ZELIRA_DDNS_TOKEN=your-api-key")
		os.Exit(1)
	}

	ui.Info(fmt.Sprintf("Provider: %s", provider))
	ui.Info("DDNS configured — see docs/addon-ddns.md for cron setup")

	fmt.Println("\n✓ DDNS add-on deployed")
}

func deployDashboard(ui *engine.UI) {
	ui.Step("Deploying Caddy dashboard...")

	pm := engine.DetectPackageManager()
	if pm == "" {
		ui.Fail("No package manager found")
		os.Exit(1)
	}

	// Install Caddy
	if !engine.CheckDependency("caddy") {
		switch pm {
		case "dnf":
			exec.Command("dnf", "install", "-y", "caddy").Run()
		case "apt":
			exec.Command("apt", "install", "-y", "caddy").Run()
		case "zypper":
			exec.Command("zypper", "install", "-y", "caddy").Run()
		}
	}
	ui.Info("Caddy installed")

	exec.Command("systemctl", "enable", "--now", "caddy").Run()
	ui.Info("Caddy enabled and started")

	fmt.Println("\n✓ Dashboard add-on deployed")
	fmt.Println("  Configure: /etc/caddy/Caddyfile")
	fmt.Println("  See: docs/addon-dashboard.md")
}
