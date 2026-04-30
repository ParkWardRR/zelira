# Zelira — Roadmap

> Project history, current status, and what's next.

---

## Design Principles

1. **Every config value has a reason.** If a value is set, there's a production incident behind it.
2. **One command to deploy, one command to verify.** `sudo zelira deploy` and `zelira health`.
3. **No external dependencies at runtime.** DNS from root servers. DHCP is local. NTP from pool.ntp.org.
4. **Survive power outages gracefully.** Stale cache, auto-recovery timers, correct boot ordering.
5. **Podman + systemd, not Docker + Compose.** Fewer moving parts, no daemon.
6. **Document the failures, not just the successes.**

---

## Origin

Zelira was extracted from a production home network stack — 40+ clients, 7 APs, managed switches, NVR cameras, IoT devices, and hypervisors — all depending on a single Raspberry Pi 5 for DNS and DHCP. Every config value and auto-recovery mechanism exists because something broke in production.

The decision to publish came from realizing that every "Pi-hole + Unbound" guide online stops at `docker-compose up` and never addresses what happens when the power goes out, when Unbound's infra cache poisons itself, or when Pi-hole's FTL engine silently drops 105 TCP connections per hour.

---

## What's Been Done

### Phase 0 — Production Hardening

*Running on a real network for months before Zelira existed as a project.*

| Event | Impact |
|-------|--------|
| Pi-hole + Unbound deployed on RPi5 (arm64, 8 GB) | Core DNS operational |
| Migrated Docker + Compose → Podman + systemd | Eliminated daemon as single point of failure |
| Migrated ISC DHCP (`dhcpd`) → Kea DHCPv4 | ISC DHCP end-of-life; Kea has JSON config + REST API |
| **Incident:** Unbound SERVFAIL death spiral after power outage | Fixed with `infra-host-ttl: 60` + `serve-expired` + auto-recovery timer |
| **Incident:** Pi-hole FTL TCP connection storms (105/hr) | Fixed with `tcp-idle-timeout: 120000` + `incoming-num-tcp: 20` |
| **Incident:** Pi-hole v6 dual DNS source conflict | Documented as Pitfall #3 |
| DHCP Snooping dropped Kea packets on managed switch | Documented as Pitfall #4 |
| Kea exporter crash loop (missing control socket) | Fixed in default Kea template |
| Added Caddy, Dynamic DNS, Chrony NTP | Full stack for production homelab |

### Phase 1 — Public Release

| Date | Commit | Milestone |
|------|--------|-----------|
| 2026-04-29 | `fbd6f98` | Initial release: core stack, deploy script, health check, uninstall |
| 2026-04-29 | `2eb4429` | Mermaid diagrams: DNS flow, ad-blocking, auto-recovery, boot chain |
| 2026-04-29 | `490b8c7` | Add-on docs: NTP (Chrony), Dynamic DNS, Landing Page (Caddy) |
| 2026-04-29 | `6be7d5d` | Testing framework: isolated DHCP test, firewall safety |

### Phase 2 — Validation ✅

*Full end-to-end testing on `zeliratest` (openSUSE Leap 16.0, Podman 5.4.2).*

| Test | Result |
|------|--------|
| Full `deploy.sh` end-to-end | 15/15 health checks; found & fixed 3 bugs |
| DNS: Pi-hole → Unbound → root servers (DNSSEC) | Recursive resolution, RRSIG verified, ads blocked |
| Auto-recovery: kill Unbound, verify restart | systemd auto-restarted in <10s |
| Boot ordering: cold reboot | All containers healthy, firewall persisted |
| Chrony NTP | 7 sources, stratum 3, <1ms offset |

> Full log: [testing/results/phase2-validation-2026-04-29.md](../testing/results/phase2-validation-2026-04-29.md)

### Phase 3 — Hardening ✅

| Item | Result |
|------|--------|
| `deploy.sh` idempotency | Cached image skipping, safe re-runs, existing service detection |
| Multi-distro support | apt/zypper/dnf detection for podman, dig, envsubst |
| Config validation | IP/CIDR/interface/port conflict pre-flight checks |
| Kea JSON validation | `python3 -m json.tool` after envsubst + comment stripping |
| systemd-resolved detection | Auto-detects port 53 conflict; prompts user with fix |

### Phase 4 — Add-on Integration ✅

| Item | Result |
|------|--------|
| Add-on deploy scripts | `deploy-ntp.sh`, `deploy-ddns.sh`, `deploy-dashboard.sh` — all idempotent |
| Unified `.env` | Add-on config in `env.example` with optional sections |
| Kea Option 42 | `deploy-ntp.sh` auto-injects NTP server IP into Kea config |
| Health check expansion | NTP (stratum, offset, sources), DDNS (container, logs), Caddy (TLS expiry, HTTP) |
| Metrics framework | Documented in [addon-metrics.md](addon-metrics.md) |

### Phase 5 — Community ✅

| Item | Result |
|------|--------|
| Contributing guide | [CONTRIBUTING.md](../CONTRIBUTING.md) — ground rules, code style, PR process |
| Example configs | `config/examples/` — apartment, house, homelab-with-VLANs |
| Migration guide | [migration-from-docker.md](migration-from-docker.md) — Docker Compose → Zelira |

### Phase 6 — Documentation ✅

| Item | Result |
|------|--------|
| Zelira vs. Alternatives | [comparison.md](comparison.md) — vs Pi-hole, AdGuard Home, Technitium (feature matrix, trade-offs) |
| README overhaul | Updated architecture tree, health check output (19→21 checks), Quick Start with example configs + add-on commands |
| Testing docs | Validation logs for openSUSE Leap 16, AlmaLinux 10.1 |

