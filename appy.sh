#!/usr/bin/env bash
# appy — Service Installer & System Manager for CachyOS / Arch Linux
# Version: 2.0
# Usage: sudo bash appy.sh [--daemon|--health|--update|--status|--install|--remove|--backup|--logs|--version|--help]

# ── Strict mode (with safe arithmetic) ───────────────────────────────────────
# NOTE: We deliberately avoid `set -e` at the top level because `(( expr ))`
# returning 0 (false) would abort the script. We use explicit `|| true` guards
# on arithmetic and set -uo pipefail only.
set -uo pipefail

# ── Version & paths ───────────────────────────────────────────────────────────
readonly APPY_VERSION="2.0"
readonly APPY_DIR="/var/lib/appy"
readonly APPY_LOG="/var/log/appy.log"
readonly APPY_DAEMON_LOG="/var/log/appy-daemon.log"
readonly CRED_FILE="$HOME/appy-credentials.txt"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# ── Logging helpers ───────────────────────────────────────────────────────────
# Safe tee: always prints to terminal; log file failure is non-fatal
_tee_log() { local f="$1"; shift; echo -e "$*" | tee -a "$f" 2>/dev/null || echo -e "$*"; }

info()       { _tee_log "$APPY_LOG" "${GREEN}[✓]${RESET} $*"; }
warn()       { _tee_log "$APPY_LOG" "${YELLOW}[!]${RESET} $*"; }
err()        { echo -e "${RED}[✗]${RESET} $*" | tee -a "$APPY_LOG" 2>/dev/null >&2 || echo -e "${RED}[✗]${RESET} $*" >&2; }
step()       { _tee_log "$APPY_LOG" "\n${BOLD}${BLUE}▶ $*${RESET}"; }
die()        { err "$*"; exit 1; }
log()        { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$APPY_LOG" 2>/dev/null || true; }
daemon_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$APPY_DAEMON_LOG" 2>/dev/null || true; }

# ── Init directories (must run before any log call) ──────────────────────────
init_dirs() {
  mkdir -p "$APPY_DIR" /var/log 2>/dev/null || true
  touch "$APPY_LOG" "$APPY_DAEMON_LOG" 2>/dev/null || true
  touch "$APPY_DIR/notifications.log" 2>/dev/null || true
}

# ── Guards ────────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo -e "${RED}[✗]${RESET} Run as root: sudo bash appy.sh"; exit 1; }
command -v pacman &>/dev/null || { echo -e "${RED}[✗]${RESET} pacman not found — Arch/CachyOS only."; exit 1; }
init_dirs
log "appy v$APPY_VERSION started (args: ${*:-none})"

# ── Real user detection (robust) ─────────────────────────────────────────────
# SUDO_USER is the most reliable. Fall back to logname, then the first non-root
# user in /etc/passwd with a home directory, then "nobody" as last resort.
_detect_real_user() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    echo "$SUDO_USER"; return
  fi
  local lu
  lu=$(logname 2>/dev/null) && [[ -n "$lu" && "$lu" != "root" ]] && { echo "$lu"; return; }
  # Last resort: first UID >= 1000 with /bin/bash or /bin/zsh
  local u
  u=$(awk -F: '$3 >= 1000 && $3 < 65534 && ($7 ~ /bash|zsh|sh$/) {print $1; exit}' /etc/passwd 2>/dev/null)
  echo "${u:-root}"
}
REAL_USER=$(_detect_real_user)

# ── AUR helper ────────────────────────────────────────────────────────────────
ensure_yay() {
  command -v yay &>/dev/null && return 0
  step "Installing yay (AUR helper)"
  pacman -S --noconfirm --needed git base-devel || die "Failed to install build dependencies"
  local tmp="/tmp/yay-install-$$"
  rm -rf "$tmp"
  # Run git clone and makepkg as the real user, not root
  sudo -u "$REAL_USER" git clone https://aur.archlinux.org/yay-bin.git "$tmp" \
    || die "Failed to clone yay"
  # Use a subshell so cd doesn't affect the global state
  (cd "$tmp" && sudo -u "$REAL_USER" makepkg -si --noconfirm) \
    || die "Failed to build yay"
  rm -rf "$tmp"
  command -v yay &>/dev/null || die "yay installation failed"
  info "yay installed successfully"
}

# ── Package wrappers ──────────────────────────────────────────────────────────
# Use read array to safely handle multi-package strings
pac() {
  local pkgs=()
  read -ra pkgs <<< "$*"
  pacman -S --noconfirm --needed "${pkgs[@]}" 2>&1 | tee -a "$APPY_LOG" || true
}

aur() {
  ensure_yay
  local pkgs=()
  read -ra pkgs <<< "$*"
  sudo -u "$REAL_USER" yay -S --noconfirm --needed "${pkgs[@]}" 2>&1 | tee -a "$APPY_LOG" || true
}

# Enable and start a systemd service (non-fatal on error)
enable_svc() {
  local svc_name="$1"
  if systemctl enable --now "$svc_name" 2>/dev/null; then
    info "Service started: $svc_name"
  else
    warn "Could not start: $svc_name — check: systemctl status $svc_name"
  fi
}

# ── Service definitions ───────────────────────────────────────────────────────
# FORMAT: "display name|install_type|package(s)|systemd-service-name (or -)"
# install_type: pac | aur | curl | docker
declare -A S=(
  # Containers & Web
  [docker]="Docker (containers)|pac|docker|docker"
  [compose]="Docker Compose|pac|docker-compose|-"
  [nginx]="Nginx (web server)|pac|nginx|nginx"
  [caddy]="Caddy (auto HTTPS)|pac|caddy|caddy"
  [portainer]="Portainer (Docker UI)|docker|-|-"
  # Databases
  [mariadb]="MariaDB (MySQL)|pac|mariadb|mariadb"
  [postgres]="PostgreSQL|pac|postgresql|postgresql"
  [redis]="Redis (cache)|pac|redis|redis"
  [sqlite]="SQLite|pac|sqlite|-"
  [mongodb]="MongoDB|aur|mongodb-bin|mongodb"
  # Security & Networking
  [fail2ban]="Fail2ban (brute-force)|pac|fail2ban|fail2ban"
  [ufw]="UFW (firewall)|pac|ufw|ufw"
  [wireguard]="WireGuard (VPN)|pac|wireguard-tools|-"
  [tailscale]="Tailscale (VPN)|pac|tailscale|tailscaled"
  [vaultwarden]="Vaultwarden (passwords)|docker|-|-"
  [crowdsec]="CrowdSec (IPS)|pac|crowdsec|crowdsec"
  # Media & Files
  [jellyfin]="Jellyfin (media)|aur|jellyfin|jellyfin"
  [samba]="Samba (file share)|pac|samba|smb"
  [syncthing]="Syncthing (sync)|pac|syncthing|syncthing"
  # Monitoring & Observability
  [btop]="btop (monitor)|pac|btop|-"
  [htop]="htop (processes)|pac|htop|-"
  [netdata]="Netdata (real-time)|pac|netdata|netdata"
  [prometheus]="Prometheus (metrics)|pac|prometheus|prometheus"
  [grafana]="Grafana (dashboards)|pac|grafana|grafana"
  [uptime_kuma]="Uptime Kuma (uptime)|docker|-|-"
  [cockpit]="Cockpit (web admin)|pac|cockpit|cockpit"
  [loki]="Loki (log aggr.)|pac|loki|loki"
  # Development Tools
  [git]="Git|pac|git|-"
  [neovim]="Neovim|pac|neovim|-"
  [zsh]="Zsh + Oh-My-Zsh|pac|zsh|-"
  [node]="Node.js + npm|pac|nodejs npm|-"
  [python]="Python 3 + pip|pac|python python-pip|-"
  [golang]="Go (golang)|pac|go|-"
  [rust]="Rust (rustup)|pac|rustup|-"
  [docker_buildx]="Docker Buildx|pac|docker-buildx|-"
  # AI & Other
  [ollama]="Ollama (local LLMs)|curl|-|-"
  [pihole]="Pi-hole (ad block)|curl|-|-"
  [timeshift]="Timeshift (snapshots)|aur|timeshift|-"
  [restic]="Restic (backups)|pac|restic|-"
)

