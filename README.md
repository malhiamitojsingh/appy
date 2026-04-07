# appy.sh

> Interactive service installer for CachyOS / Arch Linux.

```bash
sudo bash appy.sh
```

No flags. No config files. A numbered menu appears, you pick what you want, it installs and enables everything.

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

## How It Works

1. **Run** — Script checks you're root and on an Arch-based system
2. **Pick** — Numbered menu shows all 25 services. Type numbers space-separated (e.g. `1 3 6`) or `A` for all
3. **Done** — Services are installed via `pacman` or `yay` and immediately enabled with `systemctl`

Press **M** at the menu for maintenance options (update packages, clean cache, check services).

---

## All 25 Services

### Containers & Web

| Key | Service | Source | Port | Notes |
|-----|---------|--------|------|-------|
| `docker` | Docker | pacman | — | Container runtime. Adds user to docker group |
| `compose` | Docker Compose | pacman | — | Multi-container app orchestration via YAML |
| `nginx` | Nginx | pacman | 80, 443 | Web server and reverse proxy |
| `caddy` | Caddy | pacman | 80, 443 | Auto HTTPS via Let's Encrypt |

### Databases

| Key | Service | Source | Port | Notes |
|-----|---------|--------|------|-------|
| `mariadb` | MariaDB (MySQL) | pacman | 3306 | Root password saved to `~/appy-credentials.txt` |
| `postgres` | PostgreSQL | pacman | 5432 | Database initialized automatically |
| `redis` | Redis | pacman | 6379 | In-memory cache, bound to localhost |
| `sqlite` | SQLite | pacman | — | Embedded database, no server needed |

### Security & Networking

| Key | Service | Source | Notes |
|-----|---------|--------|-------|
| `fail2ban` | Fail2ban | pacman | Bans IPs after failed SSH attempts |
| `ufw` | UFW | pacman | Firewall: deny inbound, allow SSH |
| `wireguard` | WireGuard | pacman | Configure at `/etc/wireguard/wg0.conf` |
| `tailscale` | Tailscale | pacman | Run `tailscale up` after install to auth |

### Media & Files

| Key | Service | Source | Port | Notes |
|-----|---------|--------|------|-------|
| `jellyfin` | Jellyfin | AUR | 8096 | Free open-source media server |
| `samba` | Samba | pacman | 445 | Windows-compatible file sharing |

### Monitoring

| Key | Service | Source | Notes |
|-----|---------|--------|-------|
| `btop` | btop | pacman | Terminal resource monitor with graphs |
| `htop` | htop | pacman | Classic interactive process viewer |

### Development Tools

| Key | Service | Source | Notes |
|-----|---------|--------|-------|
| `git` | Git | pacman | Version control |
| `neovim` | Neovim | pacman | Vim-based text editor |
| `zsh` | Zsh + Oh-My-Zsh | pacman | Sets as default shell |
| `node` | Node.js + npm | pacman | LTS version |
| `python` | Python 3 + pip | pacman | |
| `golang` | Go | pacman | |

### AI & Other

| Key | Service | Source | Notes |
|-----|---------|--------|-------|
| `ollama` | Ollama | curl | Run LLMs locally. Needs 8+ GB RAM |
| `pihole` | Pi-hole | curl | Network ad blocker. Needs port 53 free |
| `timeshift` | Timeshift | AUR | System snapshots and restore |

---

## Post-Install Notes

### MariaDB
Root password is auto-generated and saved to:
```
~/appy-credentials.txt
```
Secure the installation:
```bash
mysql_secure_installation
```

### PostgreSQL
Connect as the postgres user:
```bash
sudo -u postgres psql
```
Create a database:
```bash
sudo -u postgres createdb mydb
```

### Docker
After install, re-login (or run `newgrp docker`) for the group change to take effect:
```bash
docker run hello-world
```

### WireGuard
Generate your keys and create a config:
```bash
wg genkey | tee privatekey | wg pubkey > publickey
nano /etc/wireguard/wg0.conf
systemctl enable --now wg-quick@wg0
```

### Tailscale
Authenticate after install:
```bash
tailscale up
```
For a server (advertise exit node):
```bash
tailscale up --advertise-exit-node
```

### Caddy
Edit the Caddyfile:
```bash
nano /etc/caddy/Caddyfile
systemctl reload caddy
```
Example reverse proxy:
```
yourdomain.com {
    reverse_proxy localhost:3000
}
```

### Nginx
Config files:
```
/etc/nginx/nginx.conf          # main config
/etc/nginx/sites-available/    # per-site configs
```
Test and reload:
```bash
nginx -t && systemctl reload nginx
```

### Jellyfin
First-run setup at: `http://localhost:8096`
Add media libraries pointing to your media folders.

### Ollama
Pull and run a model:
```bash
ollama pull llama3
ollama run llama3
```
API runs at `http://localhost:11434`.

### Pi-hole
Admin dashboard: `http://pi.hole/admin`
Set your router's DNS to the machine's IP.

### Samba
Add a share to `/etc/samba/smb.conf`:
```ini
[myshare]
   path = /srv/samba/myshare
   browseable = yes
   read only = no
   guest ok = no
```
Add a Samba user:
```bash
smbpasswd -a yourusername
systemctl restart smb
```

### Zsh / Oh-My-Zsh
Oh-My-Zsh is installed at `~/.oh-my-zsh`.
Add plugins in `~/.zshrc`:
```bash
plugins=(git docker kubectl zsh-autosuggestions)
```

---

## Maintenance

Re-run appy and press `M`, or run these directly:

```bash
# Update everything
pacman -Syu

# Update AUR packages
yay -Syu

# Clean package cache
pacman -Sc

# Check for failed services
systemctl --failed

# Disk usage
df -h /

# List running services
systemctl list-units --type=service --state=running
```

---

## Requirements

- CachyOS, Arch Linux, or any Arch-based distribution
- Run as root (`sudo bash appy.sh`)
- Internet connection
- `pacman` available

---

## License

MIT — do whatever you want with it.
