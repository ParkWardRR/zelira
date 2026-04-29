#!/usr/bin/env bash
# Zelira Add-on — Deploy Dynamic DNS Updater
# Run as root: sudo ./scripts/deploy-ddns.sh
# Idempotent — safe to run multiple times.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/config/.env"

# ─── Colors ────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "  ${RED}✗${NC} $1"; }
step()  { echo -e "\n${CYAN}→${NC} $1"; }

# ─── Preflight ─────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root (sudo ./scripts/deploy-ddns.sh)"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: config/.env not found."
    echo "  Add DDNS settings to your .env first."
    exit 1
fi

set -a; source "$ENV_FILE"; set +a

# ─── Validate DDNS Config ────────────────────────────
step "Validating DDNS config..."

PROVIDER="${ZELIRA_DDNS_PROVIDER:-}"
if [[ -z "$PROVIDER" ]]; then
    fail "ZELIRA_DDNS_PROVIDER not set in config/.env"
    echo ""
    echo "  Add these to your config/.env:"
    echo "    ZELIRA_DDNS_PROVIDER=namecheap   # or: cloudflare, duckdns"
    echo "    ZELIRA_DDNS_HOST=home"
    echo "    ZELIRA_DDNS_DOMAIN=yourdomain.com"
    echo "    ZELIRA_DDNS_PASSWORD=your-ddns-password"
    echo "    ZELIRA_DDNS_INTERVAL=300"
    exit 1
fi

# Validate per-provider requirements
case "$PROVIDER" in
    namecheap)
        for var in ZELIRA_DDNS_HOST ZELIRA_DDNS_DOMAIN ZELIRA_DDNS_PASSWORD; do
            if [[ -z "${!var:-}" ]]; then
                fail "$var is required for Namecheap DDNS"
                exit 1
            fi
        done
        IMAGE="docker.io/linuxshots/namecheap-ddns"
        DDNS_INTERVAL="${ZELIRA_DDNS_INTERVAL:-300}"
        CONTAINER_ARGS=(
            -e "NC_HOST=${ZELIRA_DDNS_HOST}"
            -e "NC_DOMAIN=${ZELIRA_DDNS_DOMAIN}"
            -e "NC_PASS=${ZELIRA_DDNS_PASSWORD}"
            -e "NC_INTERVAL=${DDNS_INTERVAL}"
        )
        info "Provider: Namecheap (${ZELIRA_DDNS_HOST}.${ZELIRA_DDNS_DOMAIN})"
        ;;
    cloudflare)
        for var in ZELIRA_DDNS_API_KEY ZELIRA_DDNS_ZONE; do
            if [[ -z "${!var:-}" ]]; then
                fail "$var is required for Cloudflare DDNS"
                exit 1
            fi
        done
        IMAGE="docker.io/oznu/cloudflare-ddns"
        CONTAINER_ARGS=(
            -e "API_KEY=${ZELIRA_DDNS_API_KEY}"
            -e "ZONE=${ZELIRA_DDNS_ZONE}"
            -e "SUBDOMAIN=${ZELIRA_DDNS_SUBDOMAIN:-home}"
        )
        info "Provider: Cloudflare (${ZELIRA_DDNS_SUBDOMAIN:-home}.${ZELIRA_DDNS_ZONE})"
        ;;
    duckdns)
        for var in ZELIRA_DDNS_TOKEN ZELIRA_DDNS_SUBDOMAINS; do
            if [[ -z "${!var:-}" ]]; then
                fail "$var is required for DuckDNS"
                exit 1
            fi
        done
        IMAGE="lscr.io/linuxserver/duckdns"
        CONTAINER_ARGS=(
            -e "TOKEN=${ZELIRA_DDNS_TOKEN}"
            -e "SUBDOMAINS=${ZELIRA_DDNS_SUBDOMAINS}"
            -e "PUID=1000"
            -e "PGID=1000"
        )
        info "Provider: DuckDNS (${ZELIRA_DDNS_SUBDOMAINS})"
        ;;
    *)
        fail "Unknown DDNS provider: $PROVIDER"
        echo "  Supported: namecheap, cloudflare, duckdns"
        exit 1
        ;;
esac

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║    Zelira Add-on: Dynamic DNS            ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Provider:  ${PROVIDER}"
echo "║  Image:     ${IMAGE}"
echo "╚══════════════════════════════════════════╝"
echo ""

# ─── Pull Image ───────────────────────────────────────
step "Pulling DDNS container image..."
if podman image exists "$IMAGE" 2>/dev/null; then
    info "$IMAGE (cached)"
else
    podman pull "$IMAGE"
    info "$IMAGE (pulled)"
fi

# ─── Stop Existing (if upgrading) ─────────────────────
if systemctl is-active --quiet container-ddns 2>/dev/null; then
    warn "Stopping existing DDNS service for upgrade..."
    systemctl stop container-ddns
fi

# ─── Install Systemd Service ─────────────────────────
step "Installing systemd service..."

# Build the ExecStart line with provider-specific env vars
ENV_LINES=""
for arg in "${CONTAINER_ARGS[@]}"; do
    ENV_LINES+="    ${arg} \\\\\n"
done

cat > /etc/systemd/system/container-ddns.service <<EOF
[Unit]
Description=Zelira — Dynamic DNS Updater (${PROVIDER})
Wants=network-online.target
After=network-online.target

[Service]
Restart=always
RestartSec=30
TimeoutStopSec=30
ExecStartPre=-/usr/bin/podman rm -f ddns
ExecStart=/usr/bin/podman run \\
    --rm \\
    --name ddns \\
    --net host \\
$(printf '    %s \\\n' "${CONTAINER_ARGS[@]}")
    ${IMAGE}
ExecStop=/usr/bin/podman stop -t 10 ddns
Type=simple

[Install]
WantedBy=multi-user.target
EOF

info "container-ddns.service (${PROVIDER})"

# ─── Enable & Start ──────────────────────────────────
step "Starting DDNS service..."
systemctl daemon-reload
systemctl enable --now container-ddns.service
sleep 3

# ─── Verify ──────────────────────────────────────────
step "Verifying..."
if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^ddns$"; then
    UPTIME=$(podman ps --filter "name=^ddns$" --format '{{.Status}}')
    info "DDNS container running ($UPTIME)"
else
    if systemctl is-active --quiet container-ddns 2>/dev/null; then
        info "DDNS service active"
    else
        warn "DDNS container may still be starting — check: podman logs ddns"
    fi
fi

# Show recent logs
echo ""
echo "  Recent logs:"
podman logs --tail 5 ddns 2>/dev/null | while read -r line; do
    echo "    $line"
done

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       ✓ Dynamic DNS Deployed             ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Provider:  ${PROVIDER}"
echo "║  Service:   container-ddns.service"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Verify with: podman logs ddns"