# Ordered list for menu display (grouped)
KEYS=(
  docker compose nginx caddy portainer
  mariadb postgres redis sqlite mongodb
  fail2ban ufw wireguard tailscale vaultwarden crowdsec
  jellyfin samba syncthing
  btop htop netdata prometheus grafana uptime_kuma cockpit loki
  git neovim zsh node python golang rust docker_buildx
  ollama pihole timeshift restic
)

# ── Post-install hooks ────────────────────────────────────────────────────────

post_docker() {
  usermod -aG docker "$REAL_USER" \
    && info "Added $REAL_USER to docker group (re-login or run: newgrp docker)"
  systemctl enable --now docker 2>/dev/null || true
}

post_postgres() {
  # initdb fails if data dir already exists — that's fine
  if [[ ! -f /var/lib/postgres/data/PG_VERSION ]]; then
    sudo -u postgres initdb -D /var/lib/postgres/data 2>/dev/null \
      || warn "PostgreSQL initdb failed — may already be initialized"
  fi
  enable_svc postgresql
}

post_mariadb() {
  # Initialize the database only if not done yet
  if [[ ! -d /var/lib/mysql/mysql ]]; then
    mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql &>/dev/null \
      || warn "mariadb-install-db failed"
  fi
  enable_svc mariadb
  # Wait for socket to be ready before running mysql commands
  local retries=10
  while (( retries-- > 0 )); do
    if mysqladmin ping --silent 2>/dev/null; then break; fi
    sleep 1
  done
  local pw
  pw=$(openssl rand -base64 16)
  # Use mariadb-admin to set root password — works even when auth is socket-only
  mysql --user=root --connect-timeout=5 \
    -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${pw}';" 2>/dev/null \
    || warn "Could not set MariaDB root password automatically — run mysql_secure_installation manually"
  {
    printf "=== MariaDB ===\nGenerated: %s\nRoot password: %s\n\n" "$(date)" "$pw"
  } >> "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  info "MariaDB root password saved to $CRED_FILE"
}

post_ufw() {
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh
  ufw --force enable
  info "UFW configured: deny all inbound, allow SSH"
}

post_zsh() {
  if [[ ! -d "/home/$REAL_USER/.oh-my-zsh" ]]; then
    sudo -u "$REAL_USER" env RUNZSH=no CHSH=no \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
      &>/dev/null || warn "Oh-My-Zsh installation failed — install manually"
  else
    info "Oh-My-Zsh already installed"
  fi
  chsh -s /bin/zsh "$REAL_USER" 2>/dev/null || warn "Could not set Zsh as default shell — run: chsh -s /bin/zsh $REAL_USER"
  info "Zsh set as default shell for $REAL_USER"
}

post_samba() {
  enable_svc nmb
}

post_rust() {
  sudo -u "$REAL_USER" rustup default stable 2>/dev/null \
    || warn "rustup default stable failed — run: rustup default stable"
}

post_prometheus() {
  if [[ ! -f /etc/prometheus/prometheus.yml ]]; then
    mkdir -p /etc/prometheus
    cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
EOF
    info "Prometheus config written to /etc/prometheus/prometheus.yml"
  fi
  # node_exporter for host metrics
  pac prometheus-node-exporter 2>/dev/null || true
  enable_svc prometheus-node-exporter 2>/dev/null || true
}

post_grafana() {
  local cfg="/etc/grafana/grafana.ini"
  local pw
  pw="appy_grafana_$(openssl rand -hex 4)"
  if [[ -f "$cfg" ]]; then
    # Uncomment and set admin_password line
    sed -i \
      "s|^;*admin_password\s*=.*|admin_password = ${pw}|" \
      "$cfg" 2>/dev/null || true
  fi
  {
    printf "=== Grafana ===\nGenerated: %s\nURL: http://localhost:3000\nAdmin user: admin\nAdmin password: %s\n\n" \
      "$(date)" "$pw"
  } >> "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  info "Grafana credentials saved to $CRED_FILE — dashboard: http://localhost:3000"
}

post_netdata() {
  info "Netdata dashboard available at http://localhost:19999"
}

post_cockpit() {
  # Open port only if ufw is active
  if ufw status 2>/dev/null | grep -q "active"; then
    ufw allow 9090/tcp 2>/dev/null || true
  fi
  info "Cockpit web UI available at https://localhost:9090"
}

post_syncthing() {
  # Syncthing runs as a user service; the system-level service is a template
  systemctl enable --now "syncthing@${REAL_USER}.service" 2>/dev/null \
    || warn "Could not start syncthing for $REAL_USER — run: systemctl enable --now syncthing@$REAL_USER"
  info "Syncthing UI available at http://localhost:8384"
}

post_mongodb() {
  {
    printf "=== MongoDB ===\nGenerated: %s\nPort: 27017\nNote: Run 'mongosh' to configure auth\n\n" "$(date)"
  } >> "$CRED_FILE"
  chmod 600 "$CRED_FILE"
}

post_crowdsec() {
  # cscli may need a moment after service start
  sleep 2
  cscli collections install crowdsecurity/linux 2>/dev/null || true
  cscli collections install crowdsecurity/sshd  2>/dev/null || true
  info "CrowdSec installed with Linux + SSH collections"
}

post_loki() {
  if [[ ! -f /etc/loki/loki.yaml ]]; then
    mkdir -p /etc/loki /var/lib/loki/index /var/lib/loki/index_cache /var/lib/loki/chunks
    cat > /etc/loki/loki.yaml <<'EOF'
auth_enabled: false
server:
  http_listen_port: 3100
ingester:
  lifecycler:
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
schema_config:
  configs:
    - from: 2024-01-01
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h
storage_config:
  boltdb_shipper:
    active_index_directory: /var/lib/loki/index
    cache_location: /var/lib/loki/index_cache
  filesystem:
    directory: /var/lib/loki/chunks
limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
EOF
    # Fix ownership if loki user exists
    id loki &>/dev/null && chown -R loki:loki /var/lib/loki /etc/loki 2>/dev/null || true
    info "Loki config written to /etc/loki/loki.yaml"
  fi
}

