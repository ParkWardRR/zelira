#!/usr/bin/env bash
# Zelira — Health Check
# Validates all services are running and DNS/DHCP are functional.
# Checks core stack + optional add-ons (NTP, DDNS, Dashboard).
set -euo pipefail

PASS=0
FAIL=0
WARN=0

check() {
    local label="$1"
    local result="$2"
    if [[ "$result" == "0" ]]; then
        echo "  ✓ $label"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label"
        FAIL=$((FAIL + 1))
    fi
}

warn() {
    local label="$1"
    echo "  ⚠ $label"
    WARN=$((WARN + 1))
}

skip() {
    local label="$1"
    echo "  ─ $label (not deployed)"
}

echo "Zelira Health Check"
echo "═══════════════════"
echo ""

# ─── Container Status ─────────────────────────────────
echo "Containers:"
for name in unbound pihole kea-dhcp4; do
    if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        uptime=$(podman ps --filter "name=^${name}$" --format '{{.Status}}' 2>/dev/null)
        check "$name ($uptime)" "0"
    elif sudo podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        uptime=$(sudo podman ps --filter "name=^${name}$" --format '{{.Status}}' 2>/dev/null)
        check "$name ($uptime)" "0"
    else
        check "$name — NOT RUNNING" "1"
    fi
done

# Check add-on containers (optional — only report if deployed)
for name in ddns; do
    if podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$" || \
       sudo podman ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        uptime=$(podman ps --filter "name=^${name}$" --format '{{.Status}}' 2>/dev/null || \
                 sudo podman ps --filter "name=^${name}$" --format '{{.Status}}' 2>/dev/null)
        check "$name ($uptime)" "0"
    elif systemctl is-enabled --quiet container-ddns 2>/dev/null; then
        check "$name — NOT RUNNING (enabled)" "1"
    fi
done
echo ""

# ─── Systemd Services ─────────────────────────────────
echo "Systemd:"
for svc in container-unbound container-pihole container-kea-dhcp4 dns-healthcheck.timer; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        check "$svc" "0"
    else
        check "$svc" "1"
    fi
done

# Optional add-on services
for svc in container-ddns; do
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            check "$svc" "0"
        else
            check "$svc — ENABLED BUT NOT RUNNING" "1"
        fi
    fi
done
echo ""

# ─── DNS Resolution ───────────────────────────────────
echo "DNS:"

# Test Unbound directly
unbound_result=$(dig +short +time=3 +tries=1 google.com @127.0.0.1 -p 5335 2>/dev/null || true)
if [[ -n "$unbound_result" ]]; then
    check "Unbound (127.0.0.1:5335) → $unbound_result" "0"
else
    check "Unbound (127.0.0.1:5335) — FAILED" "1"
fi

# Test Pi-hole (full chain)
pihole_result=$(dig +short +time=3 +tries=1 google.com @127.0.0.1 2>/dev/null || true)
if [[ -n "$pihole_result" ]]; then
    check "Pi-hole (127.0.0.1:53) → $pihole_result" "0"
else
    check "Pi-hole (127.0.0.1:53) — FAILED" "1"
fi

# Test DNSSEC
dnssec_result=$(dig +short +time=3 +tries=1 +dnssec sigok.verteiltesysteme.net @127.0.0.1 -p 5335 2>/dev/null || true)
if [[ -n "$dnssec_result" ]]; then
    check "DNSSEC validation working" "0"
else
    warn "DNSSEC test inconclusive"
fi

# Test ad-blocking
ad_result=$(dig +short +time=3 +tries=1 ads.google.com @127.0.0.1 2>/dev/null || true)
if [[ "$ad_result" == "0.0.0.0" ]] || [[ -z "$ad_result" ]]; then
    check "Ad-blocking active (ads.google.com → blocked)" "0"
else
    warn "Ad-blocking may not be configured yet (ads.google.com → $ad_result)"
fi
echo ""

# ─── Ports ─────────────────────────────────────────────
echo "Ports:"
for port_check in "53:DNS" "80:Pi-hole Web" "5335:Unbound" "67:DHCP"; do
    port="${port_check%%:*}"
    label="${port_check##*:}"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        check "Port $port ($label)" "0"
    else
        check "Port $port ($label) — NOT LISTENING" "1"
    fi
done
echo ""

