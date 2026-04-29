#!/usr/bin/env bash
# Zelira Add-on — Deploy Landing Page & Reverse Proxy (Caddy)
# Run as root: sudo ./scripts/deploy-dashboard.sh
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
    echo "Error: run as root (sudo ./scripts/deploy-dashboard.sh)"
    exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
fi

ZELIRA_HOST_IP="${ZELIRA_IP:-$(hostname -I | awk '{print $1}')}"
DASH_DOMAIN="${ZELIRA_DASH_DOMAIN:-}"
DNS_DOMAIN="${ZELIRA_DNS_DOMAIN:-}"
DASH_PORT="${ZELIRA_DASH_PORT:-8083}"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Zelira Add-on: Dashboard (Caddy)        ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Host IP:   ${ZELIRA_HOST_IP}"
if [[ -n "$DASH_DOMAIN" ]]; then
echo "║  Dashboard: ${DASH_DOMAIN}"
fi
if [[ -n "$DNS_DOMAIN" ]]; then
echo "║  Pi-hole:   ${DNS_DOMAIN}"
fi
echo "╚══════════════════════════════════════════╝"
echo ""

# ─── Install Caddy ────────────────────────────────────
step "Installing Caddy..."
if command -v caddy &>/dev/null; then
    info "Caddy already installed ($(caddy version 2>/dev/null | head -1 || echo 'unknown'))"