post_restic() {
  cat > /usr/local/bin/appy-backup <<'BKUP'
#!/usr/bin/env bash
# appy-backup: restic backup helper
# Usage: appy-backup init <repo> | backup <repo> <path> | restore <repo>
set -uo pipefail
CMD="${1:-help}"
REPO="${2:-/var/backups/restic}"
SOURCE="${3:-/home}"

case "$CMD" in
  init)
    restic init --repo "$REPO"
    echo "Repo initialized at $REPO"
    ;;
  backup)
    restic backup --repo "$REPO" "$SOURCE" --exclude-caches
    restic forget --repo "$REPO" --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
    echo "Backup complete. Old snapshots pruned."
    ;;
  restore)
    echo "Available snapshots:"
    restic snapshots --repo "$REPO"
    ;;
  *)
    echo "Usage: appy-backup [init|backup|restore] [repo] [source]"
    ;;
esac
BKUP
  chmod +x /usr/local/bin/appy-backup
  info "appy-backup helper installed at /usr/local/bin/appy-backup"
}

# ── Docker-based service installers ──────────────────────────────────────────

ensure_docker_running() {
  if ! command -v docker &>/dev/null; then
    warn "Docker not installed. Installing first..."
    do_install docker
  fi
  systemctl start docker 2>/dev/null || true
  # Wait up to 10 seconds for the daemon socket
  local i=0
  while (( i < 10 )); do
    docker info &>/dev/null 2>&1 && return 0
    sleep 1
    (( i++ )) || true
  done
  warn "Docker socket not ready — containers may fail to start"
}

install_portainer() {
  ensure_docker_running
  docker volume create portainer_data 2>/dev/null || true
  if docker inspect portainer &>/dev/null 2>&1; then
    docker start portainer 2>/dev/null || true
  else
    docker run -d \
      --name=portainer \
      --restart=always \
      -p 8000:8000 -p 9443:9443 \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      portainer/portainer-ce:latest
  fi
  info "Portainer running at https://localhost:9443"
}

install_vaultwarden() {
  ensure_docker_running
  local vw_data="/var/lib/vaultwarden"
  mkdir -p "$vw_data"
  local admin_token
  admin_token=$(openssl rand -base64 48)
  if docker inspect vaultwarden &>/dev/null 2>&1; then
    docker start vaultwarden 2>/dev/null || true
  else
    docker run -d \
      --name=vaultwarden \
      --restart=always \
      -p 8222:80 \
      -v "${vw_data}:/data" \
      -e ADMIN_TOKEN="$admin_token" \
      -e WEBSOCKET_ENABLED=true \
      vaultwarden/server:latest
    {
      printf "=== Vaultwarden ===\nGenerated: %s\nURL: http://localhost:8222\nAdmin token: %s\nAdmin panel: http://localhost:8222/admin\n\n" \
        "$(date)" "$admin_token"
    } >> "$CRED_FILE"
    chmod 600 "$CRED_FILE"
  fi
  info "Vaultwarden running at http://localhost:8222 — admin token saved to $CRED_FILE"
}

install_uptime_kuma() {
  ensure_docker_running
  docker volume create uptime-kuma 2>/dev/null || true
  if docker inspect uptime-kuma &>/dev/null 2>&1; then
    docker start uptime-kuma 2>/dev/null || true
  else
    docker run -d \
      --name=uptime-kuma \
      --restart=always \
      -p 3001:3001 \
      -v uptime-kuma:/app/data \
      louislam/uptime-kuma:latest
  fi
  info "Uptime Kuma running at http://localhost:3001"
}

# ── Curl-based installers ─────────────────────────────────────────────────────

install_ollama() {
  if command -v ollama &>/dev/null; then
    info "Ollama already installed"
  else
    curl -fsSL https://ollama.ai/install.sh | sh || die "Ollama installation failed"
  fi
  enable_svc ollama
  info "Ollama API at http://localhost:11434 — run: ollama pull llama3"
}

install_pihole() {
  warn "Pi-hole requires port 53 to be free. The interactive installer will launch."
  warn "Make sure no other DNS service (systemd-resolved, etc.) is using port 53."
  curl -sSL https://install.pi-hole.net | bash
}

# docker_buildx is pac type but has no extra steps needed (docker already handles it)
# Keeping this stub so do_install doesn't error when type=pac and no function exists
# (do_install only calls install_$key for curl/docker types)

# ── Core install dispatcher ───────────────────────────────────────────────────
do_install() {
  local key="$1"
  local spec="${S[$key]:-}"
  if [[ -z "$spec" ]]; then
    err "Unknown service key: '$key'"; return 1
  fi

  local display type pkg service
  IFS='|' read -r display type pkg service <<< "$spec"

  step "Installing $display"
  log "Installing: $key ($display)"

  # Skip if already installed (pac/aur only — Docker containers checked separately)
  if [[ "$type" == "pac" && "$pkg" != "-" ]]; then
    local first_pkg
    first_pkg=$(awk '{print $1}' <<< "$pkg")
    if pacman -Qi "$first_pkg" &>/dev/null 2>&1; then
      info "Already installed: $display"; return 0
    fi
  elif [[ "$type" == "aur" && "$pkg" != "-" ]]; then
    local first_pkg
    first_pkg=$(awk '{print $1}' <<< "$pkg")
    if pacman -Qi "$first_pkg" &>/dev/null 2>&1; then
      info "Already installed: $display"; return 0
    fi
  fi

  # Install
  case "$type" in
    pac)
      pac "$pkg"
      ;;
    aur)
      aur "$pkg"
      ;;
    curl|docker)
      local fn="install_${key}"
      if declare -f "$fn" &>/dev/null; then
        "$fn"
      else
        err "No installer function found for: $key (expected: $fn)"
        return 1
      fi
      ;;
    *)
      err "Unknown install type '$type' for $key"
      return 1
      ;;
  esac

  # Enable systemd service (only for pac/aur; curl/docker handle their own)
  if [[ "$type" =~ ^(pac|aur)$ && "$service" != "-" ]]; then
    enable_svc "$service"
  fi

  # Run post-install hook if defined
  local post_fn="post_${key}"
  if declare -f "$post_fn" &>/dev/null; then
    "$post_fn"
  fi

  log "Installed: $key"
  info "$display installed successfully."
}

# ══════════════════════════════════════════════════════════════════════════════
# ── DAEMON / WATCHDOG MODE ────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

DAEMON_INTERVAL="${APPY_DAEMON_INTERVAL:-300}"
NOTIFY_EMAIL="${APPY_NOTIFY_EMAIL:-}"

