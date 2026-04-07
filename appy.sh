#!/usr/bin/env bash
# appy — Service Installer & System Manager for CachyOS / Arch Linux
# Version: 2.0
# Usage: sudo bash appy.sh [--daemon] [--health] [--update] [--status]

set -euo pipefail

# ── Version ───────────────────────────────────────────────────────────────────
APPY_VERSION="2.0"
APPY_DIR="/var/lib/appy"
APPY_LOG="/var/log/appy.log"
APPY_DAEMON_LOG="/var/log/appy-daemon.log"
APPY_STATE="$APPY_DIR/state.json"
APPY_CONFIG="$APPY_DIR/config"
CRED_FILE="$HOME/appy-credentials.txt"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[✓]${RESET} $*" | tee -a "$APPY_LOG" 2>/dev/null || echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*" | tee -a "$APPY_LOG" 2>/dev/null || echo -e "${YELLOW}[!]${RESET} $*"; }
err()     { echo -e "${RED}[✗]${RESET} $*" | tee -a "$APPY_LOG" 2>/dev/null >&2 || echo -e "${RED}[✗]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${BLUE}▶ $*${RESET}" | tee -a "$APPY_LOG" 2>/dev/null || echo -e "\n${BOLD}${BLUE}▶ $*${RESET}"; }
die()     { err "$*"; exit 1; }
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$APPY_LOG" 2>/dev/null || true; }
daemon_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$APPY_DAEMON_LOG" 2>/dev/null || true; }

# ── Init directories ──────────────────────────────────────────────────────────
init_dirs() {
  mkdir -p "$APPY_DIR" /var/log 2>/dev/null || true
  touch "$APPY_LOG" "$APPY_DAEMON_LOG" 2>/dev/null || true
}

# ── Guards ────────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root: sudo bash appy.sh"
command -v pacman &>/dev/null || die "pacman not found — Arch/CachyOS only."
init_dirs
log "appy v$APPY_VERSION started (args: ${*:-none})"

# ── AUR helper ────────────────────────────────────────────────────────────────
REAL_USER="${SUDO_USER:-$USER}"
[[ "$REAL_USER" == "root" ]] && REAL_USER=$(who am i 2>/dev/null | awk '{print $1}' || echo "root")

ensure_yay() {
  command -v yay &>/dev/null && return 0
  step "Installing yay (AUR helper)"
  pacman -S --noconfirm --needed git base-devel
  local tmp="/tmp/yay-$$"
  sudo -u "$REAL_USER" git clone https://aur.archlinux.org/yay-bin.git "$tmp"
  cd "$tmp" && sudo -u "$REAL_USER" makepkg -si --noconfirm; cd /; rm -rf "$tmp"
  info "yay installed"
}

pac()  { pacman -S --noconfirm --needed "$@" 2>&1 | tee -a "$APPY_LOG"; }
aur()  { ensure_yay; sudo -u "$REAL_USER" yay -S --noconfirm --needed "$@" 2>&1 | tee -a "$APPY_LOG"; }
svc()  { systemctl enable --now "$1" 2>/dev/null && info "Service started: $1" || warn "Could not start: $1"; }

# ── Service definitions ───────────────────────────────────────────────────────
# FORMAT: "display name|install_type|package|service (or -)"
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
  [timeshift]="Timeshift (backups)|aur|timeshift|-"
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

# ── Special post-install steps ────────────────────────────────────────────────
post_docker()   {
  usermod -aG docker "$REAL_USER" && info "Added $REAL_USER to docker group (re-login to apply)"
  systemctl enable --now docker
}

post_postgres() {
  sudo -u postgres initdb -D /var/lib/postgres/data 2>/dev/null || true
  svc postgresql
}

