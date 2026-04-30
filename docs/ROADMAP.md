# Zelira — Roadmap

> Project history, current status, and what's next.

---

## Design Principles

1. **Every config value has a reason.** If a value is set, there's a production incident behind it.
2. **One command to deploy, one command to verify.** `sudo zelira deploy` and `zelira health`.
3. **No external dependencies at runtime.** DNS from root servers. DHCP is local. NTP from pool.ntp.org.
4. **Survive power outages gracefully.** Stale cache, auto-recovery timers, correct boot ordering.
5. **Podman + systemd, not Docker + Compose.** Fewer moving parts, no daemon.
6. **Single binary, zero bash at runtime.** The Go CLI embeds all configs and replaces all shell scripts.
7. **Document the failures, not just the successes.**

---

## Origin

Zelira was extracted from a production home network stack — 40+ clients, 7 APs, managed switches, NVR cameras, IoT devices, and hypervisors — all depending on a single Raspberry Pi 5 for DNS and DHCP. Every config value and auto-recovery mechanism exists because something broke in production.

The decision to publish came from realizing that every "Pi-hole + Unbound" guide online stops at `docker-compose up` and never addresses what happens when the power goes out, when Unbound's infra cache poisons itself, or when Pi-hole's FTL engine silently drops 105 TCP connections per hour.

---

## Completed

### Phase 1 — Foundation

*Production hardening + first public release.*

| Event | Impact |
|-------|--------|
| Pi-hole + Unbound deployed on RPi5 (arm64, 8 GB) | Core DNS operational |
| Migrated Docker + Compose → Podman + systemd | Eliminated daemon as single point of failure |
| Migrated ISC DHCP (`dhcpd`) → Kea DHCPv4 | ISC DHCP end-of-life; Kea has JSON config + REST API |
| **Incident:** Unbound SERVFAIL death spiral after power outage | Fixed with `infra-host-ttl: 60` + `serve-expired` + auto-recovery timer |
| **Incident:** Pi-hole FTL TCP connection storms (105/hr) | Fixed with `tcp-idle-timeout: 120000` + `incoming-num-tcp: 20` |
| **Incident:** Pi-hole v6 dual DNS source conflict | Documented as Pitfall #3 |
| DHCP Snooping dropped Kea packets on managed switch | Documented as Pitfall #4 |
| Initial public release | Core stack, deploy script, health check, uninstall |
| Mermaid diagrams | DNS flow, ad-blocking, auto-recovery, boot chain |

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

### Phase 4 — Add-ons ✅

| Item | Result |
|------|--------|
| Add-on deploy scripts | `deploy-ntp.sh`, `deploy-ddns.sh`, `deploy-dashboard.sh` |
| Unified `.env` | Add-on config in `env.example` with optional sections |
| Kea Option 42 | NTP server IP auto-injected into Kea config |
| Health check expansion | NTP, DDNS, Caddy checks added |
| Metrics framework | Documented in [addon-metrics.md](addon-metrics.md) |

### Phase 5 — Community ✅

| Item | Result |
|------|--------|
| Contributing guide | [CONTRIBUTING.md](../CONTRIBUTING.md) |
| Example configs | `config/examples/` — apartment, house, homelab |
| Migration guide | [migration-from-docker.md](migration-from-docker.md) |

### Phase 6 — Documentation ✅

| Item | Result |
|------|--------|
| Zelira vs. Alternatives | [comparison.md](comparison.md) |
| README overhaul | Architecture diagrams, health output, Quick Start |
| Testing docs | Validation logs for openSUSE 16 + AlmaLinux 10.1 |

### Phase 7 — Go CLI ✅

*Single static binary replacing all shell scripts. Cross-compiled for arm64 + amd64.*

