#!/usr/bin/env bash
# Zelira — Uninstall
# Stops all services, removes systemd units. Leaves config files in /srv/ intact.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root (sudo ./scripts/uninstall.sh)"
    exit 1
fi

echo "Zelira Uninstall"
echo "════════════════"
echo ""
echo "This will:"
echo "  • Stop all Zelira containers"
echo "  • Remove systemd service files"
echo "  • Remove dns-healthcheck script"
echo ""
echo "Config data in /srv/ will NOT be deleted."
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "→ Stopping services..."
for svc in dns-healthcheck.timer container-pihole container-unbound container-kea-dhcp4; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc"
        echo "  ✓ Stopped $svc"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        systemctl disable "$svc"
    fi
done

echo "→ Removing containers..."
for name in pihole unbound kea-dhcp4; do
    podman rm -f "$name" 2>/dev/null && echo "  ✓ Removed $name" || true
done

echo "→ Removing systemd units..."
rm -f /etc/systemd/system/container-pihole.service
rm -f /etc/systemd/system/container-unbound.service
rm -f /etc/systemd/system/container-kea-dhcp4.service
rm -f /etc/systemd/system/dns-healthcheck.service
rm -f /etc/systemd/system/dns-healthcheck.timer
systemctl daemon-reload
echo "  ✓ Systemd units removed"

echo "→ Removing health check script..."
rm -f /usr/local/bin/dns-healthcheck.sh
echo "  ✓ Removed"

echo ""
echo "Done. Config data preserved at:"
echo "  /srv/pihole/"
echo "  /srv/unbound/"
echo "  /srv/kea/"
echo ""
echo "To fully purge: sudo rm -rf /srv/pihole /srv/unbound /srv/kea"
