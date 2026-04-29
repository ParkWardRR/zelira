# AlmaLinux 10 Full Validation — 2026-04-29

> First validation on RHEL-family distro. Tests Go CLI + deploy.sh + add-ons + auto-recovery.
> **Test host:** `zeliraTest` (`172.16.6.143`), AlmaLinux 10.1 (Heliotrope Lion), Podman 5.6.0

---

## Summary

| # | Test | Status | Notes |
|---|------|--------|-------|
| 1 | Firewall DHCP isolation | ✅ | nftables `zelira_safety`: 4 rules on ens18 |
| 2 | `zelira deploy` (first run) | ✅ | Config validation, image pulls, systemd services — all clean |
| 3 | `zelira health` (Go CLI) | ✅ | 19/19 passed (NTP auto-detected: 3 sources, stratum 3, 0.010ms) |
| 4 | `zelira health --json` | ✅ | Structured JSON output, all fields present |
| 5 | `zelira status` | ✅ | All containers + systemd + chronyd detected |
| 6 | Auto-recovery (kill Unbound) | ✅ | Killed → DNS failed → systemd restarted in <10s → DNS restored |
| 7 | `zelira deploy` (idempotent) | ✅ | Cached images, detected running services, clean restart |
| 8 | Firewall after all tests | ✅ | nftables rules intact |

**Overall: 8/8 tests passed. Production network never impacted.**

---

## Bugs Found and Fixed

### 1. Go version pinning too high

**Problem:** `go.mod` was pinned to `go 1.26.1` (dev machine). AlmaLinux 10 ships Go 1.25.9 via `dnf`.
Build failed with: `go.mod requires go >= 1.26.1 (running go 1.25.9; GOTOOLCHAIN=local)`

**Fix:** Lowered `go.mod` to `go 1.22` since no features newer than that are used.
Commit: `04ea653`

### 2. Go DNS resolver returns IPv6 by default

**Problem:** Go's `net.Resolver.LookupHost` returns AAAA records before A records.
Health check showed `2607:f8b0:4007:807::200e` instead of `142.251.32.174`.
Bash's `dig +short` returns A records by default — mismatch in output.

**Fix:** Added IPv4 preference loop in `dnsLookup()`.
Commit: `89d9396`

---

## Platform Notes — AlmaLinux 10.1

| Item | Details |
|------|---------|
| Package manager | `dnf` (auto-detected by deploy.sh) |
| Go install | `dnf install golang` → Go 1.25.9 |
| Podman | 5.6.0 (newer than openSUSE's 5.4.2) |
| Python | 3.12.11 |
| Kernel | 6.12.0-124 (EL10 kernel) |
| nftables | Native, used for DHCP isolation |
| Chrony | Pre-installed (AlmaLinux default NTP) |

AlmaLinux 10 is the first RHEL-family distro validated. `deploy.sh` correctly detected `dnf` for dependencies.

---

## Go CLI Build Output

```
$ make build
go build -ldflags "-s -w -X .../commands.version=89d9396" -o zelira ./cmd/zelira
$ ls -lh zelira
-rwxr-xr-x. 1 alfa alfa 6.7M zelira
$ ./zelira version
zelira v89d9396
```

---

## Health Check Comparison: Go CLI vs. Bash

| Check | Go CLI | Bash Script | Match? |
|-------|--------|-------------|--------|
| Containers (3) | ✓ | ✓ | ✅ |
| Systemd (4) | ✓ | ✓ | ✅ |
| DNS Unbound | 142.251.32.174 | 142.251.32.174 | ✅ (after IPv4 fix) |
| DNS Pi-hole | 142.251.210.142 | 142.251.210.142 | ✅ |
| DNSSEC | ✓ | ✓ | ✅ |
| Ad-blocking | ✓ (blocked) | ✓ (blocked) | ✅ |
| Ports (4) | ✓ | ✓ | ✅ |
| NTP sources | 3/3 | 3/3 | ✅ |
| NTP stratum | 3 | 3 | ✅ |
| NTP offset | 0.009ms | 0.010ms | ✅ (rounding) |
| Total | 19/19 | 19/19 | ✅ |
