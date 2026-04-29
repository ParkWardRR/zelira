# Advanced Configuration

## Static DHCP Reservations

Edit `/srv/kea/etc-kea/kea-dhcp4.conf` and add entries to the `reservations` array:

```json
"reservations": [
  {
    "hw-address": "AA:BB:CC:DD:EE:FF",
    "ip-address": "192.168.1.10",
    "hostname": "my-server"
  },
  {
    "hw-address": "11:22:33:44:55:66",
    "ip-address": "192.168.1.11",
    "hostname": "my-nas"
  }
]
```

Then restart Kea:
```bash
sudo systemctl restart container-kea-dhcp4
```

## Custom Pi-hole Blocklists

Pi-hole data lives at `/srv/pihole/etc-pihole/`. After deploying, use the Pi-hole web UI (`http://<IP>/admin`) to manage blocklists, or edit files directly:

```bash
# Add custom blocklist
echo "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" >> /srv/pihole/etc-pihole/adlists.list
sudo podman exec pihole pihole -g  # Update gravity
```

## Local DNS Records

Add custom DNS entries via Pi-hole's Local DNS feature in the web UI, or via config:

```bash
# /srv/pihole/etc-dnsmasq.d/05-local-dns.conf
address=/nas.home.local/192.168.1.10
address=/printer.home.local/192.168.1.20
```

Restart Pi-hole: `sudo systemctl restart container-pihole`

## Monitoring with Prometheus

Export Pi-hole and Unbound metrics for Grafana dashboards.

### Pi-hole Exporter
```bash
podman run -d --name pihole-exporter \
    --network host \
    -e PIHOLE_HOSTNAME=127.0.0.1 \
    -e PIHOLE_API_TOKEN=<your-api-token> \
    -e PORT=9617 \
    docker.io/ekofr/pihole-exporter:latest
```

Scrape `http://<IP>:9617/metrics` from Prometheus.

### Node Exporter
```bash
apt install prometheus-node-exporter
# Exposes machine metrics on :9100
```

## Backup & Restore

### Backup
```bash
# All persistent data lives in /srv/
tar czf zelira-backup-$(date +%Y%m%d).tar.gz \
    /srv/pihole/ \
    /srv/unbound/ \
    /srv/kea/
```

### Restore
```bash
sudo tar xzf zelira-backup-YYYYMMDD.tar.gz -C /
sudo systemctl restart container-unbound container-pihole container-kea-dhcp4
```

## Running Without DHCP

If you only want DNS (Pi-hole + Unbound) and your router handles DHCP:

1. Don't start the Kea service:
```bash
sudo systemctl disable --now container-kea-dhcp4
```

2. Point your router's DHCP to hand out this host's IP as the DNS server.

## Running on x86_64

Zelira works on any Linux with Podman. The container images are multi-arch (arm64 + amd64). No changes needed for x86_64 deployment.

## Updating Container Images

```bash
sudo podman pull docker.io/pihole/pihole:latest
sudo podman pull docker.io/klutchell/unbound:latest
sudo podman pull docker.io/jonasal/kea-dhcp4:2.6

# Restart to pick up new images
sudo systemctl restart container-unbound
sleep 3
sudo systemctl restart container-pihole
sudo systemctl restart container-kea-dhcp4
```

## Security Hardening

- **Change Pi-hole password:** Edit `ZELIRA_PIHOLE_PASSWORD` in `.env` and re-run deploy, or use `podman exec pihole pihole -a -p <newpass>`
- **Restrict Unbound access:** The default config only allows RFC1918 ranges. If your network uses non-standard subnets, add them to `access-control` in `unbound.conf`.
- **Firewall:** Only ports 53 (DNS), 67 (DHCP), and 80 (Pi-hole UI) need to be accessible from LAN. Block everything else.
