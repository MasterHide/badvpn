#!/usr/bin/env bash
set -euo pipefail

# ========= Config =========
REPO_URL="https://github.com/MasterHide/badvpn.git"
SRC_DIR="/root/badvpn"
BUILD_DIR="${SRC_DIR}/badvpn-build"

BIN_DIR="/usr/local/bin"
BIN_UDPGW="${BIN_DIR}/badvpn-udpgw"
BIN_TUN2SOCKS="${BIN_DIR}/badvpn-tun2socks"

SERVICE_NAME="badvpn.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

# Config file for future changes (nano-friendly)
ENV_FILE="/etc/default/badvpn-udpgw"

# Defaults (written to ENV_FILE on first install)
DEFAULT_LISTEN_ADDR="127.0.0.1:7300"
DEFAULT_MAX_CLIENTS="4096"
DEFAULT_MAX_CONN_PER_CLIENT="4096"

# ========= Helpers =========
log() { echo -e "\n[badvpn] $*"; }
die() { echo -e "\n[badvpn] ERROR: $*" >&2; exit 1; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo)."; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_systemd() {
  have_cmd systemctl || die "systemctl not found. This script requires systemd."
}

ensure_tools() {
  if ! have_cmd ss; then
    apt-get update -y
    apt-get install -y --no-install-recommends iproute2
  fi
  if ! have_cmd nano; then
    apt-get update -y
    apt-get install -y --no-install-recommends nano
  fi
}

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates git cmake build-essential pkg-config iproute2 nano curl socat
}

clone_or_update() {
  log "Preparing source: ${SRC_DIR}"
  if [[ -d "${SRC_DIR}/.git" ]]; then
    git -C "${SRC_DIR}" fetch --all --prune
    # Prefer origin/master, fallback to origin/main
    if git -C "${SRC_DIR}" show-ref --verify --quiet refs/remotes/origin/master; then
      git -C "${SRC_DIR}" reset --hard origin/master
    else
      git -C "${SRC_DIR}" reset --hard origin/main
    fi
  else
    rm -rf "${SRC_DIR}"
    git clone "${REPO_URL}" "${SRC_DIR}"
  fi
  [[ -f "${SRC_DIR}/CMakeLists.txt" ]] || die "CMakeLists.txt missing in ${SRC_DIR}"
}

build_all() {
  log "Building (tun2socks + udpgw)"
  mkdir -p "${BUILD_DIR}"
  cd "${BUILD_DIR}"

  cmake .. \
    -DBUILD_NOTHING_BY_DEFAULT=1 \
    -DBUILD_UDPGW=1 \
    -DBUILD_TUN2SOCKS=1

  make -j"$(nproc || echo 1)"

  [[ -x "${BUILD_DIR}/udpgw/badvpn-udpgw" ]] || die "UDPGW build failed"
  [[ -x "${BUILD_DIR}/tun2socks/badvpn-tun2socks" ]] || die "tun2socks build failed"

  install -m 0755 "${BUILD_DIR}/udpgw/badvpn-udpgw" "${BIN_UDPGW}"
  install -m 0755 "${BUILD_DIR}/tun2socks/badvpn-tun2socks" "${BIN_TUN2SOCKS}"

  mkdir -p /var/lib/badvpn
  {
    echo "${BIN_UDPGW}"
    echo "${BIN_TUN2SOCKS}"
    echo "${SERVICE_PATH}"
    echo "${ENV_FILE}"
  } > /var/lib/badvpn/install_manifest.txt
}

write_env_file_if_missing() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    log "Creating config: ${ENV_FILE}"
    cat > "${ENV_FILE}" <<EOF
# BadVPN UDPGW config (used by systemd)
# Edit with: nano ${ENV_FILE}

LISTEN_ADDR="${DEFAULT_LISTEN_ADDR}"
MAX_CLIENTS="${DEFAULT_MAX_CLIENTS}"
MAX_CONN_PER_CLIENT="${DEFAULT_MAX_CONN_PER_CLIENT}"
EOF
  fi
}

