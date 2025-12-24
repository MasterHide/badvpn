#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX_DEFAULT="${SCRIPT_DIR}/badvpn"
PREFIX="$PREFIX_DEFAULT"

usage() {
  cat <<EOF
Usage:
  sudo ./badvpn_uninstall.sh [--prefix PATH]

Default prefix:
  ${PREFIX_DEFAULT}

This removes files listed in:
  PATH/.badvpn_install_manifest.txt
EOF
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Run as root (use sudo)." >&2
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix)
        PREFIX="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

remove_empty_dirs_upwards() {
  local path="$1"
  # Remove empty parent dirs, but never go above PREFIX
  while true; do
    [[ "$path" == "$PREFIX" ]] && break
    rmdir --ignore-fail-on-non-empty "$path" 2>/dev/null || break
    path="$(dirname "$path")"
  done
}

main() {
  need_root
  parse_args "$@"

  if [[ -z "${PREFIX}" || "${PREFIX}" == "/" ]]; then
    echo "ERROR: Invalid PREFIX='${PREFIX}'" >&2
    exit 1
  fi

  local manifest="${PREFIX}/.badvpn_install_manifest.txt"
  if [[ ! -f "${manifest}" ]]; then
    echo "ERROR: Manifest not found: ${manifest}" >&2
    echo "Uninstall cannot be done safely without it." >&2
    echo "If you installed to a different prefix, run with: --prefix /that/path" >&2
    exit 1
  fi

  echo "Uninstalling BadVPN from: ${PREFIX}"
  echo "Using manifest: ${manifest}"

  # Remove files listed in manifest
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ -e "$f" || -L "$f" ]]; then
      rm -f -- "$f"
      remove_empty_dirs_upwards "$(dirname "$f")" || true
    fi
  done < "${manifest}"

  # Remove our tracking files
  rm -f -- "${manifest}" "${PREFIX}/.badvpn_build_info.txt" 2>/dev/null || true

  echo "Done."
  echo "If you want to remove the whole prefix directory too:"
  echo "  rm -rf ${PREFIX}"
}

main "$@"