get_watched_services() {
  local svc_name
  for key in "${KEYS[@]}"; do
    local spec="${S[$key]:-}"
    [[ -z "$spec" ]] && continue
    IFS='|' read -r _ _ _ svc_name <<< "$spec"
    [[ "$svc_name" == "-" ]] && continue
    # Check the unit file exists and is enabled
    if systemctl list-unit-files "${svc_name}.service" &>/dev/null 2>&1 \
       && systemctl is-enabled "$svc_name" &>/dev/null 2>&1; then
      echo "$svc_name"
    fi
  done
}

watchdog_check_service() {
  local svc_name="$1"
  if ! systemctl is-active --quiet "$svc_name" 2>/dev/null; then
    daemon_log "WARN: $svc_name is DOWN — attempting restart"
    systemctl restart "$svc_name" 2>/dev/null || true
    sleep 3
    if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
      daemon_log "OK: $svc_name restarted successfully"
      send_notification "✓ appy recovered $svc_name" "$svc_name was down and has been restarted."
    else
      daemon_log "ERROR: $svc_name failed to restart"
      send_notification "✗ appy FAILED to recover $svc_name" "$svc_name is still down after restart attempt."
    fi
  fi
}

health_snapshot() {
  # CachyOS/Arch uses '%Cpu(s):' format — handle both formats
  local cpu_line
  cpu_line=$(top -bn1 2>/dev/null | grep -E "^(%Cpu|Cpu)" | head -1)
  local cpu_idle=0
  if [[ -n "$cpu_line" ]]; then
    # Extract idle value — field position varies; look for 'id' token
    cpu_idle=$(echo "$cpu_line" | grep -oP '[0-9]+\.?[0-9]*(?=\s*id)' | head -1 || echo "0")
  fi
  local cpu_used
  cpu_used=$(awk "BEGIN{printf \"%.0f\", 100 - ${cpu_idle:-0}}" 2>/dev/null || echo "?")

  local mem_total mem_avail mem_used_pct
  mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  mem_used_pct=$(awk "BEGIN{printf \"%.0f\", (1 - ${mem_avail}/${mem_total}) * 100}" 2>/dev/null || echo "?")

  local disk_used
  disk_used=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo "?")

  local load
  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "?")

  echo "cpu=${cpu_used}% mem=${mem_used_pct}% disk=${disk_used}% load=${load}"
}

send_notification() {
  local subject="$1"
  local body="$2"
  daemon_log "NOTIFY: $subject"
  if [[ -n "$NOTIFY_EMAIL" ]] && command -v mail &>/dev/null; then
    echo "$body" | mail -s "[appy] $subject" "$NOTIFY_EMAIL" 2>/dev/null || true
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $subject" >> "$APPY_DIR/notifications.log" 2>/dev/null || true
}

install_daemon() {
  step "Installing appy watchdog daemon"
  local script_src
  script_src=$(realpath "$0" 2>/dev/null || echo "/usr/local/bin/appy-daemon")
  local script_dest="/usr/local/bin/appy-daemon"

  cp "$script_src" "$script_dest" || die "Failed to copy appy to $script_dest"
  chmod +x "$script_dest"

  cat > /etc/systemd/system/appy-daemon.service <<EOF
[Unit]
Description=appy System Manager Daemon (watchdog + health monitor)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${script_dest} --daemon
Restart=always
RestartSec=10
Environment=APPY_DAEMON_INTERVAL=${DAEMON_INTERVAL}
Environment=APPY_NOTIFY_EMAIL=${NOTIFY_EMAIL}
StandardOutput=append:${APPY_DAEMON_LOG}
StandardError=append:${APPY_DAEMON_LOG}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now appy-daemon
  info "appy-daemon installed and running"
  info "Logs:   tail -f $APPY_DAEMON_LOG"
  info "Status: systemctl status appy-daemon"
}

remove_daemon() {
  systemctl stop    appy-daemon 2>/dev/null || true
  systemctl disable appy-daemon 2>/dev/null || true
  rm -f /etc/systemd/system/appy-daemon.service /usr/local/bin/appy-daemon
  systemctl daemon-reload
  info "appy-daemon removed"
}

run_daemon() {
  daemon_log "appy-daemon v$APPY_VERSION started (interval=${DAEMON_INTERVAL}s)"

  local last_update_check=0
  local last_log_rotate=0
  local update_check_interval=$(( 6 * 3600 ))
  local log_rotate_interval=$(( 24 * 3600 ))

  while true; do
    local now
    now=$(date +%s)

    # Watchdog: check all enabled services
    local svc_name
    while IFS= read -r svc_name; do
      [[ -n "$svc_name" ]] && watchdog_check_service "$svc_name"
    done < <(get_watched_services)

    # Health snapshot
    local snap
    snap=$(health_snapshot)
    daemon_log "HEALTH: $snap"

    # Extract thresholds
    local disk_pct mem_pct
    disk_pct=$(echo "$snap" | grep -oP 'disk=\K[0-9]+' || echo 0)
    mem_pct=$(echo "$snap"  | grep -oP 'mem=\K[0-9]+'  || echo 0)

    [[ "${disk_pct:-0}" -gt 90 ]] && \
      send_notification "⚠ Disk usage critical: ${disk_pct}%" "Root filesystem is ${disk_pct}% full."
    [[ "${mem_pct:-0}"  -gt 95 ]] && \
      send_notification "⚠ Memory usage critical: ${mem_pct}%" "System memory is ${mem_pct}% used."

    # Update check (every 6 hours)
    if (( now - last_update_check > update_check_interval )); then
      daemon_log "Checking for package updates..."
      local updates=0
      updates=$(pacman -Qu 2>/dev/null | wc -l || echo 0)
      if [[ "$updates" -gt 0 ]]; then
        daemon_log "INFO: $updates package(s) available for update"
        send_notification "📦 $updates system update(s) available" "Run 'pacman -Syu' or press U in appy menu."
        echo "$updates" > "$APPY_DIR/pending_updates"
      else
        rm -f "$APPY_DIR/pending_updates"
      fi
      last_update_check=$now
    fi

    # Log rotation (every 24 hours)
    if (( now - last_log_rotate > log_rotate_interval )); then
      rotate_logs
      last_log_rotate=$now
    fi

    sleep "$DAEMON_INTERVAL"
  done
}

rotate_logs() {
  daemon_log "Checking log rotation..."
  local max_size=$(( 10 * 1024 * 1024 ))  # 10 MB
  local logfile
  for logfile in "$APPY_LOG" "$APPY_DAEMON_LOG" "$APPY_DIR/notifications.log"; do
    [[ ! -f "$logfile" ]] && continue
    local size=0
    size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
    if (( size > max_size )); then
      mv "$logfile" "${logfile}.$(date +%Y%m%d_%H%M%S).bak"
      touch "$logfile"
      # Keep only last 3 rotated backups per log
      ls -t "${logfile}."*".bak" 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
      daemon_log "Rotated: $logfile"
    fi
  done
}