write_service() {
  require_systemd
  log "Creating systemd service: ${SERVICE_PATH}"
  cat > "${SERVICE_PATH}" <<'EOF'
[Unit]
Description=BadVPN UDPGW service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/badvpn-udpgw
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr ${LISTEN_ADDR} --max-clients ${MAX_CLIENTS} --max-connections-for-client ${MAX_CONN_PER_CLIENT}
Restart=always
RestartSec=2
KillSignal=SIGINT
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

enable_service() {
  require_systemd
  log "Enabling & starting ${SERVICE_NAME}"
  systemctl enable --now "${SERVICE_NAME}"
}

# ========= Ops / Menu actions =========
show_status() {
  require_systemd
  echo
  systemctl status "${SERVICE_NAME}" --no-pager -l || true
}

show_ports() {
  echo
  echo "Listening UDP sockets for badvpn / LISTEN_ADDR from config:"
  if [[ -f "${ENV_FILE}" ]]; then
    # safe source under set -u
    set +u
    # shellcheck disable=SC1090
    source "${ENV_FILE}" || true
    set -u

    echo "Configured LISTEN_ADDR=${LISTEN_ADDR:-not_set}"

    if [[ -n "${LISTEN_ADDR:-}" ]]; then
      local port="${LISTEN_ADDR##*:}"
      ss -u -lpn | grep -E ":${port}\b|badvpn" || true
    else
      ss -u -lpn | grep -i badvpn || true
    fi
  else
    echo "Config file missing: ${ENV_FILE}"
    ss -u -lpn | grep -i badvpn || true
  fi
}

show_logs() {
  require_systemd
  echo
  journalctl -u "${SERVICE_NAME}" --no-pager -n 120 || true
}

follow_logs() {
  require_systemd
  echo
  journalctl -u "${SERVICE_NAME}" -f
}

start_service() { require_systemd; systemctl start "${SERVICE_NAME}"; }
stop_service() { require_systemd; systemctl stop "${SERVICE_NAME}"; }
restart_service() { require_systemd; systemctl restart "${SERVICE_NAME}"; }
enable_on_boot() { require_systemd; systemctl enable "${SERVICE_NAME}"; }
disable_on_boot() { require_systemd; systemctl disable "${SERVICE_NAME}"; }

edit_config() {
  ensure_tools
  [[ -f "${ENV_FILE}" ]] || write_env_file_if_missing
  nano "${ENV_FILE}"
  require_systemd
  systemctl daemon-reload
  systemctl restart "${SERVICE_NAME}" || true
  show_ports
}

set_listen_addr() {
  ensure_tools
  [[ -f "${ENV_FILE}" ]] || write_env_file_if_missing
  read -r -p "Enter new LISTEN_ADDR (example: 127.0.0.1:7300): " newaddr
  [[ -n "${newaddr}" ]] || die "LISTEN_ADDR cannot be empty"
  sed -i -E "s|^LISTEN_ADDR=.*|LISTEN_ADDR=\"${newaddr}\"|g" "${ENV_FILE}"
  require_systemd
  systemctl daemon-reload
  systemctl restart "${SERVICE_NAME}" || true
  show_ports
}

install_flow() {
  need_root
  install_deps
  clone_or_update
  build_all
  write_env_file_if_missing
  write_service
  enable_service

  log "Installed:"
  echo "  UDPGW:     ${BIN_UDPGW}"
  echo "  tun2socks: ${BIN_TUN2SOCKS}"
  echo "  Service:   ${SERVICE_NAME}"
  echo "  Config:    ${ENV_FILE}"
  show_ports
}

# ========= Simple logger =========
LOGI() { echo -e "[INFO] $*"; }
LOGE() { echo -e "[ERROR] $*" >&2; }
LOGD() { echo -e "[DEBUG] $*"; }

detect_release() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      debian) echo "debian" ;;
      ubuntu) echo "ubuntu" ;;
      *) echo "${ID:-unknown}" ;;
    esac
  else
    echo "unknown"
  fi
}

install_acme() {
  LOGI "Installing acme.sh..."
  apt-get update -y
  apt-get install -y --no-install-recommends curl ca-certificates
  curl -fsSL https://get.acme.sh | sh
}

install_badvpn_menu_command() {
  local target_script="/usr/local/sbin/badvpn-manager"
  LOGI "Installing global command: badvpn"

  install -m 0755 "$0" "${target_script}"

  # Wrapper: use sudo only if not root (and if sudo exists)
  cat >/usr/local/bin/badvpn <<'EOF'
#!/usr/bin/env bash
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo /usr/local/sbin/badvpn-manager
  else
    echo "sudo not found. Run as root: su -c /usr/local/sbin/badvpn-manager" >&2
    exit 1
  fi
else
  exec /usr/local/sbin/badvpn-manager
fi
EOF
  chmod +x /usr/local/bin/badvpn

  LOGI "Global menu command installed. Run: badvpn"
}

