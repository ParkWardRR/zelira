# Phase 3–5 Full Test Results — 2026-04-29

> Comprehensive validation of all Phases 3–5 deliverables on the test host.
> **Test host:** `zeliratest` (`172.16.6.142`), openSUSE Leap 16.0, Podman 5.4.2

---

## Summary

| # | Test | Status | Notes |
|---|------|--------|-------|
| 1 | Firewall DHCP isolation | ✅ PASSED | nftables `zelira_safety` table: 4 rules blocking all DHCP on ens18 |
| 2 | `deploy.sh` idempotency | ✅ PASSED | Cached images skipped, existing services detected, clean restart |
| 3 | Expanded health check | ✅ PASSED | 19/19 checks including NTP (stratum, offset, sources, port 123) |
| 4a | Unbound recursive DNS | ✅ PASSED | `google.com → 142.251.218.14` via root servers |
| 4b | Pi-hole full chain | ✅ PASSED | `google.com → 142.251.40.110` via Pi-hole → Unbound |
| 4c | DNSSEC signature | ✅ PASSED | RRSIG records present, NOERROR |
| 4d | Ad-blocking | ✅ PASSED | `ads.google.com → 0.0.0.0` |
| 5 | `deploy-ntp.sh` idempotency | ✅ PASSED | Detected existing config, skipped; re-injected Kea Option 42 |
| 6 | Auto-recovery (kill Unbound) | ✅ PASSED | Killed → DNS failed → systemd restarted → DNS restored in <10s |
| 7 | `deploy-dashboard.sh` first run | ✅ PASSED | Installed Caddy 2.10.0, created dashboard, port 8083 open |
| 8 | Dashboard HTTP check | ✅ PASSED | HTTP 200, 6264 bytes, 1.9ms response time |
| 9 | `deploy-dashboard.sh` idempotency | ✅ PASSED | Detected Caddy installed, port open, config present |
| 10 | Firewall still safe after all tests | ✅ PASSED | nftables `zelira_safety` table intact with all 4 DHCP drop rules |
| 11 | Final health check (with Caddy) | ✅ PASSED | 21/21 passed, 1 warning (Caddy 403 on port 443 — expected, no TLS domain configured) |

**Overall: 14/14 tests passed. Production network never impacted.**

---

## Test Details

### Test 1 — Firewall DHCP Isolation

openSUSE Leap 16 uses nftables natively (iptables/firewalld `--direct` rules don't persist). Created dedicated nftables table:

```
table ip zelira_safety {
    chain output {
        type filter hook output priority filter; policy accept;
        udp dport 68 drop
        udp sport 67 drop
        ip daddr 255.255.255.255 udp sport 67 drop
    }
    chain input {
        type filter hook input priority filter; policy accept;
        iifname "ens18" udp dport 67 drop
    }
}
```

Persisted to `/etc/nftables.d/zelira-safety.nft` with boot-time loading via `nftables.service`.

### Test 2 — deploy.sh Idempotency

Key idempotency behaviors verified:
- **Config validation:** IP/CIDR/interface checks passed immediately
- **Port conflict detection:** Recognized ports 53, 5335, 80 as "Zelira already running"
- **Image cache:** All 3 images showed `(cached)` — no pulls
- **Service management:** Stopped existing services, reinstalled, restarted cleanly
- **Multi-distro:** Detected `zypper` for openSUSE, offered correct package names

### Test 3 — Expanded Health Check (19 checks)

```
Containers:  3/3  ✓
Systemd:     4/4  ✓
DNS:         4/4  ✓  (Unbound, Pi-hole chain, DNSSEC, ad-blocking)
Ports:       4/4  ✓  (53, 80, 5335, 67)
NTP:         4/4  ✓  (7 sources, stratum 3, 0.000ms offset, port 123)
─────────────────
Total:       19/19 HEALTHY
```

### Test 5 — deploy-ntp.sh Idempotency

Second run correctly detected:
- "Chrony already installed"
- "Chrony already configured by Zelira (skipping)"
- "Port 123/UDP already open"
- Re-injected Kea Option 42 (JSON-safe — doesn't duplicate)

### Test 6 — Auto-Recovery

| Step | Action | Result |
|------|--------|--------|
| 6a | DNS before kill | `142.251.218.14` ✓ |
| 6b | `podman stop unbound` | Container stopped |
| 6c | DNS after kill | "connection refused" ✓ (expected) |
| 6d | Wait 10 seconds | systemd `Restart=always` + `RestartSec=5` triggers |
| 6e | Check Unbound | "Up 2 seconds" ✓ |
| 6f | DNS after recovery | `142.251.218.14` ✓ |
| 6g | Full health check | 19/19 HEALTHY ✓ |

### Test 7 — deploy-dashboard.sh

- Installed Caddy 2.10.0 from openSUSE repos (zypper)
- Created dashboard HTML at `/var/www/zelira-dashboard/index.html`
- Configured Caddyfile for `http://172.16.6.142:8083`
- Opened port 8083/tcp via firewalld

### Test 8 — Dashboard HTTP

```
HTTP 200 (6264 bytes, 0.001918s)
```

### Test 11 — Final Health Check (with Caddy)

```
Containers:  3/3   ✓
Systemd:     4/4   ✓
DNS:         4/4   ✓
Ports:       4/4   ✓
NTP:         4/4   ✓
Caddy:       2/2   ✓  (service running, port 443 listening)
─────────────────────
Total:       21/21 HEALTHY (1 warning: Caddy 403 on :443 — no TLS domain configured)
```

---

## Production Network Safety Confirmation

Throughout all 14 tests:
1. **nftables `zelira_safety` table** remained active with 4 DHCP drop rules
2. **No DHCP broadcast** packets reached the LAN from the test host
3. **DNS queries** from the test host used its own Unbound → root servers (never queried production Pi-hole)
4. **Kea DHCP** pool (`172.16.200.x`) never served a lease to any production device
5. **Firewall verified** at the start (Test 1) and end (Test 10) of the test run