---

## What's Next

### Near-Term

| Priority | Item | Description |
|----------|------|-------------|
| 🟡 | **CI/CD** | GitHub Actions: ShellCheck, isolated DHCP test |
| ✅ | ~~**Fedora/RHEL testing**~~ | Validated on AlmaLinux 10.1 (Podman 5.6.0, Go 1.25.9) |
| 🟡 | **Docker fallback** | Optional Docker-compatible mode for non-Podman hosts |

### Phase 7 — Go CLI ✅

Single static binary replacing all shell scripts. Cross-compiled for arm64 + amd64.

```
zelira deploy              # full stack deploy (idempotent)
zelira health              # run all health checks
zelira health --json       # structured output for monitoring
zelira addon ntp           # deploy Chrony NTP add-on
zelira addon ddns          # deploy Dynamic DNS add-on
zelira addon dashboard     # deploy Caddy dashboard add-on
zelira status              # container + service status
zelira status --json       # machine-readable for Prometheus/scripts
zelira uninstall           # clean removal
```

| Status | Item | Description |
|--------|------|-------------|
| ✅ | **CLI scaffold** | cobra-based subcommands, `--json` global flag, version |
| ✅ | **`zelira health`** | Native Go: DNS via net.Resolver, port checks, NTP parsing, TLS cert inspection |
| ✅ | **`zelira health --json`** | Structured JSON with timestamp, per-check status, pass/fail/warn counts |
| ✅ | **`zelira status`** | Native Go: container + systemd + add-on service detection |
| ✅ | **`zelira status --json`** | Machine-readable service inventory |
| ✅ | **Cross-compilation** | `make all` → 6.8 MB (amd64), 6.3 MB (arm64) |
| ✅ | **AlmaLinux validation** | Built + tested on Go 1.25.9 (dnf); found/fixed 2 bugs |
| ✅ | **`zelira deploy`** | Native Go: .env parsing, config validation, Podman, systemd unit generation |
| ✅ | **`zelira addon`** | Native Go: NTP (Chrony + Option 42), DDNS, Dashboard (Caddy) |
| 🟡 | **GitHub Releases** | Automated binary builds via GitHub Actions |

### Phase 8 — Go CLI Feature Expansion ✅

All new commands implemented and tested on AlmaLinux 10.1.

#### Native Ports (bash eliminated)

| Status | Item | Description |
|--------|------|-------------|
| ✅ | **`zelira deploy` (native)** | .env parsing, config validation, Podman API, systemd unit generation, embedded configs |
| ✅ | **`zelira addon` (native)** | NTP: Chrony + Kea Option 42 injection. DDNS: config validation. Dashboard: Caddy install |
| ✅ | **`zelira uninstall` (native)** | Stop, disable, remove containers + units. `--purge` flag for data cleanup |

#### New Features

| Status | Item | Description |
|--------|------|-------------|
| ✅ | **`zelira validate`** | Pre-flight: .env, IPs, CIDR, interface, ports, systemd-resolved, dependencies — 13 checks |
| ✅ | **`zelira init`** | Interactive wizard: detect interfaces, suggest IPs/pools, generate `.env` |
| ✅ | **`zelira logs`** | Unified journalctl viewer: `-s pihole`, `-n 200`, `-f` (follow) |
| ✅ | **`zelira backup`** | tar.gz export: /srv/ data, systemd units, .env (34 files, 2.9 MB on test host) |
| ✅ | **`zelira restore`** | tar.gz import with idempotent extraction |
| ✅ | **`zelira update`** | Force-pull images, restart in dependency order, auto-verify health |
| ✅ | **`zelira doctor`** | Deep diagnostics: root servers, disk, container age, Unbound cache, TLS, NTP drift |
| ✅ | **Embedded configs** | `go:embed` for unbound.conf, kea template, healthcheck — true single-file deploy |

### Future

| Priority | Item | Description |
|----------|------|-------------|
| 🟢 | **NixOS module** | Declarative deployment |
| 🟢 | **Ansible playbook** | Config management alternative |
| 🟢 | **`zelira metrics serve`** | Long-running Prometheus exporter with textfile collectors |

---

## Incident → Feature Map

Every Zelira feature traces back to a real failure:

| Incident | Zelira Feature |
|----------|----------------|
| Unbound SERVFAIL after power outage (15-min blackout) | `serve-expired=yes`, `infra-host-ttl=60`, `dns-healthcheck.timer` |
| Pi-hole TCP storms (105 errors/hr) | `tcp-idle-timeout=120000`, `incoming/outgoing-num-tcp=20` |
| Pi-hole v6 dual DNS source conflict | Documented in Pitfall #3 |
| DHCP Snooping dropping Kea packets | Documented in Pitfall #4 |
| Kea exporter crash (missing control socket) | `control-socket` in default Kea template |
| Pi-hole started before Unbound was ready | `Requires=container-unbound.service` + 3s sleep |
| Port 53 conflict with systemd-resolved | Documented in Pitfall #6 |

---

## Non-Goals

| Non-Goal | Why |
|----------|-----|
| **Web-based config UI** | `.env` is the single source of truth. A UI adds complexity |
| **IPv6 DHCP (DHCPv6)** | IPv6 RA/SLAAC works without managed DHCPv6 |
| **Multi-node clustering** | Single-box deployment. Use keepalived for HA |
| **DoH / DoT** | Zelira resolves recursively — no upstream to encrypt to |
| **Container orchestration** | No Kubernetes, no Compose. systemd is the orchestrator |
| **VPN integration** | DNS/DHCP concern only; VPN belongs on the router |