post_mariadb()  {
  mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql &>/dev/null || true
  svc mariadb
  local pw; pw=$(openssl rand -base64 16)
  mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$pw';" 2>/dev/null || true
  {
    echo "=== MariaDB ==="
    echo "Generated: $(date)"
    echo "Root password: $pw"
    echo ""
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
  info "UFW configured: deny inbound, allow SSH"
}

post_zsh() {
  sudo -u "$REAL_USER" sh -c 'RUNZSH=no CHSH=no curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | bash' &>/dev/null || true
  chsh -s /bin/zsh "$REAL_USER" 2>/dev/null || true
  info "Zsh set as default shell for $REAL_USER"
}

post_samba()    { svc nmb; }

post_rust() {
  sudo -u "$REAL_USER" rustup default stable 2>/dev/null || true
}

post_prometheus() {
  # Write a basic prometheus.yml if not present
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
  # Also install node_exporter for host metrics
  pac prometheus-node-exporter 2>/dev/null || true
  svc prometheus-node-exporter 2>/dev/null || true
}

post_grafana() {
  # Pre-configure Grafana with anonymous access and default admin password
  local cfg="/etc/grafana/grafana.ini"
  if [[ -f "$cfg" ]]; then
    sed -i 's/^;admin_password = .*/admin_password = appy_grafana/' "$cfg" 2>/dev/null || true
  fi
  local pw="appy_grafana_$(openssl rand -hex 4)"
  {
    echo "=== Grafana ==="
    echo "Generated: $(date)"
    echo "URL: http://localhost:3000"
    echo "Admin user: admin"
    echo "Admin password: $pw"
    echo ""
  } >> "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  info "Grafana credentials saved to $CRED_FILE — access at http://localhost:3000"
}

post_netdata() {
  info "Netdata dashboard available at http://localhost:19999"
}

post_cockpit() {
  ufw allow 9090/tcp 2>/dev/null || true
  info "Cockpit web UI available at https://localhost:9090"
}

post_syncthing() {
  systemctl enable --now "syncthing@$REAL_USER" 2>/dev/null || true
  info "Syncthing UI available at http://localhost:8384"
}

post_mongodb() {
  local pw; pw=$(openssl rand -base64 16)
  {
    echo "=== MongoDB ==="
    echo "Generated: $(date)"
    echo "Port: 27017"
    echo "Note: Run mongosh to configure auth"
    echo ""
  } >> "$CRED_FILE"
}

post_crowdsec() {
  cscli collections install crowdsecurity/linux 2>/dev/null || true
  cscli collections install crowdsecurity/sshd  2>/dev/null || true
  info "CrowdSec installed with Linux + SSH collections"
}

post_loki() {
  if [[ ! -f /etc/loki/loki.yaml ]]; then
    mkdir -p /etc/loki
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
    mkdir -p /var/lib/loki/index /var/lib/loki/index_cache /var/lib/loki/chunks
    chown -R loki:loki /var/lib/loki 2>/dev/null || true
    info "Loki config written to /etc/loki/loki.yaml"
  fi
}

post_restic() {
  # Create a helper script for easy backups
  cat > /usr/local/bin/appy-backup <<'BKUP'
#!/usr/bin/env bash
# appy-backup: restic backup helper
# Usage: appy-backup init <repo> | backup <repo> <path> | restore <repo>

set -euo pipefail
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
    echo "Backup complete. Pruned old snapshots."
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

# ── Docker-based installers ───────────────────────────────────────────────────
install_portainer() {
  ensure_docker_running
  docker volume create portainer_data 2>/dev/null || true
  docker run -d \
    --name=portainer \
    --restart=always \
    -p 8000:8000 -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest 2>/dev/null || \
    docker start portainer 2>/dev/null || true
  info "Portainer running at https://localhost:9443"
}

install_vaultwarden() {
  ensure_docker_running
  local vw_data="/var/lib/vaultwarden"
  mkdir -p "$vw_data"
  local admin_token; admin_token=$(openssl rand -base64 48)
  docker run -d \
    --name=vaultwarden \
    --restart=always \
    -p 8222:80 \
    -v "$vw_data:/data" \
    -e ADMIN_TOKEN="$admin_token" \
    -e WEBSOCKET_ENABLED=true \
    vaultwarden/server:latest 2>/dev/null || \
    docker start vaultwarden 2>/dev/null || true
  {
    echo "=== Vaultwarden ==="
    echo "Generated: $(date)"
    echo "URL: http://localhost:8222"
    echo "Admin token: $admin_token"
    echo "Admin panel: http://localhost:8222/admin"
    echo ""
  } >> "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  info "Vaultwarden running at http://localhost:8222 — admin token saved to $CRED_FILE"
}

install_uptime_kuma() {
  ensure_docker_running
  docker volume create uptime-kuma 2>/dev/null || true
  docker run -d \
    --name=uptime-kuma \
    --restart=always \
    -p 3001:3001 \
    -v uptime-kuma:/app/data \
    louislam/uptime-kuma:latest 2>/dev/null || \
    docker start uptime-kuma 2>/dev/null || true
  info "Uptime Kuma running at http://localhost:3001"
}

ensure_docker_running() {
  if ! command -v docker &>/dev/null; then
    warn "Docker not installed. Installing first..."
    do_install docker
  fi
  systemctl start docker 2>/dev/null || true
  sleep 2
}

# ── Custom curl-based installers ──────────────────────────────────────────────
install_ollama() {
  curl -fsSL https://ollama.ai/install.sh | sh
  svc ollama
  info "Ollama API at http://localhost:11434"
}

install_pihole() {
  warn "Pi-hole needs port 53 free. Interactive installer will launch."
  curl -sSL https://install.pi-hole.net | bash
}

# ── Core install function ─────────────────────────────────────────────────────
do_install() {
  local key="$1"
  local spec="${S[$key]:-}"
  [[ -z "$spec" ]] && { err "Unknown service: $key"; return 1; }

  IFS='|' read -r display type pkg service <<< "$spec"
  step "Installing $display"
  log "Installing: $key ($display)"

  # Check if already installed
  if [[ "$type" == "pac" ]] && [[ "$pkg" != "-" ]]; then
    local first_pkg; first_pkg=$(echo "$pkg" | awk '{print $1}')
    if pacman -Qi "$first_pkg" &>/dev/null; then
      info "Already installed: $display"; return 0
    fi
  fi

  case "$type" in
    pac)    pac $pkg ;;
    aur)    aur $pkg ;;
    curl)   "install_$key" ;;
    docker) "install_$key" ;;
  esac

  [[ "$service" != "-" ]] && svc "$service"
  declare -f "post_$key" &>/dev/null && "post_$key"

  log "Installed: $key"
  info "$display installed successfully."
}