```
zelira deploy              # full stack deploy (idempotent)
zelira health              # run all health checks
zelira health --json       # structured output for monitoring
zelira addon ntp           # deploy Chrony NTP add-on
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
| ✅ | **`zelira deploy`** | Native Go: .env parsing, config validation, Podman, systemd unit generation |
| ✅ | **`zelira addon`** | Native Go: NTP (Chrony + Option 42), DDNS, Dashboard (Caddy) |
| ✅ | **Cross-compilation** | `make all` → 6.8 MB (amd64), 6.3 MB (arm64) |
| ✅ | **AlmaLinux validation** | Built + tested on Go 1.25.9 (dnf); found/fixed 2 bugs |

### Phase 8 — Feature Expansion ✅

*All new commands implemented and tested on AlmaLinux 10.1.*

| Status | Item | Description |
|--------|------|-------------|
| ✅ | **`zelira deploy` (native)** | .env parsing, config validation, Podman API, systemd unit generation, embedded configs |
| ✅ | **`zelira addon` (native)** | NTP: Chrony + Kea Option 42 injection. DDNS: config validation. Dashboard: Caddy install |
| ✅ | **`zelira uninstall` (native)** | Stop, disable, remove containers + units. `--purge` flag for data cleanup |
| ✅ | **`zelira validate`** | Pre-flight: .env, IPs, CIDR, interface, ports, systemd-resolved, dependencies — 13 checks |
| ✅ | **`zelira init`** | Interactive wizard: detect interfaces, suggest IPs/pools, generate `.env` |
| ✅ | **`zelira logs`** | Unified journalctl viewer: `-s pihole`, `-n 200`, `-f` (follow) |
| ✅ | **`zelira backup`** | tar.gz export: /srv/ data, systemd units, .env (34 files, 2.9 MB on test host) |
| ✅ | **`zelira restore`** | tar.gz import with idempotent extraction |
| ✅ | **`zelira update`** | Force-pull images, restart in dependency order, auto-verify health |
| ✅ | **`zelira doctor`** | Deep diagnostics: root servers, disk, container age, Unbound cache, TLS, NTP drift |
| ✅ | **Embedded configs** | `go:embed` for unbound.conf, kea template, healthcheck — true single-file deploy |

> Full validation log: [testing/results/go-cli-v0.2.0-validation-2026-04-30.md](../testing/results/go-cli-v0.2.0-validation-2026-04-30.md)

---

## What's Next

### Phase 9 — CI/CD & Release Engineering

Automate quality gates and deliver the CLI as downloadable release binaries.

#### CI Pipeline

| Status | Item | Description |
|--------|------|-------------|
| 🔴 | **GitHub Actions: Go build** | Build + unit test on push/PR for `linux/amd64`, `linux/arm64`, `darwin/arm64` |
| 🔴 | **GitHub Actions: ShellCheck** | Lint remaining bash scripts (deploy-*.sh, health-check.sh) |
| 🔴 | **Go unit tests** | Table-driven tests for `internal/config`, `internal/checker`, `internal/engine` |
| 🔴 | **Integration test container** | Podman-in-Podman or rootless: `zelira validate` → `zelira deploy` → `zelira health` in CI |
| 🟡 | **Multi-distro matrix** | CI runs on Debian 12, AlmaLinux 10, Ubuntu 24.04 via container images |

#### Release Engineering

| Status | Item | Description |
|--------|------|-------------|
| 🔴 | **GitHub Releases** | Tag-triggered workflow: build, sign, upload `zelira-linux-amd64` + `zelira-linux-arm64` |
| 🔴 | **Checksums + signatures** | SHA256 sums + optional GPG signing for release binaries |
| 🔴 | **Install script** | `curl -sSL https://zelira.dev/install \| sh` — detect arch, download binary, verify checksum |
| 🟡 | **Homebrew tap** | `brew install parkwardrr/tap/zelira` for macOS dev machines |
| 🟡 | **Version bumping** | `make release VERSION=0.3.0` — tag, build, push |

### Phase 10 — Observability & Ecosystem

Production monitoring, alternative deployment methods, and Docker compatibility.

#### Observability

| Status | Item | Description |
|--------|------|-------------|
| 🔴 | **`zelira metrics serve`** | Long-running HTTP server exposing Prometheus `/metrics` endpoint |
| 🔴 | **DNS metrics** | Query latency (p50/p95/p99), cache hit ratio, upstream failure count |
| 🔴 | **DHCP metrics** | Pool utilization (leased/total), lease churn rate, Option 42 propagation |
| 🔴 | **NTP metrics** | Stratum, offset, jitter, source reachability bitmap |
| 🟡 | **Grafana dashboard** | Pre-built JSON dashboard for Zelira metrics — drop-in for existing Grafana instances |
| 🟡 | **Alerting rules** | Prometheus alerting rules: DNS down >30s, DHCP pool >90%, NTP offset >100ms |

#### Ecosystem

| Status | Item | Description |
|--------|------|-------------|
| 🟡 | **Docker fallback** | Optional Docker-compatible mode (`zelira deploy --runtime docker`) |
| 🟢 | **NixOS module** | Declarative Nix flake: `services.zelira.enable = true;` |
| 🟢 | **Ansible playbook** | Role-based deployment: `ansible-playbook zelira.yml -i hosts` |
| 🟢 | **Helm chart** | Kubernetes deployment for lab clusters (not primary target) |

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