# ── System health check (interactive display) ─────────────────────────────────
run_health_check() {
  clear
  local LINE="${BOLD}${CYAN}═══════════════════════════════════════════════════${RESET}"
  echo -e "$LINE"
  echo -e "${BOLD}${CYAN}          appy System Health Report                ${RESET}"
  echo -e "$LINE"
  echo -e "${DIM}  $(date)${RESET}\n"

  # CPU — CachyOS/Arch top may output '%Cpu(s):' or 'Cpu(s):'
  local cpu_line cpu_idle cpu_pct cpu_col
  cpu_line=$(top -bn1 2>/dev/null | grep -E "^(%Cpu|Cpu)" | head -1)
  cpu_idle=$(echo "$cpu_line" | grep -oP '[0-9]+\.?[0-9]*(?=\s*id)' | head -1 || echo "0")
  cpu_pct=$(awk "BEGIN{printf \"%.1f\", 100 - ${cpu_idle:-0}}" 2>/dev/null || echo "?")
  cpu_col="$GREEN"
  local cpu_int=${cpu_pct%.*}
  (( cpu_int > 80 )) && cpu_col="$RED" || true
  (( cpu_int > 60 && cpu_int <= 80 )) && cpu_col="$YELLOW" || true
  echo -e "  ${BOLD}CPU Usage:${RESET}      ${cpu_col}${cpu_pct}%${RESET}"

  # Memory
  local mem_total mem_avail mem_used_pct mem_used_mb mem_total_mb mem_col
  mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  mem_used_pct=$(awk "BEGIN{printf \"%.1f\", (1-${mem_avail}/${mem_total})*100}" 2>/dev/null || echo "?")
  mem_used_mb=$(awk "BEGIN{printf \"%.0f\", (${mem_total}-${mem_avail})/1024}" 2>/dev/null || echo "?")
  mem_total_mb=$(awk "BEGIN{printf \"%.0f\", ${mem_total}/1024}" 2>/dev/null || echo "?")
  mem_col="$GREEN"
  local mem_int=${mem_used_pct%.*}
  (( mem_int > 85 )) && mem_col="$RED" || true
  (( mem_int > 70 && mem_int <= 85 )) && mem_col="$YELLOW" || true
  echo -e "  ${BOLD}Memory:${RESET}         ${mem_col}${mem_used_pct}%${RESET} (${mem_used_mb}MB / ${mem_total_mb}MB)"

  # Disk
  local disk_info disk_pct disk_used disk_total disk_col
  disk_info=$(df -h / | tail -1)
  disk_pct=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')
  disk_used=$(echo "$disk_info" | awk '{print $3}')
  disk_total=$(echo "$disk_info" | awk '{print $2}')
  disk_col="$GREEN"
  (( ${disk_pct:-0} > 85 )) && disk_col="$RED" || true
  (( ${disk_pct:-0} > 70 && ${disk_pct:-0} <= 85 )) && disk_col="$YELLOW" || true
  echo -e "  ${BOLD}Disk (/):${RESET}       ${disk_col}${disk_pct}%${RESET} (${disk_used} / ${disk_total})"

  # Load
  local load1 load5 load15
  read -r load1 load5 load15 _ < /proc/loadavg
  echo -e "  ${BOLD}Load Average:${RESET}   ${load1} (1m)  ${load5} (5m)  ${load15} (15m)"

  # Uptime
  local uptime_str
  uptime_str=$(uptime -p 2>/dev/null || uptime)
  echo -e "  ${BOLD}Uptime:${RESET}         $uptime_str"

  # Network
  echo -e "\n  ${BOLD}${BLUE}Network:${RESET}"
  ip -o -4 addr show 2>/dev/null \
    | awk '{printf "    %-12s %s\n", $2, $4}' \
    | grep -v '^\s*lo ' \
    || echo "    (no interfaces)"

  # Managed services status
  echo -e "\n  ${BOLD}${BLUE}Managed Services:${RESET}"
  local all_ok=true
  local key svc_name display spec
  for key in "${KEYS[@]}"; do
    spec="${S[$key]:-}"; [[ -z "$spec" ]] && continue
    IFS='|' read -r display _ _ svc_name <<< "$spec"
    [[ "$svc_name" == "-" ]] && continue
    if systemctl list-unit-files "${svc_name}.service" &>/dev/null 2>&1 \
       && systemctl is-enabled "$svc_name" &>/dev/null 2>&1; then
      if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
        printf "  ${GREEN}●${RESET} %-24s ${GREEN}running${RESET}\n" "$display"
      else
        printf "  ${RED}●${RESET} %-24s ${RED}stopped${RESET}\n" "$display"
        all_ok=false
      fi
    fi
  done

  # Docker containers
  if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    echo -e "\n  ${BOLD}${BLUE}Docker Containers:${RESET}"
    local container_list
    container_list=$(docker ps -a --format "  {{.Names}}|{{.Status}}" 2>/dev/null || true)
    if [[ -n "$container_list" ]]; then
      while IFS='|' read -r cname cstatus; do
        if [[ "$cstatus" == Up* ]]; then
          printf "  ${GREEN}●${RESET} %-22s ${GREEN}%s${RESET}\n" "$cname" "$cstatus"
        else
          printf "  ${RED}●${RESET} %-22s ${RED}%s${RESET}\n" "$cname" "$cstatus"
        fi
      done <<< "$container_list"
    else
      echo "    (no containers)"
    fi
  fi

  # Pending updates
  if [[ -f "$APPY_DIR/pending_updates" ]]; then
    local upd
    upd=$(cat "$APPY_DIR/pending_updates")
    echo -e "\n  ${YELLOW}[!] $upd package update(s) available — press U in main menu${RESET}"
  fi

  # Failed services (system-wide)
  local failed=0
  failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l || echo 0)
  if [[ "$failed" -gt 0 ]]; then
    echo -e "\n  ${RED}[!] $failed systemd service(s) failed system-wide:${RESET}"
    systemctl --failed --no-legend 2>/dev/null | awk '{print "    - "$1}' || true
  fi

  echo ""
  if $all_ok; then
    echo -e "  ${GREEN}${BOLD}All monitored services are healthy.${RESET}"
  else
    echo -e "  ${YELLOW}${BOLD}Some services need attention (see above).${RESET}"
  fi
  echo -e "\n$LINE"
  log "Health check completed"
  read -rp "  Press Enter to continue..."
}