# ══════════════════════════════════════════════════════════════════════════════
# ── DAEMON / WATCHDOG MODE ────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

DAEMON_INTERVAL="${APPY_DAEMON_INTERVAL:-300}"   # seconds between health checks (default 5min)
NOTIFY_EMAIL="${APPY_NOTIFY_EMAIL:-}"

# Services to watch (auto-populated from installed services)
get_watched_services() {
  local watched=()
  for key in "${KEYS[@]}"; do
    local spec="${S[$key]:-}"
    [[ -z "$spec" ]] && continue
    IFS='|' read -r _ _ _ service <<< "$spec"
    [[ "$service" == "-" ]] && continue
    if systemctl list-unit-files "$service.service" &>/dev/null 2>&1; then
      if systemctl is-enabled "$service" &>/dev/null 2>&1; then
        watched+=("$service")
      fi
    fi
  done
  echo "${watched[@]:-}"
}

# Check a service and restart if down
watchdog_check_service() {
  local svc_name="$1"
  if ! systemctl is-active --quiet "$svc_name" 2>/dev/null; then
    daemon_log "WARN: $svc_name is DOWN — attempting restart"
    systemctl restart "$svc_name" 2>/dev/null
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

# System health snapshot
health_snapshot() {
  local cpu_idle; cpu_idle=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | tr -d '%id,' 2>/dev/null || echo "?")
  local cpu_used; cpu_used=$(awk "BEGIN{printf \"%.0f\", 100-${cpu_idle:-0}}" 2>/dev/null || echo "?")
  local mem_total; mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local mem_avail; mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  local mem_used_pct; mem_used_pct=$(awk "BEGIN{printf \"%.0f\", (1-$mem_avail/$mem_total)*100}" 2>/dev/null || echo "?")
  local disk_used; disk_used=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %' || echo "?")
  local load; load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "?")

  echo "cpu=${cpu_used}% mem=${mem_used_pct}% disk=${disk_used}% load=${load}"
}

# Send notification (email or log only)
send_notification() {
  local subject="$1"
  local body="$2"
  daemon_log "NOTIFY: $subject"
  if [[ -n "$NOTIFY_EMAIL" ]] && command -v mail &>/dev/null; then
    echo "$body" | mail -s "[appy] $subject" "$NOTIFY_EMAIL" 2>/dev/null || true
  fi
  # Write to a notifications file for in-menu display
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $subject" >> "$APPY_DIR/notifications.log" 2>/dev/null || true
}

# Install appy as a systemd daemon
install_daemon() {
  step "Installing appy daemon (watchdog + health monitor)"

  local script_dest="/usr/local/bin/appy-daemon"
  cp "$(realpath "$0")" "$script_dest"
  chmod +x "$script_dest"

  cat > /etc/systemd/system/appy-daemon.service <<EOF
[Unit]
Description=appy System Manager Daemon
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/appy-daemon --daemon
Restart=always
RestartSec=10
Environment=APPY_DAEMON_INTERVAL=${DAEMON_INTERVAL}
Environment=APPY_NOTIFY_EMAIL=${NOTIFY_EMAIL}
StandardOutput=append:$APPY_DAEMON_LOG
StandardError=append:$APPY_DAEMON_LOG

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now appy-daemon
  info "appy-daemon installed and running"
  info "Logs: $APPY_DAEMON_LOG"
  info "Status: systemctl status appy-daemon"
}

# Remove appy daemon
remove_daemon() {
  systemctl stop appy-daemon 2>/dev/null || true
  systemctl disable appy-daemon 2>/dev/null || true
  rm -f /etc/systemd/system/appy-daemon.service /usr/local/bin/appy-daemon
  systemctl daemon-reload
  info "appy-daemon removed"
}

