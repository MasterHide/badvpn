#!/usr/bin/env bash
set -euo pipefail

#!/usr/bin/env bash
set -euo pipefail

# ========= Config =========
REPO_URL="https://github.com/ambrop72/badvpn.git"
SRC_DIR="/root/badvpn"
BUILD_DIR="${SRC_DIR}/badvpn-build"

BIN_DIR="/usr/local/bin"
BIN_UDPGW="${BIN_DIR}/badvpn-udpgw"
BIN_TUN2SOCKS="${BIN_DIR}/badvpn-tun2socks"

SERVICE_NAME="badvpn.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"

# UDPGW defaults
LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1:7300}"
MAX_CLIENTS="${MAX_CLIENTS:-4096}"
MAX_CONN_PER_CLIENT="${MAX_CONN_PER_CLIENT:-4096}"

# ========= Helpers =========
log() { echo -e "[badvpn] $*"; }
die() { echo -e "[badvpn] ERROR: $*" >&2; exit 1; }

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo)."
}

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates git cmake build-essential pkg-config
}

clone_or_update() {
  log "Preparing source: ${SRC_DIR}"
  if [[ -d "${SRC_DIR}/.git" ]]; then
    git -C "${SRC_DIR}" fetch --all --prune
    git -C "${SRC_DIR}" reset --hard origin/master || \
    git -C "${SRC_DIR}" reset --hard origin/main
  else
    rm -rf "${SRC_DIR}"
    git clone "${REPO_URL}" "${SRC_DIR}"
  fi
  [[ -f "${SRC_DIR}/CMakeLists.txt" ]] || die "CMakeLists.txt missing."
}

build_all() {
  mkdir -p "${BUILD_DIR}"
  cd "${BUILD_DIR}"

  log "Configuring (tun2socks + udpgw)"
  cmake .. \
    -DBUILD_NOTHING_BY_DEFAULT=1 \
    -DBUILD_UDPGW=1 \
    -DBUILD_TUN2SOCKS=1

  log "Building..."
  make -j"$(nproc || echo 1)"

  [[ -x "${BUILD_DIR}/udpgw/badvpn-udpgw" ]] || die "UDPGW build failed"
  [[ -x "${BUILD_DIR}/tun2socks/badvpn-tun2socks" ]] || die "tun2socks build failed"

  install -m 0755 "${BUILD_DIR}/udpgw/badvpn-udpgw" "${BIN_UDPGW}"
  install -m 0755 "${BUILD_DIR}/tun2socks/badvpn-tun2socks" "${BIN_TUN2SOCKS}"

  mkdir -p /var/lib/badvpn
  {
    echo "${BIN_UDPGW}"
    echo "${BIN_TUN2SOCKS}"
  } > /var/lib/badvpn/install_manifest.txt
}

write_service() {
  log "Creating systemd service for UDPGW"
  cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=BadVPN UDPGW service
After=network.target

[Service]
Type=simple
ExecStart=${BIN_UDPGW} --listen-addr ${LISTEN_ADDR} --max-clients ${MAX_CLIENTS} --max-connections-for-client ${MAX_CONN_PER_CLIENT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  echo "${SERVICE_PATH}" >> /var/lib/badvpn/install_manifest.txt
}

enable_service() {
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
}

main() {
  need_root
  install_deps
  clone_or_update
  build_all
  write_service
  enable_service

  log "Installed:"
  log "  ${BIN_UDPGW}"
  log "  ${BIN_TUN2SOCKS}"
  log "UDPGW service running on ${LISTEN_ADDR}"
}

main "$@"