# ─── Add-on: NTP (Chrony) ─────────────────────────────
if command -v chronyc &>/dev/null && systemctl is-active --quiet chronyd 2>/dev/null || systemctl is-active --quiet chrony 2>/dev/null; then
    echo "NTP (Chrony):"

    # Source count
    sources=$(chronyc sources 2>/dev/null | grep -c '^\^' || echo "0")
    reachable=$(chronyc sources 2>/dev/null | grep '^\^' | awk '{print $3}' | grep -cv '?' || echo "0")
    if [[ "$sources" -gt 0 ]]; then
        check "$sources source(s) configured, $reachable reachable" "0"
    else
        check "No NTP sources configured" "1"
    fi

    # Stratum check
    stratum=$(chronyc tracking 2>/dev/null | grep "Stratum" | awk '{print $3}' || echo "0")
    if [[ "$stratum" -gt 0 ]] && [[ "$stratum" -le 15 ]]; then
        check "Stratum $stratum (valid)" "0"
    elif [[ "$stratum" -eq 0 ]]; then
        check "Stratum 0 — not synced" "1"
    else
        warn "Stratum $stratum (very high)"
    fi

    # Offset check
    offset_raw=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4}' || echo "")
    if [[ -n "$offset_raw" ]]; then
        # Compare offset to threshold (1 second)
        offset_ms=$(echo "$offset_raw" | awk '{printf "%.3f", $1 * 1000}')
        offset_sign=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $5}')
        if (( $(echo "$offset_raw < 1.0" | bc -l 2>/dev/null || echo "1") )); then
            check "Clock offset: ${offset_ms}ms $offset_sign" "0"
        else
            warn "Clock offset: ${offset_ms}ms $offset_sign (>1s drift)"
        fi
    fi

    # Port 123
    if ss -ulnp 2>/dev/null | grep -q ":123 "; then
        check "Port 123/UDP (NTP) listening" "0"
    else
        warn "Port 123/UDP not listening — LAN clients can't sync"
    fi
    echo ""
fi

# ─── Add-on: DDNS ─────────────────────────────────────
if systemctl is-enabled --quiet container-ddns 2>/dev/null; then
    echo "DDNS:"

    if systemctl is-active --quiet container-ddns 2>/dev/null; then
        # Check how recently the container restarted (proxy for "last update")
        ddns_uptime=$(podman ps --filter "name=^ddns$" --format '{{.Status}}' 2>/dev/null || \
                      sudo podman ps --filter "name=^ddns$" --format '{{.Status}}' 2>/dev/null || echo "unknown")
        check "DDNS container running ($ddns_uptime)" "0"

        # Try to get last update from logs
        last_log=$(podman logs --tail 1 ddns 2>/dev/null || sudo podman logs --tail 1 ddns 2>/dev/null || echo "")
        if [[ -n "$last_log" ]]; then
            check "Last log: $last_log" "0"
        fi
    else
        check "DDNS service enabled but not running" "1"
    fi
    echo ""
fi

# ─── Add-on: Dashboard (Caddy) ────────────────────────
if systemctl is-enabled --quiet caddy 2>/dev/null; then
    echo "Dashboard (Caddy):"

    if systemctl is-active --quiet caddy 2>/dev/null; then
        check "Caddy service running" "0"
    else
        check "Caddy service not running" "1"
    fi

    # Check port 443 or configured dashboard port
    if ss -tlnp 2>/dev/null | grep -q ":443 "; then
        check "Port 443/TCP (HTTPS) listening" "0"

        # Check TLS cert expiry if domain is configured
        if [[ -d /var/lib/caddy/.local/share/caddy/certificates ]]; then
            # Find the most recent cert and check expiry
            cert_file=$(find /var/lib/caddy/.local/share/caddy/certificates -name "*.crt" -type f 2>/dev/null | head -1)
            if [[ -n "$cert_file" ]] && command -v openssl &>/dev/null; then
                expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
                if [[ -n "$expiry_date" ]]; then
                    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null || echo "0")
                    now_epoch=$(date +%s)
                    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                    if [[ $days_left -gt 14 ]]; then
                        check "TLS cert expires in ${days_left} days" "0"
                    elif [[ $days_left -gt 0 ]]; then
                        warn "TLS cert expires in ${days_left} days — renewal needed soon"
                    else
                        check "TLS cert EXPIRED" "1"
                    fi
                fi
            fi
        fi
    elif ss -tlnp 2>/dev/null | grep -q ":8083 "; then
        check "Port 8083/TCP (Dashboard HTTP) listening" "0"
    else
        warn "No dashboard port detected (443 or 8083)"
    fi

    # Quick HTTP check
    dash_url="http://127.0.0.1:8083"
    if ss -tlnp 2>/dev/null | grep -q ":443 "; then
        dash_url="https://127.0.0.1"
    fi
    if command -v curl &>/dev/null; then
        http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 -k "$dash_url" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
            check "Dashboard responding (HTTP $http_code)" "0"
        elif [[ "$http_code" == "000" ]]; then
            warn "Dashboard unreachable"
        else
            warn "Dashboard returned HTTP $http_code"
        fi
    fi
    echo ""
fi

# ─── Summary ──────────────────────────────────────────
echo "═══════════════════"
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
if [[ $FAIL -gt 0 ]]; then
    echo "Status: UNHEALTHY"
    exit 1
else
    echo "Status: HEALTHY"
    exit 0
fi
