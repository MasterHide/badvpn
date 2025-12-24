#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="badvpn.service"
MANIFEST="/var/lib/badvpn/install_manifest.txt"

log() { echo -e "[badvpn] $*"; }
die() { echo -e "[badvpn] ERROR: $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root (use: sudo bash badvpn_uninstall.sh)"
  fi
}

main() {
  need_root

  if systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
    log "Stopping and disabling service..."
    systemctl disable --now "${SERVICE_NAME}" || true
  fi

  if [[ -f "${MANIFEST}" ]]; then
    log "Removing installed files from manifest: ${MANIFEST}"
    while IFS= read -r f; do
      [[ -z "${f}" ]] && continue
      if [[ -e "${f}" || -L "${f}" ]]; then
        rm -f -- "${f}"
        log "Removed: ${f}"
      fi
    done < "${MANIFEST}"
    rm -f "${MANIFEST}"
  else
    log "No manifest found at ${MANIFEST}. Removing common paths..."
    rm -f /usr/local/bin/badvpn-udpgw
    rm -f /etc/systemd/system/badvpn.service
  fi

  log "Reloading systemd..."
  systemctl daemon-reload || true

  # Optional: keep source dir /root/badvpn unless you want to remove it manually
  log "Uninstall complete."
  log "If you also want to remove source/build folders:"
  log "  rm -rf /root/badvpn"
}

main "$@"
