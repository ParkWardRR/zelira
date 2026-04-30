# Contributing to Zelira

Thanks for your interest. Contributions that improve reliability, documentation, or portability are welcome.

## Quick Start

```bash
git clone https://github.com/YOUR-USERNAME/zelira.git
cd zelira
git checkout -b feat/your-feature-name
make build
cp config/env.example config/.env
vi config/.env
sudo ./zelira deploy
./zelira health
```

## What We Need

| Type | Examples | Priority |
|------|----------|----------|
| Bug fixes | CLI edge case, Kea config validation issue | 🔴 High |
| Distro support | Testing/fixing on new distributions | 🔴 High |
| Documentation | Typos, unclear instructions, pitfall entries | 🟡 Medium |
| Go CLI features | New subcommands, improved diagnostics | 🟡 Medium |
| Example configs | `.env` for different network setups | 🟢 Low |

## Ground Rules

1. **Never test DHCP on production.** Use a VM with firewalled DHCP or a Podman `--internal` network.
2. **Config changes need a reason.** Every value exists because something broke. Explain what your change fixes.
3. **Commands must be idempotent.** Safe to run twice without errors.
4. **Support multiple distros.** Debian/Ubuntu, openSUSE, Fedora/RHEL/AlmaLinux.

## Code Style

### Go (CLI)

- Follow `gofmt` + `go vet` conventions
- Internal packages: `internal/config`, `internal/engine`, `internal/checker`, `internal/embedded`
- Subcommands: `cmd/zelira/commands/`
- Use `cobra` for CLI structure
- Errors should be user-friendly with actionable messages

### General

- Variables: `UPPER_SNAKE_CASE` for env, `camelCase` for Go
- Section headers in output: `→ Step name...`
- Use ✓/✗/⚠ indicators for check results

## Pull Requests

**Branch naming:** `feat/`, `fix/`, `docs/` prefixes.

**Commit messages:** Conventional style with context:
```
fix: Kea crash on empty domain-search option

envsubst produces empty value when ZELIRA_DOMAIN unset.
Root cause: missing validation in internal/config
```

**Checklist:**
- [ ] Tested on at least one supported distro
- [ ] `zelira deploy` runs twice without errors (idempotent)
- [ ] `zelira health` passes
- [ ] `make build` succeeds
- [ ] No hardcoded IPs or credentials
- [ ] Docs updated if behavior changed
- [ ] DHCP tested in isolation only

## Bug Reports

Include: distro, Podman version, CLI version (`zelira version`), component, logs (`zelira logs -s <service>`), and repro steps.

## Architecture Notes

- **Go CLI** is the only supported interface. All shell scripts have been removed.
- Podman, not Docker. No daemon, no compose.
- systemd is the orchestrator. Dependencies and restart via unit files.
- Host networking (`--network host`). No bridge, no port mapping.
- `go:embed` for config templates. No envsubst at runtime.
- `/srv/` for persistent data.

## License

Contributions are licensed under [Blue Oak Model License 1.0.0](LICENSE.md).
