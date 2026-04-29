# Contributing to Zelira

Thanks for your interest. Contributions that improve reliability, documentation, or portability are welcome.

## Quick Start

```bash
git clone https://github.com/YOUR-USERNAME/zelira.git
cd zelira
git checkout -b feat/your-feature-name
cp config/env.example config/.env
vi config/.env
sudo ./deploy.sh
./scripts/health-check.sh
```

## What We Need

| Type | Examples | Priority |
|------|----------|----------|
| Bug fixes | deploy.sh fails on Fedora, Kea config edge case | 🔴 High |
| Distro support | Testing/fixing on new distributions | 🔴 High |
| Documentation | Typos, unclear instructions, pitfall entries | 🟡 Medium |
| Add-on scripts | New DDNS providers, dashboard options | 🟡 Medium |
| Example configs | `.env` for different network setups | 🟢 Low |

## Ground Rules

1. **Never test DHCP on production.** Use a VM with firewalled DHCP or a Podman `--internal` network.
2. **Config changes need a reason.** Every value exists because something broke. Explain what your change fixes.
3. **Scripts must be idempotent.** Safe to run twice without errors.
4. **Support multiple distros.** Debian/Ubuntu, openSUSE, Fedora/RHEL.

## Code Style

- Shebang: `#!/usr/bin/env bash` with `set -euo pipefail`
- Variables: `UPPER_SNAKE_CASE` for env, `lower_snake` for locals
- Section headers: `# ─── Section Name ───...`
- Use `info()`, `warn()`, `fail()`, `step()` helpers

## Pull Requests

**Branch naming:** `feat/`, `fix/`, `docs/` prefixes.

**Commit messages:** Conventional style with context:
```
fix: Kea crash on empty domain-search option

envsubst produces empty value when ZELIRA_DOMAIN unset.
Root cause: set -a missing before source .env
```

**Checklist:**
- [ ] Tested on at least one supported distro
- [ ] `deploy.sh` runs twice without errors
- [ ] `health-check.sh` passes
- [ ] No hardcoded IPs or credentials
- [ ] Docs updated if behavior changed
- [ ] DHCP tested in isolation only

## Bug Reports

Include: distro, Podman version, component, logs (`journalctl -u container-NAME`), and repro steps.

## Architecture Notes

- Podman, not Docker. No daemon, no compose.
- systemd is the orchestrator. Dependencies and restart via unit files.
- Host networking (`--network host`). No bridge, no port mapping.
- `envsubst` for templating. No Jinja2, no Helm.
- `/srv/` for persistent data.

## License

Contributions are licensed under [Blue Oak Model License 1.0.0](LICENSE.md).