else
    if command -v apt &>/dev/null; then
        # Debian/Ubuntu — install from official Caddy repo
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl 2>/dev/null || true
        if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
            apt-get update
        fi
        apt-get install -y caddy
    elif command -v zypper &>/dev/null; then
        # openSUSE
        zypper install -y caddy 2>/dev/null || {
            warn "Caddy not in default repos — installing from GitHub release"
            CADDY_VER=$(curl -s https://api.github.com/repos/caddyserver/caddy/releases/latest | grep tag_name | cut -d'"' -f4 | sed 's/^v//')
            curl -Lo /tmp/caddy.tar.gz "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VER}/caddy_${CADDY_VER}_linux_amd64.tar.gz"
            tar xzf /tmp/caddy.tar.gz -C /usr/local/bin caddy
            chmod +x /usr/local/bin/caddy
            rm -f /tmp/caddy.tar.gz
        }
    elif command -v dnf &>/dev/null; then
        dnf install -y caddy 2>/dev/null || {
            warn "Caddy not in repos — installing from COPR"
            dnf copr enable -y @caddy/caddy
            dnf install -y caddy
        }
    else
        fail "No supported package manager found"
        exit 1
    fi
    info "Caddy installed"
fi

# ─── Create Dashboard ────────────────────────────────
step "Creating dashboard..."
mkdir -p /var/www/zelira-dashboard

cat > /var/www/zelira-dashboard/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Home Network — Zelira</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Inter', system-ui, -apple-system, sans-serif;
            background: #0a0a0f;
            color: #e0e0e8;
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 2rem;
        }
        .container { max-width: 480px; width: 100%; }
        .header {
            text-align: center;
            margin-bottom: 2rem;
        }
        .header h1 {
            font-size: 1.5rem;
            font-weight: 600;
            color: #f0f0f8;
            letter-spacing: -0.02em;
        }
        .header .subtitle {
            font-size: 0.85rem;
            color: #666;
            margin-top: 0.25rem;
        }
        .card {
            background: #12121a;
            border: 1px solid #1e1e2e;
            border-radius: 12px;
            overflow: hidden;
        }
        .service {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 1rem 1.25rem;
            border-bottom: 1px solid #1e1e2e;
            transition: background 0.15s;
        }
        .service:last-child { border-bottom: none; }
        .service:hover { background: #1a1a28; }
        .service-info {
            display: flex;
            align-items: center;
            gap: 0.75rem;
        }
        .service-icon {
            width: 32px;
            height: 32px;
            border-radius: 8px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 1rem;
        }
        .service-name { font-weight: 500; font-size: 0.9rem; }
        .service-desc { font-size: 0.75rem; color: #666; margin-top: 0.1rem; }
        .status {
            display: flex;
            align-items: center;
            gap: 0.4rem;
            font-size: 0.8rem;
        }
        .dot {
            width: 6px; height: 6px;
            border-radius: 50%;
            background: #22c55e;
            box-shadow: 0 0 6px #22c55e88;
            animation: pulse 2s ease-in-out infinite;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }
        .status-text { color: #22c55e; }
        a.service { text-decoration: none; color: inherit; cursor: pointer; }
        .footer {
            text-align: center;
            margin-top: 1.5rem;
            font-size: 0.7rem;
            color: #333;
        }
        .icon-dns { background: #96060C22; }
        .icon-shield { background: #22c55e18; }
        .icon-lock { background: #3b82f618; }
        .icon-server { background: #f59e0b18; }
        .icon-clock { background: #8b5cf618; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🏠 Home Network</h1>
            <div class="subtitle">Powered by Zelira</div>
        </div>
        <div class="card">
            <a class="service" href="/admin" id="service-pihole">
                <div class="service-info">
                    <div class="service-icon icon-dns">🛡️</div>
                    <div>
                        <div class="service-name">Pi-hole DNS</div>
                        <div class="service-desc">Ad-blocking & DNS management</div>
                    </div>
                </div>
                <div class="status">
                    <div class="dot"></div>
                    <span class="status-text">Admin →</span>
                </div>
            </a>
            <div class="service" id="service-adblock">
                <div class="service-info">
                    <div class="service-icon icon-shield">🚫</div>
                    <div>
                        <div class="service-name">Ad Blocking</div>
                        <div class="service-desc">~180,000 domains blocked</div>
                    </div>
                </div>
                <div class="status">
                    <div class="dot"></div>
                    <span class="status-text">Active</span>
                </div>
            </div>
            <div class="service" id="service-dnssec">
                <div class="service-info">
                    <div class="service-icon icon-lock">🔐</div>
                    <div>
                        <div class="service-name">DNSSEC</div>
                        <div class="service-desc">Recursive validation via Unbound</div>
                    </div>
                </div>
                <div class="status">
                    <div class="dot"></div>
                    <span class="status-text">Validated</span>
                </div>
            </div>
            <div class="service" id="service-dhcp">
                <div class="service-info">
                    <div class="service-icon icon-server">📋</div>
                    <div>
                        <div class="service-name">DHCP Server</div>
                        <div class="service-desc">Kea DHCPv4 with lease management</div>
                    </div>
                </div>
                <div class="status">
                    <div class="dot"></div>
                    <span class="status-text">Running</span>
                </div>
            </div>
            <div class="service" id="service-ntp">
                <div class="service-info">
                    <div class="service-icon icon-clock">⏱️</div>
                    <div>
                        <div class="service-name">NTP Server</div>
                        <div class="service-desc">Chrony time synchronization</div>
                    </div>
                </div>
                <div class="status">
                    <div class="dot"></div>
                    <span class="status-text">Synced</span>
                </div>
            </div>
        </div>
        <div class="footer">
            Zelira — Containerized DNS/DHCP Stack
        </div>
    </div>
</body>
</html>
HTMLEOF
info "Dashboard page → /var/www/zelira-dashboard/index.html"

# ─── Configure Caddyfile ─────────────────────────────
step "Configuring Caddy..."

CADDY_CONF="/etc/caddy/Caddyfile"
mkdir -p /etc/caddy

# Back up existing config
if [[ -f "$CADDY_CONF" ]] && [[ ! -f "${CADDY_CONF}.zelira-backup" ]]; then
    cp "$CADDY_CONF" "${CADDY_CONF}.zelira-backup"
    info "Backed up existing Caddyfile"
fi

if [[ -n "$DASH_DOMAIN" ]] || [[ -n "$DNS_DOMAIN" ]]; then
    # Domain-based config with auto-TLS
    cat > "$CADDY_CONF" <<EOF
{
    persist_config off
}

EOF
    if [[ -n "$DASH_DOMAIN" ]]; then
        cat >> "$CADDY_CONF" <<EOF
# Dashboard / Landing Page
${DASH_DOMAIN} {
    root * /var/www/zelira-dashboard
    file_server
    encode gzip
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}

EOF
    fi
    if [[ -n "$DNS_DOMAIN" ]]; then
        cat >> "$CADDY_CONF" <<EOF
# Pi-hole Admin (HTTPS)
${DNS_DOMAIN} {
    reverse_proxy 127.0.0.1:80
    encode gzip
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
    }
}
EOF
    fi
    info "Caddyfile configured with domain(s)"
else
    # IP-only fallback — serve on port 8083
    cat > "$CADDY_CONF" <<EOF
# Zelira Dashboard — IP-only mode (no TLS)
:${DASH_PORT} {
    root * /var/www/zelira-dashboard
    file_server
    encode gzip
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
    }
}
EOF
    info "Caddyfile configured for http://${ZELIRA_HOST_IP}:${DASH_PORT}"
fi

# ─── Open Firewall Port ──────────────────────────────
step "Configuring firewall..."
PORTS_NEEDED=("443/tcp")
if [[ -z "$DASH_DOMAIN" ]] && [[ -z "$DNS_DOMAIN" ]]; then
    PORTS_NEEDED=("${DASH_PORT}/tcp")
fi

if command -v firewall-cmd &>/dev/null; then
    for p in "${PORTS_NEEDED[@]}"; do
        if ! firewall-cmd --list-ports 2>/dev/null | grep -q "$p"; then
            firewall-cmd --permanent --add-port="$p"
            info "Opened port $p (firewalld)"
        else
            info "Port $p already open (firewalld)"
        fi
    done
    firewall-cmd --reload 2>/dev/null || true
elif command -v ufw &>/dev/null; then
    for p in "${PORTS_NEEDED[@]}"; do
        ufw allow "$p" 2>/dev/null || true
        info "Opened port $p (ufw)"
    done
else
    warn "No firewall manager detected — ensure port(s) are open"
fi

# ─── Enable & Start ──────────────────────────────────
step "Starting Caddy..."
systemctl enable --now caddy
sleep 2

# ─── Verify ──────────────────────────────────────────
step "Verifying..."
if systemctl is-active --quiet caddy; then
    info "Caddy service is running"
else
    warn "Caddy may not have started — check: systemctl status caddy"
fi

if [[ -n "$DASH_DOMAIN" ]]; then
    DASH_URL="https://${DASH_DOMAIN}"
elif [[ -z "$DASH_DOMAIN" ]]; then
    DASH_URL="http://${ZELIRA_HOST_IP}:${DASH_PORT}"
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       ✓ Dashboard Deployed               ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Dashboard:  ${DASH_URL}"
if [[ -n "$DNS_DOMAIN" ]]; then
echo "║  Pi-hole:    https://${DNS_DOMAIN}/admin"
fi
echo "║  Service:    caddy.service"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Verify with: curl -I ${DASH_URL}"