ssl_cert_issue() {
  local release
  release="$(detect_release)"

  if [[ ! -x /usr/local/x-ui/x-ui ]]; then
    LOGE "x-ui binary not found at /usr/local/x-ui/x-ui"
    LOGE "This SSL option is for x-ui. Install x-ui first, then retry."
    return 1
  fi

  local existing_webBasePath existing_port
  existing_webBasePath=$(/usr/local/x-ui/x-ui setting -show true | awk '/webBasePath:/ {print $2; exit}')
  existing_port=$(/usr/local/x-ui/x-ui setting -show true | awk '/port:/ {print $2; exit}')

  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    LOGI "acme.sh not found. Installing..."
    install_acme || { LOGE "install acme.sh failed"; return 1; }
  fi

  case "${release}" in
    ubuntu|debian)
      apt-get update -y
      apt-get install -y --no-install-recommends socat iproute2
      ;;
    *)
      LOGE "Unsupported OS for this SSL helper (${release}). Debian/Ubuntu only."
      return 1
      ;;
  esac

  # Pre-check: port 80 must be free for standalone
  if ss -tulpn | grep -q ':80 '; then
    LOGE "Port 80 is currently in use. Standalone ACME needs port 80."
    ss -tulpn | grep ':80 ' || true
    LOGE "Stop the service using port 80 (nginx/apache/caddy) then retry."
    return 1
  fi

  local domain=""
  read -r -p "Please enter your domain name (A/AAAA must point to this VPS): " domain
  [[ -n "${domain}" ]] || { LOGE "Domain cannot be empty"; return 1; }
  LOGI "Domain: ${domain}"

  # Only block if exact domain exists in list (more accurate than tail -1)
  if /root/.acme.sh/acme.sh --list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${domain}"; then
    LOGE "A certificate already exists for ${domain} in acme.sh."
    /root/.acme.sh/acme.sh --list || true
    return 1
  fi

  local certPath="/root/cert/${domain}"
  rm -rf "${certPath}"
  mkdir -p "${certPath}"

  LOGI "Issuing certificate using Let's Encrypt (standalone mode)..."
  LOGI "NOTE: Port 80 must be reachable from the internet."

  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

  /root/.acme.sh/acme.sh --issue --force --standalone -d "${domain}" \
    --fullchain-file "${certPath}/fullchain.pem" \
    --key-file "${certPath}/privkey.pem" || {
      LOGE "Issuing certificate failed. Common causes:"
      LOGE " - DNS not pointing to this VPS"
      LOGE " - Port 80 blocked by firewall/provider"
      LOGE " - Another service is using port 80"
      rm -rf "/root/.acme.sh/${domain}" || true
      return 1
    }

  LOGI "Installing certificate (acme.sh installcert)..."
  /root/.acme.sh/acme.sh --installcert -d "${domain}" \
    --key-file "${certPath}/privkey.pem" \
    --fullchain-file "${certPath}/fullchain.pem" || {
      LOGE "Installing certificate failed."
      rm -rf "/root/.acme.sh/${domain}" || true
      return 1
    }

  /root/.acme.sh/acme.sh --upgrade --auto-upgrade || true

  chmod 755 "${certPath}"/* || true
  ls -lah "${certPath}" || true

  local webCertFile="${certPath}/fullchain.pem"
  local webKeyFile="${certPath}/privkey.pem"

  if [[ -f "${webCertFile}" && -f "${webKeyFile}" ]]; then
    /usr/local/x-ui/x-ui cert -webCert "${webCertFile}" -webCertKey "${webKeyFile}"
    LOGI "x-ui cert paths updated for domain: ${domain}"
    LOGI "  - Cert: ${webCertFile}"
    LOGI "  - Key:  ${webKeyFile}"

    systemctl restart x-ui || true
    LOGI "x-ui restarted."

    existing_webBasePath="${existing_webBasePath:-/}"
    existing_port="${existing_port:-443}"
    echo
    echo "Access URL: https://${domain}:${existing_port}${existing_webBasePath}"
  else
    LOGE "Certificate files not found after issuance."
    return 1
  fi
}

menu() {
  need_root
  ensure_tools

  while true; do
    echo
    echo "=========== BadVPN Manager ==========="
    echo "1) Install / Update (build udpgw + tun2socks + setup service)"
    echo "2) Service status"
    echo "3) Show logs (last 120 lines)"
    echo "4) Follow logs (live)"
    echo "5) Show listening port(s)"
    echo "6) Start service"
    echo "7) Stop service"
    echo "8) Restart service"
    echo "9) Edit config in nano (then restart)"
    echo "10) Set LISTEN_ADDR quickly"
    echo "11) SSL install (x-ui cert via acme.sh)"
    echo "12) Install global menu command: badvpn"
    echo "0) Exit"
    echo "======================================"
    read -r -p "Choose: " choice

    case "${choice}" in
      1) install_flow ;;
      2) show_status ;;
      3) show_logs ;;
      4) follow_logs ;;
      5) show_ports ;;
      6) start_service; show_ports ;;
      7) stop_service; show_status ;;
      8) restart_service; show_ports ;;
      9) edit_config ;;
      10) set_listen_addr ;;
      11) ssl_cert_issue ;;
      12) install_badvpn_menu_command ;;
      0) exit 0 ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

# ========= Entry =========
case "${1:-}" in
  install) install_flow ;;
  status) show_status ;;
  logs) show_logs ;;
  logs-f) follow_logs ;;
  ports) show_ports ;;
  start) start_service; show_ports ;;
  stop) stop_service; show_status ;;
  restart) restart_service; show_ports ;;
  edit) edit_config ;;
  set-addr) set_listen_addr ;;
  ssl) ssl_cert_issue ;;
  global) install_badvpn_menu_command ;;
  "" ) menu ;;
  * ) echo "Usage: $0 [install|status|logs|logs-f|ports|start|stop|restart|edit|set-addr|ssl|global]"; exit 1 ;;
esac
