package commands

import (
	"fmt"
	"os"

	"github.com/ParkWardRR/zelira/internal/config"
	"github.com/ParkWardRR/zelira/internal/engine"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(validateCmd)
}

var validateCmd = &cobra.Command{
	Use:   "validate",
	Short: "Pre-flight config check without deploying",
	Long: `Validate config/.env and the host environment without deploying anything.

Checks:
  • Required variables are set
  • IP addresses and CIDR subnet are valid
  • DHCP pool range is sane
  • Network interface exists
  • Port conflicts
  • systemd-resolved conflicts
  • Required dependencies (podman, dig, envsubst)`,
	Run: func(cmd *cobra.Command, args []string) {
		ui := &engine.UI{}
		passed := 0
		failed := 0

		pass := func(msg string) { ui.Info(msg); passed++ }
		fail := func(msg string) { ui.Fail(msg); failed++ }

		// Config file
		envPath := findFile("config/.env")
		if envPath == "" {
			fail("config/.env not found")
			printResult(passed, failed)
			os.Exit(1)
		}
		pass("config/.env found")

		// Parse
		cfg, err := config.Load(envPath)
		if err != nil {
			fail(err.Error())
			printResult(passed, failed)
			os.Exit(1)
		}
		pass("All required variables set")

		// Validate
		if errs := cfg.Validate(); len(errs) > 0 {
			for _, e := range errs {
				fail(e)
			}
		} else {
			pass("IP addresses and CIDR valid")
			pass("DHCP pool range valid")
		}

		// Interface
		if err := engine.CheckInterface(cfg.Interface); err != nil {
			fail(err.Error())
		} else {
			pass(fmt.Sprintf("Interface %s exists", cfg.Interface))
		}

		// systemd-resolved
		if running, on53 := engine.CheckSystemdResolved(); running && on53 {
			fail("systemd-resolved is listening on port 53 — will conflict")
		} else if running {
			ui.Warn("systemd-resolved running but not on port 53")
		} else {
			pass("No systemd-resolved conflict")
		}

		// Port conflicts
		for _, pc := range []struct{ port int; label string }{
			{53, "DNS"}, {5335, "Unbound"}, {67, "DHCP"}, {80, "Pi-hole Web"},
		} {
			inUse, isZelira := engine.CheckPortConflict(pc.port)
			if inUse && !isZelira {
				fail(fmt.Sprintf("Port %d (%s) in use by non-Zelira process", pc.port, pc.label))
			} else {
				pass(fmt.Sprintf("Port %d (%s) available", pc.port, pc.label))
			}
		}

		// Dependencies
		for _, dep := range []string{"podman", "dig", "envsubst"} {
			if engine.CheckDependency(dep) {
				pass(fmt.Sprintf("%s found", dep))
			} else {
				fail(fmt.Sprintf("%s not found", dep))
			}
		}

		printResult(passed, failed)
		if failed > 0 {
			os.Exit(1)
		}
	},
}

func printResult(passed, failed int) {
	fmt.Printf("\n%d passed, %d failed\n", passed, failed)
	if failed == 0 {
		fmt.Println("Ready to deploy: sudo zelira deploy")
	}
}
