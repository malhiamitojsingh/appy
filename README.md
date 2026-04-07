# appy.sh v2.0

> Interactive service installer, watchdog daemon, and system manager for CachyOS / Arch Linux.

```bash
sudo bash appy.sh
```

No flags. No config files. A grouped menu appears, you pick what you want — it installs, enables, and monitors everything automatically.

---

## Quick Start

```bash
# Download and run
curl -fsSL https://YOUR-PROJECT.pages.dev/appy.sh -o appy.sh
sudo bash appy.sh
```

Or clone and run directly:

```bash
git clone https://github.com/YOUR_USERNAME/appy.git
cd appy
sudo bash appy.sh
```

---

## What's New in v2.0

- **37 services** (up from 25) across 7 groups
- **Watchdog daemon** — monitors and auto-restarts failed services
- **Auto-update scheduler** — systemd timer for hands-free updates
- **Real-time health check** — CPU, memory, disk, load, network, and per-service status at a glance
- **Config backup** — one command archives all service configs with rotation
- **Service rollback** — safely stop, disable, and uninstall any service from the menu
- **Notifications** — log alerts for service failures, critical resource usage, and pending updates
- **Docker image updater** — pulls fresh images for all running containers
- **Log rotation** — auto-rotates appy logs at 10 MB
- **Non-interactive CLI** — scriptable flags for automation and cron

---

## How It Works

1. **Run** — Script checks you're root and on an Arch-based system
2. **Pick** — Grouped menu shows all 37 services. Type numbers space-separated (e.g. `1 3 6`) or `A` for all
3. **Done** — Services install via `pacman`, `yay`, `curl`, or `docker` and are immediately enabled
4. **Monitored** — Press `M → 7` to install the watchdog daemon for continuous health monitoring

Press `H` for a health report, `U` to update everything, `M` for maintenance and daemon management.

---

## All 37 Services

### Containers & Web

| # | Service | Source | Port | Notes |
|---|---------|--------|------|-------|
| 1 | Docker | pacman | — | Container runtime. Adds user to docker group |
| 2 | Docker Compose | pacman | — | Multi-container app orchestration |
| 3 | Nginx | pacman | 80, 443 | Web server and reverse proxy |
| 4 | Caddy | pacman | 80, 443 | Auto HTTPS via Let's Encrypt |
| 5 | Portainer | docker | 9443 | Web UI for Docker management |

### Databases

| # | Service | Source | Port | Notes |
|---|---------|--------|------|-------|
| 6 | MariaDB | pacman | 3306 | Root password saved to `~/appy-credentials.txt` |
| 7 | PostgreSQL | pacman | 5432 | Database initialized automatically |
| 8 | Redis | pacman | 6379 | In-memory cache, bound to localhost |
| 9 | SQLite | pacman | — | Embedded database, no server |
| 10 | MongoDB | AUR | 27017 | Document database |

### Security & Networking

| # | Service | Source | Notes |
|---|---------|--------|-------|
| 11 | Fail2ban | pacman | Bans IPs after failed SSH attempts |
| 12 | UFW | pacman | Firewall: deny inbound, allow SSH |
| 13 | WireGuard | pacman | Configure at `/etc/wireguard/wg0.conf` |
| 14 | Tailscale | pacman | Run `tailscale up` after install |
| 15 | Vaultwarden | docker | Self-hosted Bitwarden. Admin token saved to credentials file |
| 16 | CrowdSec | pacman | Collaborative intrusion prevention with Linux + SSH rules |

### Media & Files

| # | Service | Source | Port | Notes |
|---|---------|--------|------|-------|
| 17 | Jellyfin | AUR | 8096 | Free open-source media server |
| 18 | Samba | pacman | 445 | Windows-compatible file sharing |
| 19 | Syncthing | pacman | 8384 | Continuous file sync across devices |

### Monitoring & Observability

| # | Service | Source | Port | Notes |
|---|---------|--------|------|-------|
| 20 | btop | pacman | — | Terminal resource monitor with graphs |
| 21 | htop | pacman | — | Classic interactive process viewer |
| 22 | Netdata | pacman | 19999 | Real-time performance monitoring |
| 23 | Prometheus | pacman | 9090 | Metrics collection + node exporter |
| 24 | Grafana | pacman | 3000 | Dashboard visualization. Credentials auto-saved |
| 25 | Uptime Kuma | docker | 3001 | Beautiful uptime/status page monitor |
| 26 | Cockpit | pacman | 9090 | Web-based system administration panel |
| 27 | Loki | pacman | 3100 | Log aggregation system (pairs with Grafana) |

### Development Tools