# The actual daemon loop
run_daemon() {
  daemon_log "appy-daemon v$APPY_VERSION started (interval=${DAEMON_INTERVAL}s)"

  # Schedule vars
  local last_update_check=0
  local last_log_rotate=0
  local update_check_interval=$((6 * 3600))   # 6 hours
  local log_rotate_interval=$((24 * 3600))     # 24 hours

  while true; do
    local now; now=$(date +%s)

    # ── Watchdog: check all enabled services ───
    local watched
    IFS=' ' read -ra watched <<< "$(get_watched_services)"
    for svc_name in "${watched[@]}"; do
      watchdog_check_service "$svc_name"
    done

    # ── Health snapshot ───
    local snap; snap=$(health_snapshot)
    daemon_log "HEALTH: $snap"

    # Extract disk % for alert
    local disk_pct; disk_pct=$(echo "$snap" | grep -oP 'disk=\K[0-9]+' 2>/dev/null || echo 0)
    local mem_pct; mem_pct=$(echo "$snap"  | grep -oP 'mem=\K[0-9]+'  2>/dev/null || echo 0)

    [[ "$disk_pct" -gt 90 ]] && send_notification "⚠ Disk usage critical: ${disk_pct}%" "Root filesystem is ${disk_pct}% full."
    [[ "$mem_pct"  -gt 95 ]] && send_notification "⚠ Memory usage critical: ${mem_pct}%" "System memory is ${mem_pct}% used."

    # ── Auto update check ───
    if (( now - last_update_check > update_check_interval )); then
      daemon_log "Checking for package updates..."
      local updates; updates=$(pacman -Qu 2>/dev/null | wc -l || echo 0)
      if [[ "$updates" -gt 0 ]]; then
        daemon_log "INFO: $updates package(s) available for update"
        send_notification "📦 $updates system update(s) available" "Run 'pacman -Syu' to update."
        echo "$updates" > "$APPY_DIR/pending_updates"
      else
        rm -f "$APPY_DIR/pending_updates"
      fi
      last_update_check=$now
    fi

    # ── Log rotation ───
    if (( now - last_log_rotate > log_rotate_interval )); then
      rotate_logs
      last_log_rotate=$now
    fi

    sleep "$DAEMON_INTERVAL"
  done
}

# ── Log rotation ──────────────────────────────────────────────────────────────
rotate_logs() {
  daemon_log "Rotating logs..."
  local max_size=$((10 * 1024 * 1024))  # 10 MB
  for logfile in "$APPY_LOG" "$APPY_DAEMON_LOG" "$APPY_DIR/notifications.log"; do
    [[ ! -f "$logfile" ]] && continue
    local size; size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
    if (( size > max_size )); then
      mv "$logfile" "${logfile}.$(date +%Y%m%d).bak"
      touch "$logfile"
      # Keep only last 3 backups
      ls -t "${logfile}.*.bak" 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
      daemon_log "Rotated: $logfile"
    fi
  done
}

