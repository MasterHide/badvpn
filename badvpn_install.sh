#!/usr/bin/env bash
set -euo pipefail

# ========= Config (edit if you want) =========
REPO_URL="https://github.com/ambrop72/badvpn.git"
SRC_DIR="/root/badvpn"
BUILD_DIR="${SRC_DIR}/badvpn-build"

BIN_DST="/usr/local/bin/badvpn-udpgw"

SERVICE_NAME="badvpn.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

# UDPGW defaults (can be overridden by env vars)
LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1:7300}"
MAX_CLIENTS="${MAX_CLIENTS:-4096}"
MAX_CONN_PER_CLIENT="${MAX_CONN_PER_CLIENT:-4096}"

# ========= Helpers =========
log() { echo -e "[badvpn] $*"; }
die() { echo -e "[badvpn] ERROR: $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root (use: sudo bash badvpn_install.sh)"
  fi
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  else
    die "This script currently supports Debian/Ubuntu (apt)."
  fi
}

install_deps() {
  local mgr
  mgr="$(detect_pkg_mgr)"
  export DEBIAN_FRONTEND=noninteractive
  log "Installing dependencies..."
  apt-get update -y
  # build-essential includes gcc/g++/make on Debian/Ubuntu
  apt-get install -y --no-install-recommends \
    ca-certificates git cmake build-essential pkg-config
}

clone_or_update_repo() {
  log "Preparing source in: ${SRC_DIR}"
  if [[ -d "${SRC_DIR}/.git" ]]; then
    log "Repo exists, updating..."
    git -C "${SRC_DIR}" fetch --all --prune
    git -C "${SRC_DIR}" reset --hard origin/master || git -C "${SRC_DIR}" reset --hard origin/main
  else
    # If folder exists but not a git repo, refuse to overwrite
    if [[ -d "${SRC_DIR}" && ! -z "$(ls -A "${SRC_DIR}" 2>/dev/null)" ]]; then
      die "${SRC_DIR} exists but is not a git repo. Move it aside or delete it, then rerun."
    fi
    rm -rf "${SRC_DIR}"
    git clone "${REPO_URL}" "${SRC_DIR}"
  fi

  [[ -f "${SRC_DIR}/CMakeLists.txt" ]] || die "CMakeLists.txt not found in ${SRC_DIR}. Clone may have failed."
}

build_udpgw() {
  log "Building UDPGW..."
  mkdir -p "${BUILD_DIR}"
  cd "${BUILD_DIR}"

  # Configure (UDPGW only)
  cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1

  # Build
  make -j"$(nproc || echo 1)"

  # Validate output binary exists
  local built_bin="${BUILD_DIR}/udpgw/badvpn-udpgw"
  [[ -x "${built_bin}" ]] || die "Built binary not found at: ${built_bin}"
  log "Built binary: ${built_bin}"

  # Install binary into /usr/local/bin
  install -m 0755 "${built_bin}" "${BIN_DST}"
  log "Installed: ${BIN_DST}"

  # Record installed file for clean uninstall
  mkdir -p /var/lib/badvpn
  echo "${BIN_DST}" > /var/lib/badvpn/install_manifest.txt
}

write_systemd_service() {
  log "Writing systemd unit: ${SERVICE_PATH}"
  cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=BadVPN UDPGW service
After=network.target

[Service]
Type=simple
ExecStart=${BIN_DST} --listen-addr ${LISTEN_ADDR} --max-clients ${MAX_CLIENTS} --max-connections-for-client ${MAX_CONN_PER_CLIENT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  # Record unit path for uninstall
  echo "${SERVICE_PATH}" >> /var/lib/badvpn/install_manifest.txt
}

enable_service() {
  log "Enabling and starting service..."
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"

  log "Service status (brief):"
  systemctl --no-pager --full status "${SERVICE_NAME}" || true
}

main() {
  need_root
  install_deps
  clone_or_update_repo
  build_udpgw
  write_systemd_service
  enable_service

  log "Done."
  log "UDPGW listening on: ${LISTEN_ADDR}"
  log "Binary: ${BIN_DST}"
  log "To change listen port/address later:"
  log "  Edit ${SERVICE_PATH} then: systemctl daemon-reload && systemctl restart ${SERVICE_NAME}"
}

main "$@"
