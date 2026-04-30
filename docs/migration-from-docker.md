# Migrating from Pi-hole Docker Compose to Zelira

Step-by-step guide for moving from a standard Pi-hole + Unbound Docker Compose setup to Zelira's Podman + systemd stack.

## Why Migrate?

| Concern | Docker Compose | Zelira |
|---------|---------------|--------|
| **Daemon dependency** | Docker daemon crash = all containers die | Podman is daemonless; each container is independent |
| **Auto-recovery** | `restart: unless-stopped` is all you get | systemd `Restart=always` + `dns-healthcheck.timer` with 3-strike restart |
| **Boot ordering** | `depends_on` doesn't wait for readiness | `Requires=` + `After=` + 3s init delay |
| **DHCP** | Usually separate (ISC dhcpd or router) | Integrated Kea DHCPv4 with JSON config |
| **Config management** | Raw YAML + env files | Single `.env` → `envsubst` → validated JSON |
| **Resilience** | No stale cache, no infra-host-ttl fix | `serve-expired`, `infra-host-ttl: 60`, TCP idle fix |

## Pre-Migration Checklist

Before you start:

- [ ] **Back up your Pi-hole config:** `docker cp pihole:/etc/pihole ./pihole-backup/`
- [ ] **Export your blocklists:** Pi-hole Admin → Adlists → note all URLs
- [ ] **Export custom DNS records:** `docker cp pihole:/etc/pihole/custom.list ./`
- [ ] **Note your DHCP reservations** (if Pi-hole manages DHCP)
- [ ] **Record your network settings:** gateway IP, subnet, DNS IP, interface name

## Step-by-Step

### 1. Stop Docker Compose

```bash
cd /path/to/your/pihole-compose
docker compose down
```

> **Important:** Don't delete your Docker volumes yet. Keep them as backup until Zelira is verified.

### 2. Install Podman

```bash
# Debian/Ubuntu
sudo apt install podman

# openSUSE
sudo zypper install podman

# Fedora/RHEL
sudo dnf install podman
```

### 3. Clone Zelira

```bash
git clone https://github.com/ParkWardRR/zelira.git
cd zelira
```

### 4. Create Your `.env`

```bash
cp config/env.example config/.env
vi config/.env
```

Map your Docker Compose values to Zelira:

| Docker Compose | Zelira `.env` |
|----------------|---------------|
| `ServerIP` or `FTLCONF_LOCAL_IPV4` | `ZELIRA_IP` |
| Your router IP | `ZELIRA_GATEWAY` |
| Your network CIDR | `ZELIRA_SUBNET` |
| `WEBPASSWORD` | `ZELIRA_PIHOLE_PASSWORD` |
| `TZ` | `ZELIRA_TZ` |
| Network interface | `ZELIRA_INTERFACE` |

If you had DHCP enabled in Pi-hole, set the pool range:
```bash
ZELIRA_POOL_START=192.168.1.100
ZELIRA_POOL_END=192.168.1.250
```

### 5. Disable systemd-resolved (Ubuntu/Debian)

If you're on Ubuntu, this is likely blocking port 53:

```bash
sudo systemctl disable --now systemd-resolved
sudo rm /etc/resolv.conf
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
```

> `zelira deploy` detects this automatically and will prompt you.

### 6. Deploy

```bash
sudo ./zelira deploy
```

### 7. Restore Custom DNS Records

If you had `custom.list` entries (local DNS for hostnames):

```bash
sudo cp ./custom.list /srv/pihole/etc-pihole/custom.list
sudo podman restart pihole
```

### 8. Restore Blocklists

Pi-hole v6 stores adlists in the web UI database. After deploy:

1. Open `http://YOUR_IP/admin`
2. Go to Adlists
3. Re-add your blocklist URLs
4. Update gravity: `sudo podman exec pihole pihole -g`

### 9. Migrate DHCP Reservations

If you had static DHCP leases in Pi-hole's DHCP:

Edit `/srv/kea/etc-kea/kea-dhcp4.conf` and add reservations:

```json
"reservations": [
  {
    "hw-address": "AA:BB:CC:DD:EE:FF",
    "ip-address": "192.168.1.10",
    "hostname": "my-server"
  },
  {
    "hw-address": "11:22:33:44:55:66",
    "ip-address": "192.168.1.20",
    "hostname": "nas"
  }
]
```

Then restart Kea:
```bash
sudo systemctl restart container-kea-dhcp4
```

### 10. Verify

```bash
./zelira health
```

Expected: 19/19 passed, HEALTHY.

### 11. Update Your Router

Point your router's DHCP DNS server setting to `ZELIRA_IP`, or disable router DHCP and let Kea handle it.

### 12. Clean Up Docker (Optional)

Once Zelira is verified and stable for a few days:

```bash
docker compose down -v  # Remove Docker volumes
sudo apt remove docker.io docker-compose  # Remove Docker
```

## Common Migration Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Port 53 already in use | systemd-resolved | `sudo systemctl disable --now systemd-resolved` |
| Pi-hole can't reach Unbound | Containers started in wrong order | `zelira deploy` handles this with `Requires=` + sleep |
| DHCP leases not renewing | Clients still have old lease from router DHCP | Wait for lease expiry, or `ipconfig /release` on clients |
| Blocklists empty | Pi-hole v6 stores lists in DB, not files | Re-add via web UI, then `pihole -g` |
| Custom DNS not working | `custom.list` not copied | Copy from backup to `/srv/pihole/etc-pihole/` |

## Docker Compose to Zelira Mapping

For reference, here's how a typical `docker-compose.yml` maps:

```yaml
# BEFORE: docker-compose.yml
services:
  pihole:
    image: pihole/pihole:latest
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80/tcp"
    environment:
      TZ: America/New_York        # → ZELIRA_TZ
      WEBPASSWORD: changeme       # → ZELIRA_PIHOLE_PASSWORD
    volumes:
      - ./etc-pihole:/etc/pihole  # → /srv/pihole/etc-pihole
      - ./etc-dnsmasq.d:/etc/dnsmasq.d

  unbound:
    image: klutchell/unbound:latest
    ports:
      - "5335:5335/tcp"
      - "5335:5335/udp"
    volumes:
      - ./unbound.conf:/etc/unbound/unbound.conf
```

```bash
# AFTER: Zelira
# One command. All config from .env.
sudo ./zelira deploy
```