| # | Service | Source | Notes |
|---|---------|--------|-------|
| 28 | Git | pacman | Version control |
| 29 | Neovim | pacman | Vim-based text editor |
| 30 | Zsh + Oh-My-Zsh | pacman | Sets as default shell |
| 31 | Node.js + npm | pacman | LTS version |
| 32 | Python 3 + pip | pacman | |
| 33 | Go | pacman | |
| 34 | Rust (rustup) | pacman | Installs stable toolchain automatically |
| 35 | Docker Buildx | pacman | Multi-platform image builder |

### AI & Other

| # | Service | Source | Notes |
|---|---------|--------|-------|
| 36 | Ollama | curl | Run LLMs locally. Needs 8+ GB RAM |
| 37 | Pi-hole | curl | Network ad blocker. Needs port 53 free |
| 38 | Timeshift | AUR | System snapshots and restore |
| 39 | Restic | pacman | Fast, encrypted backup. Installs `appy-backup` helper |

---

## Watchdog Daemon

appy can run as a persistent background daemon that monitors all installed services and automatically restarts them if they fail.

### Install

```bash
sudo bash appy.sh
# → M → 7 (Install/restart appy watchdog daemon)
```

Or directly:

```bash
sudo bash appy.sh --daemon &
# Or install as a systemd service via the maintenance menu
```

### What it does

- **Service watchdog** — checks all appy-managed services every 5 minutes and restarts any that are down
- **Resource alerts** — warns when disk exceeds 90% or memory exceeds 95%
- **Update notifications** — checks for available package updates every 6 hours
- **Log rotation** — automatically rotates appy logs when they exceed 10 MB
- **Notification log** — all events written to `/var/lib/appy/notifications.log`

### Configuration via environment

```bash
# Check interval (default: 300 seconds)
APPY_DAEMON_INTERVAL=120

# Email alerts (requires `mail` command)
APPY_NOTIFY_EMAIL=you@example.com
```

These can be set in the systemd unit at `/etc/systemd/system/appy-daemon.service`.

### Logs

```bash
# Daemon activity log
tail -f /var/log/appy-daemon.log

# General appy log
tail -f /var/log/appy.log

# View notifications (from the menu)
sudo bash appy.sh
# → M → 10
```

---

## Auto-Update Scheduler

Set up a systemd timer to keep your system updated automatically.

```bash
sudo bash appy.sh
# → M → 11
```

Options:
- **Daily at 3:00 AM** — updates pacman, AUR (yay), and Docker images nightly
- **Weekly (Sunday 3:00 AM)** — lower frequency for stable servers
- **Manual only** — disables the timer

The update process runs `pacman -Syu`, `yay -Syu`, pulls fresh Docker images for all running containers, then cleans the package cache.

Check the timer:

```bash
systemctl list-timers appy-update.timer
```

---

## Health Check

Run a full health report from the menu (`H`) or directly:

```bash
sudo bash appy.sh --health
```

The report shows:

- CPU, memory, and disk usage with color-coded thresholds
- Load average (1m, 5m, 15m)
- System uptime
- Network interface addresses
- Status of every appy-managed service (running / stopped)
- Docker container statuses
- Pending package update count
- Failed systemd services (system-wide)

---

## Config Backup

Back up all service configuration files to `/var/backups/appy-configs/`:

```bash
sudo bash appy.sh --backup
# or via menu: M → 12
```

Backs up configs for: Nginx, Caddy, Prometheus, Grafana, Loki, Fail2ban, UFW, WireGuard, Samba, Redis, MariaDB, PostgreSQL, the appy daemon unit, and your credentials file. Keeps the last 5 archives automatically.

---

## Rollback / Remove a Service

Remove any installed service cleanly (stops it, disables it, uninstalls packages):

```bash
# Via menu
sudo bash appy.sh
# → M → 13

# Or via CLI
sudo bash appy.sh --remove nginx
```

---

## Non-Interactive CLI

appy can be scripted for automation:

```bash
# Install specific services
sudo bash appy.sh --install docker nginx postgres

# Remove a service
sudo bash appy.sh --remove nginx

# Full system update
sudo bash appy.sh --update

# Health check
sudo bash appy.sh --health

# One-line status (CPU, mem, disk, load)
sudo bash appy.sh --status

# Back up configs
sudo bash appy.sh --backup

# Show logs (last 100 lines)
sudo bash appy.sh --logs

# Print version
sudo bash appy.sh --version

# Help
sudo bash appy.sh --help
```

---

## Post-Install Notes

### MariaDB
Root password is auto-generated and saved to `~/appy-credentials.txt` (mode 600). Secure the installation:

```bash
mysql_secure_installation
```

### PostgreSQL
Connect as the postgres user:

```bash
sudo -u postgres psql
sudo -u postgres createdb mydb
```

### Docker & Portainer
After install, re-login or run `newgrp docker`. Portainer web UI at `https://localhost:9443`.