# ── Auto-update ───────────────────────────────────────────────────────────────
run_auto_update() {
  step "Running full system update"
  log "Auto-update started"

  echo -e "\n  ${BOLD}[1/4] Updating pacman packages...${RESET}"
  pacman -Syu --noconfirm 2>&1 | tee -a "$APPY_LOG" || warn "pacman update had errors"

  if command -v yay &>/dev/null; then
    echo -e "\n  ${BOLD}[2/4] Updating AUR packages...${RESET}"
    sudo -u "$REAL_USER" yay -Syu --noconfirm 2>&1 | tee -a "$APPY_LOG" || warn "yay update had errors"
  else
    echo -e "\n  ${BOLD}[2/4] Skipping AUR (yay not installed)${RESET}"
  fi

  echo -e "\n  ${BOLD}[3/4] Updating Docker images...${RESET}"
  if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    docker ps --format "{{.Image}}" 2>/dev/null | sort -u | while IFS= read -r img; do
      [[ -z "$img" ]] && continue
      echo "  Pulling: $img"
      docker pull "$img" 2>/dev/null | grep -E "Status:|Digest:|error" || true
    done
    info "Docker images updated"
  else
    echo "  Docker not running — skipping."
  fi

  echo -e "\n  ${BOLD}[4/4] Cleaning package cache...${RESET}"
  pacman -Sc --noconfirm 2>&1 | tail -3 || true
  rm -f "$APPY_DIR/pending_updates"

  log "Auto-update completed"
  info "System fully updated!"
  read -rp "  Press Enter to continue..."
}

# ── Config backup ─────────────────────────────────────────────────────────────
run_config_backup() {
  local backup_dir="/var/backups/appy-configs"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local archive="$backup_dir/configs_${timestamp}.tar.gz"

  step "Backing up service configurations"
  mkdir -p "$backup_dir"

  local -a config_paths=(
    /etc/nginx
    /etc/caddy
    /etc/prometheus
    /etc/grafana
    /etc/loki
    /etc/fail2ban
    /etc/ufw
    /etc/wireguard
    /etc/samba
    /etc/redis.conf
    /etc/my.cnf
    /etc/mysql
    /etc/postgresql
    /etc/systemd/system/appy-daemon.service
    /etc/systemd/system/appy-update.service
    /etc/systemd/system/appy-update.timer
    "$CRED_FILE"
    "$APPY_DIR"
  )

  local -a existing=()
  local p
  for p in "${config_paths[@]}"; do
    [[ -e "$p" ]] && existing+=("$p")
  done

  if [[ ${#existing[@]} -eq 0 ]]; then
    warn "No configuration files found to back up."
    read -rp "  Press Enter to continue..."; return
  fi

  if tar -czf "$archive" "${existing[@]}" 2>/dev/null; then
    info "Config backup saved to: $archive"
  else
    warn "Backup completed with some warnings (non-critical)"
  fi

  # Keep only last 5 backups
  ls -t "$backup_dir"/configs_*.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

  local size
  size=$(du -sh "$archive" 2>/dev/null | awk '{print $1}' || echo "?")
  info "Backup size: $size"
  log "Config backup created: $archive"
  read -rp "  Press Enter to continue..."
}

# ── Service rollback / removal ────────────────────────────────────────────────
run_rollback_menu() {
  clear
  echo -e "${BOLD}${RED}Remove / Rollback a Service${RESET}\n"

  local i=1
  declare -A idx_to_key=()
  local key display type pkg svc_name spec installed

  for key in "${KEYS[@]}"; do
    spec="${S[$key]:-}"; [[ -z "$spec" ]] && continue
    IFS='|' read -r display type pkg svc_name <<< "$spec"
    installed=false
    if [[ "$type" =~ ^(pac|aur)$ && "$pkg" != "-" ]]; then
      local fp
      fp=$(awk '{print $1}' <<< "$pkg")
      pacman -Qi "$fp" &>/dev/null 2>&1 && installed=true
    elif [[ "$type" == "docker" ]]; then
      docker inspect "${key//_/-}" &>/dev/null 2>&1 && installed=true
    fi
    if $installed; then
      printf "  ${BLUE}%2d)${RESET} %s\n" "$i" "$display"
      idx_to_key[$i]="$key"
      (( i++ )) || true
    fi
  done

  if [[ $i -eq 1 ]]; then
    echo "  No appy-installed services detected."
    read -rp "  Press Enter..."; return
  fi

  echo ""
  read -rp "  Enter number to remove (or Q to cancel): " choice
  [[ "${choice,,}" == "q" ]] && return

  local chosen_key="${idx_to_key[$choice]:-}"
  if [[ -z "$chosen_key" ]]; then
    warn "Invalid choice."
    read -rp "  Press Enter..."; return
  fi

  spec="${S[$chosen_key]}"
  IFS='|' read -r display type pkg svc_name <<< "$spec"

  echo ""
  read -rp "  Remove '$display'? This will stop, disable, and uninstall it. [y/N]: " confirm
  [[ "${confirm,,}" != "y" ]] && return

  step "Removing $display"

  if [[ "$svc_name" != "-" ]]; then
    systemctl stop    "$svc_name" 2>/dev/null || true
    systemctl disable "$svc_name" 2>/dev/null || true
  fi

  case "$type" in
    pac)
      local pkg_arr=()
      read -ra pkg_arr <<< "$pkg"
      pacman -Rns --noconfirm "${pkg_arr[@]}" 2>/dev/null \
        || warn "Some packages could not be removed"
      ;;
    aur)
      ensure_yay
      local pkg_arr=()
      read -ra pkg_arr <<< "$pkg"
      sudo -u "$REAL_USER" yay -Rns --noconfirm "${pkg_arr[@]}" 2>/dev/null \
        || warn "Some AUR packages could not be removed"
      ;;
    docker)
      local cname="${chosen_key//_/-}"
      docker stop "$cname" 2>/dev/null || true
      docker rm   "$cname" 2>/dev/null || true
      ;;
  esac

  log "Removed: $chosen_key ($display)"
  info "$display removed."
  read -rp "  Press Enter to continue..."
}

# ── Notifications log viewer ──────────────────────────────────────────────────
view_notifications() {
  clear
  echo -e "${BOLD}${CYAN}Recent Notifications${RESET}\n"
  if [[ -s "$APPY_DIR/notifications.log" ]]; then
    tail -30 "$APPY_DIR/notifications.log"
  else
    echo "  No notifications yet."
  fi
  echo ""
  read -rp "  Press Enter to continue..."
}

# ── Auto-update scheduler ─────────────────────────────────────────────────────
setup_scheduler() {
  clear
  echo -e "${BOLD}${CYAN}Auto-Update Scheduler${RESET}\n"
  echo "  Configure automatic system updates via systemd timer."
  echo ""
  echo "  1) Daily at 3:00 AM"
  echo "  2) Weekly (Sunday 3:00 AM)"
  echo "  3) Manual only (disable timer)"
  echo "  4) Back"
  echo ""
  read -rp "  Choice: " sched_choice

  local on_calendar=""
  case "$sched_choice" in
    1) on_calendar="*-*-* 03:00:00" ;;
    2) on_calendar="Sun *-*-* 03:00:00" ;;
    3)
      systemctl stop    appy-update.timer 2>/dev/null || true
      systemctl disable appy-update.timer 2>/dev/null || true
      rm -f /etc/systemd/system/appy-update.{service,timer}
      systemctl daemon-reload
      info "Auto-update scheduler disabled."
      read -rp "  Press Enter..."; return
      ;;
    *) return ;;
  esac

  # Ensure the daemon script is installed before writing the unit
  local script_dest="/usr/local/bin/appy-daemon"
  if [[ ! -f "$script_dest" ]]; then
    local script_src
    script_src=$(realpath "$0" 2>/dev/null || echo "")
    if [[ -n "$script_src" && -f "$script_src" ]]; then
      cp "$script_src" "$script_dest"
      chmod +x "$script_dest"
    else
      warn "Cannot find source script to install as $script_dest — install daemon first (M → 7)"
      read -rp "  Press Enter..."; return
    fi
  fi

  cat > /etc/systemd/system/appy-update.service <<EOF