# ── System health check (interactive) ────────────────────────────────────────
run_health_check() {
  clear
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}          appy System Health Report                ${RESET}"
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${RESET}"
  echo -e "${DIM}  $(date)${RESET}\n"

  # CPU
  local cpu_idle; cpu_idle=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | tr -d '%id,' 2>/dev/null || echo "0")
  local cpu_pct; cpu_pct=$(awk "BEGIN{printf \"%.1f\", 100-${cpu_idle:-0}}")
  local cpu_col="$GREEN"
  (( ${cpu_pct%.*} > 80 )) && cpu_col="$RED"
  (( ${cpu_pct%.*} > 60 )) && (( ${cpu_pct%.*} <= 80 )) && cpu_col="$YELLOW"
  echo -e "  ${BOLD}CPU Usage:${RESET}      ${cpu_col}${cpu_pct}%${RESET}"

  # Memory
  local mem_total; mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local mem_avail; mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  local mem_used_pct; mem_used_pct=$(awk "BEGIN{printf \"%.1f\", (1-$mem_avail/$mem_total)*100}")
  local mem_used_mb; mem_used_mb=$(awk "BEGIN{printf \"%.0f\", ($mem_total-$mem_avail)/1024}")
  local mem_total_mb; mem_total_mb=$(awk "BEGIN{printf \"%.0f\", $mem_total/1024}")
  local mem_col="$GREEN"
  (( ${mem_used_pct%.*} > 85 )) && mem_col="$RED"
  (( ${mem_used_pct%.*} > 70 )) && (( ${mem_used_pct%.*} <= 85 )) && mem_col="$YELLOW"
  echo -e "  ${BOLD}Memory:${RESET}         ${mem_col}${mem_used_pct}%${RESET} (${mem_used_mb}MB / ${mem_total_mb}MB)"

  # Disk
  local disk_info; disk_info=$(df -h / | tail -1)
  local disk_pct; disk_pct=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')
  local disk_used; disk_used=$(echo "$disk_info" | awk '{print $3}')
  local disk_total; disk_total=$(echo "$disk_info" | awk '{print $2}')
  local disk_col="$GREEN"
  (( disk_pct > 85 )) && disk_col="$RED"
  (( disk_pct > 70 )) && (( disk_pct <= 85 )) && disk_col="$YELLOW"
  echo -e "  ${BOLD}Disk (/):${RESET}       ${disk_col}${disk_pct}%${RESET} (${disk_used} / ${disk_total})"

  # Load average
  local load1 load5 load15
  read -r load1 load5 load15 _ < /proc/loadavg
  echo -e "  ${BOLD}Load Average:${RESET}   ${load1} (1m)  ${load5} (5m)  ${load15} (15m)"

  # Uptime
  local uptime_str; uptime_str=$(uptime -p 2>/dev/null || uptime)
  echo -e "  ${BOLD}Uptime:${RESET}         $uptime_str"

  # Network
  echo -e "\n  ${BOLD}${BLUE}Network:${RESET}"
  ip -o -4 addr show 2>/dev/null | awk '{printf "  %-10s %s\n", $2, $4}' | grep -v '^  lo' || echo "  (no interfaces)"

  # Services status
  echo -e "\n  ${BOLD}${BLUE}Managed Services:${RESET}"
  local all_ok=true
  for key in "${KEYS[@]}"; do
    local spec="${S[$key]:-}"; [[ -z "$spec" ]] && continue
    IFS='|' read -r display _ _ service <<< "$spec"
    [[ "$service" == "-" ]] && continue
    if systemctl list-unit-files "${service}.service" &>/dev/null 2>&1 && \
       systemctl is-enabled "$service" &>/dev/null 2>&1; then
      if systemctl is-active --quiet "$service" 2>/dev/null; then
        printf "  ${GREEN}●${RESET} %-22s ${GREEN}running${RESET}\n" "$display"
      else
        printf "  ${RED}●${RESET} %-22s ${RED}stopped${RESET}\n" "$display"
        all_ok=false
      fi
    fi
  done

  # Docker containers
  if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    echo -e "\n  ${BOLD}${BLUE}Docker Containers:${RESET}"
    docker ps --format "  {{.Names}}\t{{.Status}}" 2>/dev/null | \
      awk '{status=$2; col="\033[0;32m"; if(status!="Up") col="\033[0;31m"; printf "  %s● \033[0m%-22s %s\n", col, $1, $2}' || \
      echo "  (none running)"
  fi

  # Pending updates
  if [[ -f "$APPY_DIR/pending_updates" ]]; then
    local upd; upd=$(cat "$APPY_DIR/pending_updates")
    echo -e "\n  ${YELLOW}[!] $upd package update(s) available — press U in main menu to update${RESET}"
  fi

  # Failed services (all, not just appy-managed)
  local failed; failed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
  if [[ "$failed" -gt 0 ]]; then
    echo -e "\n  ${RED}[!] $failed systemd service(s) failed:${RESET}"
    systemctl --failed --no-legend 2>/dev/null | awk '{print "  - "$1}'
  fi

  echo ""
  $all_ok && echo -e "  ${GREEN}${BOLD}All monitored services are healthy.${RESET}" || \
    echo -e "  ${YELLOW}${BOLD}Some services need attention.${RESET}"

  echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════════${RESET}"
  log "Health check completed"
  read -rp "  Press Enter to continue..."
}

# ── Auto-update system ────────────────────────────────────────────────────────
run_auto_update() {
  step "Running full system update"
  log "Auto-update started"

  echo -e "\n  ${BOLD}[1/4] Updating pacman packages...${RESET}"
  pacman -Syu --noconfirm 2>&1 | tee -a "$APPY_LOG"

  if command -v yay &>/dev/null; then
    echo -e "\n  ${BOLD}[2/4] Updating AUR packages...${RESET}"
    sudo -u "$REAL_USER" yay -Syu --noconfirm 2>&1 | tee -a "$APPY_LOG"
  else
    echo -e "\n  ${BOLD}[2/4] Skipping AUR (yay not installed)${RESET}"
  fi

  echo -e "\n  ${BOLD}[3/4] Updating Docker images...${RESET}"
  if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    docker ps --format "{{.Image}}" 2>/dev/null | sort -u | while read -r img; do
      echo "  Pulling: $img"
      docker pull "$img" 2>/dev/null | grep -E "Status:|Digest:|error" || true
    done
    info "Docker images updated"
  else
    echo "  Docker not running, skipping."
  fi

  echo -e "\n  ${BOLD}[4/4] Cleaning package cache...${RESET}"
  pacman -Sc --noconfirm 2>&1 | tail -3
  rm -f "$APPY_DIR/pending_updates"

  log "Auto-update completed"
  info "System fully updated!"
  read -rp "  Press Enter to continue..."
}