```bash
docker run hello-world
```

### Vaultwarden
Admin panel at `http://localhost:8222/admin` — admin token saved to `~/appy-credentials.txt`.
Set up a reverse proxy (Caddy or Nginx) with HTTPS before exposing externally.

### WireGuard

```bash
wg genkey | tee privatekey | wg pubkey > publickey
nano /etc/wireguard/wg0.conf
systemctl enable --now wg-quick@wg0
```

### Tailscale

```bash
tailscale up
# For an exit node:
tailscale up --advertise-exit-node
```

### Caddy
```bash
nano /etc/caddy/Caddyfile
systemctl reload caddy
```

Example reverse proxy config:
```
yourdomain.com {
    reverse_proxy localhost:3000
}
```

### Nginx
```
/etc/nginx/nginx.conf          # main config
/etc/nginx/sites-available/    # per-site configs
```
```bash
nginx -t && systemctl reload nginx
```

### Prometheus + Grafana
Prometheus scrapes metrics at `http://localhost:9090`. Grafana dashboards at `http://localhost:3000`.

Add Prometheus as a Grafana data source:
```
URL: http://localhost:9090
```

Import dashboard ID **1860** (Node Exporter Full) from grafana.com for host metrics.

### Loki + Grafana
Loki listens at `http://localhost:3100`. Add as a Grafana data source (type: Loki).

Install Promtail to ship logs:
```bash
yay -S promtail
```

### Netdata
Real-time dashboard at `http://localhost:19999`. No configuration needed.

### Uptime Kuma
Dashboard at `http://localhost:3001`. Create your first admin account on first visit.

### Cockpit
Web-based admin at `https://localhost:9090`. Log in with your system user credentials.

### Jellyfin
First-run setup at `http://localhost:8096`. Add media library paths.

### Ollama
```bash
ollama pull llama3
ollama run llama3
# API at http://localhost:11434
```

### Pi-hole
Admin dashboard: `http://pi.hole/admin`
Set your router's DNS to the machine's IP.

### Samba
```ini
[myshare]
   path = /srv/samba/myshare
   browseable = yes
   read only = no
   guest ok = no
```
```bash
smbpasswd -a yourusername
systemctl restart smb
```

### Syncthing
Web UI at `http://localhost:8384`. Connect devices by exchanging device IDs.

### Restic (appy-backup helper)
```bash
# Initialize a backup repository
appy-backup init /var/backups/myrepo

# Backup /home (keeps 7 daily, 4 weekly, 6 monthly snapshots)
appy-backup backup /var/backups/myrepo /home

# List snapshots
appy-backup restore /var/backups/myrepo
```

### CrowdSec
Check your alerts and decisions:
```bash
cscli alerts list
cscli decisions list
```

### Zsh / Oh-My-Zsh
Add plugins in `~/.zshrc`:
```bash
plugins=(git docker kubectl zsh-autosuggestions zsh-syntax-highlighting)
```

---

## Maintenance

Run `sudo bash appy.sh` and press `M`, or use CLI flags directly:

```bash
# Full system update (pacman + AUR + Docker)
sudo bash appy.sh --update

# Back up configs
sudo bash appy.sh --backup

# Health check
sudo bash appy.sh --health

# View logs
sudo bash appy.sh --logs
```

Or manually:

```bash
# Update everything
pacman -Syu && yay -Syu

# Clean package cache
pacman -Sc

# Check failed services
systemctl --failed

# Disk usage
df -h /

# List running services
systemctl list-units --type=service --state=running

# Watch daemon log live
tail -f /var/log/appy-daemon.log
```

---

## File & Directory Reference

| Path | Purpose |
|------|---------|
| `/var/log/appy.log` | General installation and operation log |
| `/var/log/appy-daemon.log` | Watchdog daemon activity log |
| `/var/lib/appy/notifications.log` | Alert and notification history |
| `/var/lib/appy/pending_updates` | Count of pending package updates |
| `/var/backups/appy-configs/` | Config backup archives |
| `~/appy-credentials.txt` | Auto-generated passwords and tokens (mode 600) |
| `/etc/systemd/system/appy-daemon.service` | Watchdog systemd unit |
| `/etc/systemd/system/appy-update.service` | Auto-update systemd unit |
| `/etc/systemd/system/appy-update.timer` | Auto-update systemd timer |
| `/usr/local/bin/appy-daemon` | Installed daemon script |
| `/usr/local/bin/appy-backup` | Restic backup helper |

---

## Requirements

- CachyOS, Arch Linux, or any Arch-based distribution
- Run as root (`sudo bash appy.sh`)
- Internet connection
- `pacman` available
- Docker must be installed before installing Docker-based services (appy handles this automatically)

---

## License

MIT — do whatever you want with it.