[Unit]
Description=appy Automatic System Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${script_dest} --update
StandardOutput=append:${APPY_LOG}
StandardError=append:${APPY_LOG}
EOF

  cat > /etc/systemd/system/appy-update.timer <<EOF
[Unit]
Description=appy Auto-Update Timer

[Timer]
OnCalendar=${on_calendar}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now appy-update.timer
  info "Auto-update scheduled: $on_calendar"
  info "Check: systemctl list-timers appy-update.timer"
  read -rp "  Press Enter to continue..."
}

# ── Maintenance menu ──────────────────────────────────────────────────────────
maintenance_menu() {
  while true; do
    clear
    echo -e "${BOLD}${CYAN}Maintenance & Management${RESET}\n"

    if systemctl is-active --quiet appy-daemon 2>/dev/null; then
      echo -e "  ${GREEN}●${RESET} appy-daemon is ${GREEN}running${RESET} (watchdog active)"
    else
      echo -e "  ${RED}●${RESET} appy-daemon is ${RED}not running${RESET}"
    fi

    if [[ -f "$APPY_DIR/pending_updates" ]]; then
      local upd
      upd=$(cat "$APPY_DIR/pending_updates")
      echo -e "  ${YELLOW}[!] $upd update(s) pending${RESET}"
    fi
    echo ""

    echo "  ── System ────────────────────────────────────────"
    echo "   1) Full system health check"
    echo "   2) Update all packages (pacman + AUR + Docker)"
    echo "   3) Clean package & Docker cache"
    echo "   4) Show failed services"
    echo "   5) Disk usage breakdown"
    echo "   6) Running services list"
    echo ""
    echo "  ── appy Daemon ───────────────────────────────────"
    echo "   7) Install / restart appy watchdog daemon"
    echo "   8) Remove appy watchdog daemon"
    echo "   9) View daemon logs (last 50 lines)"
    echo "  10) View notifications"
    echo "  11) Setup auto-update schedule"
    echo ""
    echo "  ── Backup & Recovery ─────────────────────────────"
    echo "  12) Back up all service configs"
    echo "  13) Remove / rollback a service"
    echo ""
    echo -e "  ${YELLOW}B)${RESET} Back to main menu"
    echo ""
    read -rp "  Choice: " m

    case "$m" in
      1) run_health_check ;;
      2) run_auto_update ;;
      3)
        pacman -Sc --noconfirm 2>&1 | tail -5 || true
        if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
          docker system prune -f 2>/dev/null || true
          info "Docker cache pruned"
        fi
        info "Cache cleaned"
        read -rp "  Press Enter..."
        ;;
      4)
        systemctl --failed 2>/dev/null || true
        read -rp "  Press Enter..."
        ;;
      5)
        df -h; echo ""
        du -sh /var/cache/pacman/pkg 2>/dev/null || true
        if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
          docker system df 2>/dev/null || true
        fi
        read -rp "  Press Enter..."
        ;;
      6)
        systemctl list-units --type=service --state=running 2>/dev/null || true
        read -rp "  Press Enter..."
        ;;
      7) install_daemon; read -rp "  Press Enter..." ;;
      8) remove_daemon;  read -rp "  Press Enter..." ;;
      9)
        echo ""
        tail -50 "$APPY_DAEMON_LOG" 2>/dev/null || echo "  No daemon log found."
        read -rp "  Press Enter..."
        ;;
      10) view_notifications ;;
      11) setup_scheduler ;;
      12) run_config_backup ;;
      13) run_rollback_menu ;;
      b|B) return ;;
      *) warn "Invalid choice: $m" ;;
    esac
  done
}