# ── Config backup ─────────────────────────────────────────────────────────────
run_config_backup() {
  local backup_dir="/var/backups/appy-configs"
  local timestamp; timestamp=$(date +%Y%m%d_%H%M%S)
  local archive="$backup_dir/configs_$timestamp.tar.gz"

  step "Backing up service configurations"
  mkdir -p "$backup_dir"

  # List of config paths to back up
  local configs=(
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
    /etc/postgresql
    /etc/systemd/system/appy-daemon.service
    "$CRED_FILE"
    "$APPY_DIR"
  )

  local existing=()
  for cfg in "${configs[@]}"; do
    [[ -e "$cfg" ]] && existing+=("$cfg")
  done

  if [[ ${#existing[@]} -eq 0 ]]; then
    warn "No configuration files found to back up."
    read -rp "  Press Enter to continue..."
    return
  fi

  tar -czf "$archive" "${existing[@]}" 2>/dev/null && \
    info "Config backup saved to: $archive" || \
    warn "Backup completed with some errors (non-critical)."

  # Keep only last 5 backups
  ls -t "$backup_dir"/configs_*.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

  local size; size=$(du -sh "$archive" 2>/dev/null | awk '{print $1}')
  info "Backup size: $size"
  log "Config backup created: $archive"
  read -rp "  Press Enter to continue..."
}

# ── Rollback: remove a service ────────────────────────────────────────────────
run_rollback_menu() {
  clear
  echo -e "${BOLD}${RED}Remove / Rollback a Service${RESET}\n"

  local i=1
  local -A idx_to_key=()
  for key in "${KEYS[@]}"; do
    local spec="${S[$key]:-}"; [[ -z "$spec" ]] && continue
    IFS='|' read -r display type pkg service <<< "$spec"
    local installed=false
    if [[ "$type" == "pac" ]] && [[ "$pkg" != "-" ]]; then
      local fp; fp=$(echo "$pkg" | awk '{print $1}')
      pacman -Qi "$fp" &>/dev/null && installed=true
    elif [[ "$type" == "docker" ]]; then
      docker inspect "${key//_/-}" &>/dev/null 2>&1 && installed=true
    fi
    if $installed; then
      printf "  ${BLUE}%2d)${RESET} %s\n" "$i" "$display"
      idx_to_key[$i]="$key"
      ((i++))
    fi
  done

  [[ $i -eq 1 ]] && { echo "  No installed services found."; read -rp "  Press Enter..."; return; }

  echo ""
  read -rp "  Enter number to remove (or Q to cancel): " choice
  [[ "${choice,,}" == "q" ]] && return

  local key="${idx_to_key[$choice]:-}"
  [[ -z "$key" ]] && { warn "Invalid choice."; read -rp "  Press Enter..."; return; }

  local spec="${S[$key]}"
  IFS='|' read -r display type pkg service <<< "$spec"

  echo ""
  read -rp "  Remove $display? This will stop and uninstall it. [y/N]: " confirm
  [[ "${confirm,,}" != "y" ]] && return

  step "Removing $display"
  [[ "$service" != "-" ]] && systemctl stop "$service" 2>/dev/null || true
  [[ "$service" != "-" ]] && systemctl disable "$service" 2>/dev/null || true

  case "$type" in
    pac)  pacman -Rns --noconfirm $pkg 2>/dev/null || warn "Some packages could not be removed" ;;
    aur)  sudo -u "$REAL_USER" yay -Rns --noconfirm $pkg 2>/dev/null || warn "Some packages could not be removed" ;;
    docker)
      docker stop "${key//_/-}" 2>/dev/null || true
      docker rm   "${key//_/-}" 2>/dev/null || true
      ;;
  esac

  log "Removed: $key ($display)"
  info "$display removed."
  read -rp "  Press Enter to continue..."
}

# ── Notifications log viewer ──────────────────────────────────────────────────
view_notifications() {
  clear
  echo -e "${BOLD}${CYAN}Recent Notifications${RESET}\n"
  if [[ -f "$APPY_DIR/notifications.log" ]] && [[ -s "$APPY_DIR/notifications.log" ]]; then
    tail -30 "$APPY_DIR/notifications.log"
  else
    echo "  No notifications yet."
  fi
  echo ""
  read -rp "  Press Enter to continue..."
}

# ── Scheduler: set up cron/timer for auto updates ─────────────────────────────
setup_scheduler() {
  clear
  echo -e "${BOLD}${CYAN}Auto-Update Scheduler${RESET}\n"
  echo "  Configure automatic system updates via systemd timer.\n"
  echo "  1) Daily at 3:00 AM"
  echo "  2) Weekly (Sunday 3:00 AM)"
  echo "  3) Manual only (disable)"
  echo "  4) Back"
  echo ""
  read -rp "  Choice: " sched_choice

  local on_calendar=""
  case "$sched_choice" in
    1) on_calendar="*-*-* 03:00:00" ;;
    2) on_calendar="Sun *-*-* 03:00:00" ;;
    3)
      systemctl stop  appy-update.timer  2>/dev/null || true
      systemctl disable appy-update.timer 2>/dev/null || true
      rm -f /etc/systemd/system/appy-update.{service,timer}
      systemctl daemon-reload
      info "Auto-update scheduler disabled."
      read -rp "  Press Enter..."; return ;;
    *) return ;;
  esac

  # Create update service
  cat > /etc/systemd/system/appy-update.service <<EOF
