package config

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strings"
)

// Config holds all Zelira configuration values.
type Config struct {
	IP            string
	Gateway       string
	Subnet        string
	PoolStart     string
	PoolEnd       string
	Domain        string
	Interface     string
	TZ            string
	PiholePass    string
	FallbackDNS   string
}

// Required returns the names of all required fields.
func Required() []string {
	return []string{
		"ZELIRA_IP", "ZELIRA_GATEWAY", "ZELIRA_SUBNET",
		"ZELIRA_POOL_START", "ZELIRA_POOL_END", "ZELIRA_DOMAIN",
		"ZELIRA_TZ", "ZELIRA_PIHOLE_PASSWORD", "ZELIRA_INTERFACE",
	}
}

// Load reads config/.env and returns a Config.
func Load(path string) (*Config, error) {
	vars, err := ParseEnvFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}

	var missing []string
	for _, key := range Required() {
		if vars[key] == "" {
			missing = append(missing, key)
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("missing required variables: %s", strings.Join(missing, ", "))
	}

	fallback := vars["ZELIRA_FALLBACK_DNS"]
	if fallback == "" {
		fallback = "1.1.1.1"
	}

	return &Config{
		IP:          vars["ZELIRA_IP"],
		Gateway:     vars["ZELIRA_GATEWAY"],
		Subnet:      vars["ZELIRA_SUBNET"],
		PoolStart:   vars["ZELIRA_POOL_START"],
		PoolEnd:     vars["ZELIRA_POOL_END"],
		Domain:      vars["ZELIRA_DOMAIN"],
		Interface:   vars["ZELIRA_INTERFACE"],
		TZ:          vars["ZELIRA_TZ"],
		PiholePass:  vars["ZELIRA_PIHOLE_PASSWORD"],
		FallbackDNS: fallback,
	}, nil
}

// ParseEnvFile reads a .env file into a map.
func ParseEnvFile(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	vars := make(map[string]string)
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])
		// Strip surrounding quotes
		val = strings.Trim(val, `"'`)
		vars[key] = val
	}
	return vars, scanner.Err()
}

// Validate checks all config values for correctness.
func (c *Config) Validate() []string {
	var errs []string

	// IP addresses
	for _, check := range []struct{ val, label string }{
		{c.IP, "ZELIRA_IP"},
		{c.Gateway, "ZELIRA_GATEWAY"},
		{c.PoolStart, "ZELIRA_POOL_START"},
		{c.PoolEnd, "ZELIRA_POOL_END"},
	} {
		if net.ParseIP(check.val) == nil {
			errs = append(errs, fmt.Sprintf("%s (%s) is not a valid IP address", check.label, check.val))
		}
	}

	// CIDR subnet
	_, _, err := net.ParseCIDR(c.Subnet)
	if err != nil {
		errs = append(errs, fmt.Sprintf("ZELIRA_SUBNET (%s) is not valid CIDR: %v", c.Subnet, err))
	}

	// Pool range sanity
	start := net.ParseIP(c.PoolStart)
	end := net.ParseIP(c.PoolEnd)
	if start != nil && end != nil {
		s4 := start.To4()
		e4 := end.To4()
		if s4 != nil && e4 != nil {
			si := uint32(s4[0])<<24 | uint32(s4[1])<<16 | uint32(s4[2])<<8 | uint32(s4[3])
			ei := uint32(e4[0])<<24 | uint32(e4[1])<<16 | uint32(e4[2])<<8 | uint32(e4[3])
			if si > ei {
				errs = append(errs, fmt.Sprintf("DHCP pool start (%s) > end (%s)", c.PoolStart, c.PoolEnd))
			}
		}
	}

	// Domain
	if strings.Contains(c.Domain, " ") || len(c.Domain) == 0 {
		errs = append(errs, fmt.Sprintf("ZELIRA_DOMAIN (%s) is invalid", c.Domain))
	}

	return errs
}

// Vars returns the config as an environment variable map (for templating).
func (c *Config) Vars() map[string]string {
	return map[string]string{
		"ZELIRA_IP":              c.IP,
		"ZELIRA_GATEWAY":        c.Gateway,
		"ZELIRA_SUBNET":         c.Subnet,
		"ZELIRA_POOL_START":     c.PoolStart,
		"ZELIRA_POOL_END":       c.PoolEnd,
		"ZELIRA_DOMAIN":         c.Domain,
		"ZELIRA_INTERFACE":      c.Interface,
		"ZELIRA_TZ":             c.TZ,
		"ZELIRA_PIHOLE_PASSWORD": c.PiholePass,
		"ZELIRA_FALLBACK_DNS":   c.FallbackDNS,
	}
}