# ── Main interactive menu ─────────────────────────────────────────────────────
main_menu() {
  # Build a stable index → key mapping once per menu render
  # (associative array ordering is undefined; KEYS array defines the order)

  while true; do
    clear
    echo -e "${BOLD}${GREEN}"
    echo "   ██████╗  ██████╗  ██████╗ ██╗   ██╗"
    echo "  ██╔═══██╗ ██╔══██╗ ██╔══██╗╚██╗ ██╔╝"
    echo "  ███████║  ██████╔╝ ██████╔╝ ╚████╔╝ "
    echo "  ██╔══██║  ██╔═══╝  ██╔═══╝   ╚██╔╝  "
    echo "  ██║  ██║  ██║      ██║        ██║   "
    echo "  ╚═╝  ╚═╝  ╚═╝      ╚═╝        ╚═╝   "
    echo -e "${RESET}  CachyOS / Arch Service Installer  v${APPY_VERSION}\n"

    # Status bar
    if systemctl is-active --quiet appy-daemon 2>/dev/null; then
      echo -e "  ${DIM}watchdog: ${GREEN}●${RESET}${DIM} running${RESET}  |  logs: $APPY_LOG"
    else
      echo -e "  ${DIM}watchdog: ${RED}○ off${RESET}${DIM}  |  logs: $APPY_LOG${RESET}"
    fi
    if [[ -f "$APPY_DIR/pending_updates" ]]; then
      local upd
      upd=$(cat "$APPY_DIR/pending_updates" 2>/dev/null || echo "?")
      echo -e "  ${YELLOW}[!] ${upd} update(s) pending — press U to update${RESET}"
    fi
    echo ""

    # Build index → key map and display grouped menu
    declare -A idx_to_key=()
    local i=1

    local -a groups=(
      "Containers & Web|docker compose nginx caddy portainer"
      "Databases|mariadb postgres redis sqlite mongodb"
      "Security & Net|fail2ban ufw wireguard tailscale vaultwarden crowdsec"
      "Media & Files|jellyfin samba syncthing"
      "Monitoring|btop htop netdata prometheus grafana uptime_kuma cockpit loki"
      "Development|git neovim zsh node python golang rust docker_buildx"
      "AI & Other|ollama pihole timeshift restic"
    )

    local group_entry group_name group_keys key spec display type pkg svc_name mark col

    for group_entry in "${groups[@]}"; do
      group_name="${group_entry%%|*}"
      group_keys="${group_entry#*|}"

      printf "  ${DIM}── %-20s ──────────────────────────────${RESET}\n" "$group_name"

      col=0
      for key in $group_keys; do
        spec="${S[$key]:-}"; [[ -z "$spec" ]] && continue
        IFS='|' read -r display type pkg svc_name <<< "$spec"

        # Installed check
        mark=" "
        if [[ "$type" =~ ^(pac|aur)$ && "$pkg" != "-" ]]; then
          local fp
          fp=$(awk '{print $1}' <<< "$pkg")
          pacman -Qi "$fp" &>/dev/null 2>&1 && mark="${GREEN}✓${RESET}"
        elif [[ "$type" == "docker" ]]; then
          docker inspect "${key//_/-}" &>/dev/null 2>&1 && mark="${GREEN}✓${RESET}"
        fi

        printf "  ${BLUE}%2d)${RESET} [%b] %-25s" "$i" "$mark" "$display"
        idx_to_key[$i]="$key"
        (( i++ )) || true
        (( col++ )) || true
        if (( col % 2 == 0 )); then echo ""; fi
      done
      # Close odd row
      (( col % 2 != 0 )) && echo "" || true
      echo ""
    done

    echo -e "  ${YELLOW}A)${RESET} Install ALL services"
    echo -e "  ${YELLOW}U)${RESET} Update system (packages + Docker)"
    echo -e "  ${YELLOW}H)${RESET} Health check"
    echo -e "  ${YELLOW}M)${RESET} Maintenance & Daemon"
    echo -e "  ${YELLOW}Q)${RESET} Quit"
    echo ""
    echo -e "${BOLD}  Enter number(s) (e.g. 1 3 7), or a letter:${RESET}"
    read -rp "  → " input
    echo ""

    # Lowercase input for letter commands
    local input_lower="${input,,}"

    case "$input_lower" in
      q) info "Goodbye!"; exit 0 ;;
      m) maintenance_menu; continue ;;
      h) run_health_check; continue ;;
      u) run_auto_update; continue ;;
      a)
        local k
        for k in "${KEYS[@]}"; do
          do_install "$k" || true
        done
        echo -e "\n${GREEN}${BOLD}All services installation complete!${RESET}"
        read -rp "  Press Enter to continue..."
        continue
        ;;
    esac

    # Numeric selections
    local installed_count=0
    local token
    for token in $input; do
      if [[ "$token" =~ ^[0-9]+$ ]]; then
        if [[ -n "${idx_to_key[$token]+_}" ]]; then
          do_install "${idx_to_key[$token]}" && (( installed_count++ )) || true
        else
          warn "No service mapped to number: $token"
        fi
      else
        warn "Invalid input: '$token' — enter a number or letter"
      fi
    done

    if [[ "$installed_count" -gt 0 ]]; then
      echo -e "\n${GREEN}${BOLD}Done! $installed_count service(s) processed.${RESET}"
    fi
    read -rp "  Press Enter to continue..."
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# ── CLI entry point ───────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════
case "${1:-}" in
  --daemon)
    log "Starting in daemon mode"
    run_daemon
    ;;

  --health)
    run_health_check
    ;;

  --update)
    run_auto_update
    ;;

  --status)
    health_snapshot
    ;;

  --install)
    shift
    if [[ $# -eq 0 ]]; then
      err "--install requires at least one service key"
      exit 1
    fi
    for svc_key in "$@"; do
      do_install "$svc_key" || true
    done
    ;;

  --remove)
    shift
    if [[ $# -eq 0 ]]; then
      err "--remove requires at least one service key"
      exit 1
    fi
    for svc_key in "$@"; do
      spec="${S[$svc_key]:-}"
      if [[ -z "$spec" ]]; then
        err "Unknown service key: '$svc_key'"
        continue
      fi
      _rm_display=""; _rm_type=""; _rm_pkg=""; _rm_svc=""
      IFS='|' read -r _rm_display _rm_type _rm_pkg _rm_svc <<< "$spec"
      step "Removing $_rm_display"
      [[ "$_rm_svc" != "-" ]] && systemctl stop    "$_rm_svc" 2>/dev/null || true
      [[ "$_rm_svc" != "-" ]] && systemctl disable "$_rm_svc" 2>/dev/null || true
      _rm_pkg_arr=()
      case "$_rm_type" in
        pac)
          read -ra _rm_pkg_arr <<< "$_rm_pkg"
          pacman -Rns --noconfirm "${_rm_pkg_arr[@]}" 2>/dev/null || warn "Some packages could not be removed"
          ;;
        aur)
          ensure_yay
          read -ra _rm_pkg_arr <<< "$_rm_pkg"
          sudo -u "$REAL_USER" yay -Rns --noconfirm "${_rm_pkg_arr[@]}" 2>/dev/null || true
          ;;
        docker)
          _rm_cname="${svc_key//_/-}"
          docker stop "$_rm_cname" 2>/dev/null || true
          docker rm   "$_rm_cname" 2>/dev/null || true
          ;;
      esac
      info "Removed: $_rm_display"
    done
    ;;

  --backup)
    run_config_backup
    ;;

  --logs)
    tail -100 "$APPY_LOG" 2>/dev/null || echo "No logs found at $APPY_LOG"
    ;;

  --version)
    echo "appy v$APPY_VERSION"
    ;;

  --help|-h)
    echo ""
    echo -e "${BOLD}appy v${APPY_VERSION}${RESET} — Service Installer & System Manager for CachyOS / Arch Linux"
    echo ""
    echo -e "  ${BOLD}Interactive TUI:${RESET}"
    echo "    sudo bash appy.sh              Launch full menu"
    echo ""
    echo -e "  ${BOLD}Non-interactive flags:${RESET}"
    echo "    --daemon                       Run watchdog daemon (used by systemd)"
    echo "    --health                       Full color-coded system health report"
    echo "    --update                       Full system update (pacman + AUR + Docker)"
    echo "    --status                       One-line health snapshot (cpu/mem/disk/load)"
    echo "    --install <key> [key...]       Install service(s) by key"
    echo "    --remove  <key> [key...]       Remove/uninstall service(s) by key"
    echo "    --backup                       Archive all service configs to /var/backups/"
    echo "    --logs                         Show last 100 lines of appy.log"
    echo "    --version                      Print version"
    echo ""
    echo -e "  ${BOLD}Available service keys:${RESET}"
    echo "    ${KEYS[*]}"
    echo ""
    echo -e "  ${BOLD}Environment variables:${RESET}"
    echo "    APPY_DAEMON_INTERVAL=<secs>    Watchdog check interval (default: 300)"
    echo "    APPY_NOTIFY_EMAIL=<email>      Email alerts (requires 'mail' command)"
    echo ""
    echo -e "  ${BOLD}Examples:${RESET}"
    echo "    sudo bash appy.sh --install docker nginx postgres"
    echo "    sudo bash appy.sh --remove  nginx"
    echo "    sudo bash appy.sh --health"
    echo "    APPY_DAEMON_INTERVAL=120 sudo bash appy.sh --daemon"
    echo ""
    ;;

  *)
    # No argument or unrecognised → interactive menu
    main_menu
    ;;
esac