[Unit]
Description=appy Automatic System Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/appy-daemon --update
StandardOutput=append:$APPY_LOG
StandardError=append:$APPY_LOG
EOF

  # Create timer
  cat > /etc/systemd/system/appy-update.timer <<EOF
[Unit]
Description=appy Auto-Update Timer

[Timer]
OnCalendar=$on_calendar
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Install the script if not already there
  [[ ! -f /usr/local/bin/appy-daemon ]] && cp "$(realpath "$0")" /usr/local/bin/appy-daemon && chmod +x /usr/local/bin/appy-daemon

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

    # Show daemon status
    if systemctl is-active --quiet appy-daemon 2>/dev/null; then
      echo -e "  ${GREEN}●${RESET} appy-daemon is ${GREEN}running${RESET} (watchdog active)"
    else
      echo -e "  ${RED}●${RESET} appy-daemon is ${RED}not running${RESET}"
    fi

    # Show pending updates
    if [[ -f "$APPY_DIR/pending_updates" ]]; then
      local upd; upd=$(cat "$APPY_DIR/pending_updates")
      echo -e "  ${YELLOW}[!] $upd update(s) pending${RESET}"
    fi
    echo ""

    echo "  ── System ──────────────────────────────────────"
    echo "  1) Full System Health Check"
    echo "  2) Update all packages (pacman + AUR + Docker)"
    echo "  3) Clean package & Docker cache"
    echo "  4) Show failed services"
    echo "  5) Disk usage breakdown"
    echo "  6) Running services list"
    echo ""
    echo "  ── appy Daemon ─────────────────────────────────"
    echo "  7) Install / restart appy watchdog daemon"
    echo "  8) Remove appy watchdog daemon"
    echo "  9) View daemon logs (last 50 lines)"
    echo " 10) View notifications"
    echo " 11) Setup auto-update schedule"
    echo ""
    echo "  ── Backup & Recovery ────────────────────────────"
    echo " 12) Back up all service configs"
    echo " 13) Remove / rollback a service"
    echo ""
    echo -e "  ${YELLOW}B)${RESET} Back to main menu"
    echo ""
    read -rp "  Choice: " m

    case "$m" in
      1)  run_health_check ;;
      2)  run_auto_update ;;
      3)
        pacman -Sc --noconfirm
        if command -v docker &>/dev/null; then
          docker system prune -f 2>/dev/null || true
          info "Docker cache pruned"
        fi
        info "Cache cleaned"
        read -rp "  Press Enter..."
        ;;
      4)  systemctl --failed; read -rp "  Press Enter..." ;;
      5)
        df -h
        echo ""
        du -sh /var/cache/pacman/pkg 2>/dev/null || true
        command -v docker &>/dev/null && docker system df 2>/dev/null || true
        read -rp "  Press Enter..."
        ;;
      6)  systemctl list-units --type=service --state=running; read -rp "  Press Enter..." ;;
      7)  install_daemon; read -rp "  Press Enter..." ;;
      8)  remove_daemon;  read -rp "  Press Enter..." ;;
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
      *)   warn "Invalid choice" ;;
    esac
  done
}

# ── Main interactive menu ─────────────────────────────────────────────────────
main_menu() {
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
      local upd; upd=$(cat "$APPY_DIR/pending_updates")
      echo -e "  ${YELLOW}[!] ${upd} update(s) pending — press U to update${RESET}"
    fi
    echo ""

    # Service groups
    local groups=(
      "Containers & Web|docker compose nginx caddy portainer"
      "Databases|mariadb postgres redis sqlite mongodb"
      "Security & Net|fail2ban ufw wireguard tailscale vaultwarden crowdsec"
      "Media & Files|jellyfin samba syncthing"
      "Monitoring|btop htop netdata prometheus grafana uptime_kuma cockpit loki"
      "Development|git neovim zsh node python golang rust docker_buildx"
      "AI & Other|ollama pihole timeshift restic"
    )

    local i=1
    local -A idx_to_key=()

    for group_entry in "${groups[@]}"; do
      local group_name; group_name=$(echo "$group_entry" | cut -d'|' -f1)
      local group_keys; group_keys=$(echo "$group_entry" | cut -d'|' -f2)

      echo -e "  ${DIM}── $group_name ──────────────────────────────────────${RESET}"

      local col=0
      for key in $group_keys; do
        local spec="${S[$key]:-}"; [[ -z "$spec" ]] && continue
        IFS='|' read -r display _ _ service <<< "$spec"

        # Check if installed
        local mark=" "
        IFS='|' read -r _ type pkg _ <<< "$spec"
        if [[ "$type" == "pac" ]] && [[ "$pkg" != "-" ]]; then
          local fp; fp=$(echo "$pkg" | awk '{print $1}')
          pacman -Qi "$fp" &>/dev/null 2>&1 && mark="${GREEN}✓${RESET}"
        elif [[ "$type" == "docker" ]]; then
          docker inspect "${key//_/-}" &>/dev/null 2>&1 && mark="${GREEN}✓${RESET}"
        fi

        printf "  ${BLUE}%2d)${RESET} ${mark} %-26s" "$i" "$display"
        idx_to_key[$i]="$key"
        (( col++ ))
        if (( col % 2 == 0 )); then echo ""; fi
      done
      [[ $((col % 2)) -ne 0 ]] && echo ""
      echo ""
    done

    echo -e "  ${YELLOW}A)${RESET} Install ALL services"
    echo -e "  ${YELLOW}U)${RESET} Update system (packages + Docker)"
    echo -e "  ${YELLOW}H)${RESET} Health check"
    echo -e "  ${YELLOW}M)${RESET} Maintenance & Daemon"
    echo -e "  ${YELLOW}Q)${RESET} Quit"
    echo ""
    echo -e "${BOLD}  Enter numbers (e.g. 1 3 7) or a letter:${RESET}"
    read -rp "  → " input
    echo ""

    case "${input,,}" in
      q) info "Goodbye!"; exit 0 ;;
      m) maintenance_menu; continue ;;
      h) run_health_check; continue ;;
      u) run_auto_update; continue ;;
      a)
        for key in "${KEYS[@]}"; do do_install "$key"; done
        echo -e "\n${GREEN}${BOLD}All services installed!${RESET}"
        read -rp "Press Enter to continue..."
        continue
        ;;
    esac

    local installed_any=false
    for token in $input; do
      if [[ "$token" =~ ^[0-9]+$ ]] && [[ -n "${idx_to_key[$token]+_}" ]]; then
        do_install "${idx_to_key[$token]}" && installed_any=true
      else
        warn "Invalid selection: $token"
      fi
    done

    "$installed_any" && echo -e "\n${GREEN}${BOLD}Done!${RESET}" || true
    read -rp "Press Enter to continue..."
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# ── CLI flags (for daemon/systemd use) ───────────────────────────────────────
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
    for svc_key in "$@"; do
      do_install "$svc_key"
    done
    ;;
  --remove)
    shift
    for svc_key in "$@"; do
      spec="${S[$svc_key]:-}"
      [[ -z "$spec" ]] && { err "Unknown: $svc_key"; continue; }
      IFS='|' read -r display type pkg service <<< "$spec"
      step "Removing $display"
      [[ "$service" != "-" ]] && systemctl stop    "$service" 2>/dev/null || true
      [[ "$service" != "-" ]] && systemctl disable "$service" 2>/dev/null || true
      [[ "$type" == "pac" ]] && pacman -Rns --noconfirm $pkg 2>/dev/null || true
      info "Removed: $display"
    done
    ;;
  --backup)
    run_config_backup
    ;;
  --logs)
    tail -100 "$APPY_LOG" 2>/dev/null || echo "No logs found."
    ;;
  --version)
    echo "appy v$APPY_VERSION"
    ;;
  --help|-h)
    echo ""
    echo -e "${BOLD}appy v$APPY_VERSION${RESET} — Service Installer & System Manager"
    echo ""
    echo "  ${BOLD}Interactive:${RESET}"
    echo "    sudo bash appy.sh              Launch full TUI menu"
    echo ""
    echo "  ${BOLD}Non-interactive flags:${RESET}"
    echo "    --daemon                       Run watchdog daemon (used by systemd)"
    echo "    --health                       Print system health report"
    echo "    --update                       Run full system update"
    echo "    --status                       One-line health snapshot"
    echo "    --install <key> [key...]       Install service(s) by key"
    echo "    --remove  <key> [key...]       Remove service(s) by key"
    echo "    --backup                       Back up all service configs"
    echo "    --logs                         Show last 100 log lines"
    echo "    --version                      Print version"
    echo ""
    echo "  ${BOLD}Service keys:${RESET}"
    echo "    ${KEYS[*]}"
    echo ""
    echo "  ${BOLD}Environment:${RESET}"
    echo "    APPY_DAEMON_INTERVAL=<secs>   Watchdog check interval (default: 300)"
    echo "    APPY_NOTIFY_EMAIL=<email>     Email alerts (requires mail command)"
    echo ""
    ;;
  *)
    main_menu
    ;;
esac
