#!/usr/bin/env bash
set -euo pipefail

# ===== Defaults =====
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Install into a single folder inside your repo by default:
PREFIX_DEFAULT="${SCRIPT_DIR}/badvpn"

# Build only what most VPS users need by default (tun2socks + udpgw)
BUILD_TUN2SOCKS=1
BUILD_UDPGW=1
BUILD_FULL=0

PREFIX="$PREFIX_DEFAULT"
JOBS="$(nproc || echo 1)"
CLEAN_PREFIX=0

usage() {
  cat <<EOF
Usage:
  sudo ./badvpn_install.sh [options]

Options:
  --prefix PATH        Install into PATH (default: ${PREFIX_DEFAULT})
  --full               Build "full" BadVPN (may require libssl-dev + libnspr4-dev)
  --only-tun2socks      Build/install only tun2socks
  --only-udpgw          Build/install only udpgw
  --clean-prefix        Delete PREFIX before installing (DANGEROUS)
  -j, --jobs N          Parallel build jobs (default: ${JOBS})
  -h, --help            Show help

Examples:
  sudo ./badvpn_install.sh
  sudo ./badvpn_install.sh --prefix /root/badvpn
  sudo ./badvpn_install.sh --prefix /opt/badvpn --only-udpgw
  sudo ./badvpn_install.sh --full --prefix /opt/badvpn
EOF
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Run as root (use sudo)." >&2
    exit 1
  fi
}

has_cmakelists() {
  [[ -f "${SCRIPT_DIR}/CMakeLists.txt" ]]
}

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates git cmake make gcc g++ pkg-config

  if [[ "$BUILD_FULL" -eq 1 ]]; then
    apt-get install -y --no-install-recommends libssl-dev libnspr4-dev
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix)
        PREFIX="${2:-}"
        shift 2
        ;;
      --full)
        BUILD_FULL=1
        shift
        ;;
      --only-tun2socks)
        BUILD_TUN2SOCKS=1
        BUILD_UDPGW=0
        BUILD_FULL=0
        shift
        ;;
      --only-udpgw)
        BUILD_TUN2SOCKS=0
        BUILD_UDPGW=1
        BUILD_FULL=0
        shift
        ;;
      --clean-prefix)
        CLEAN_PREFIX=1
        shift
        ;;
      -j|--jobs)
        JOBS="${2:-1}"
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

main() {
  need_root
  parse_args "$@"

  if ! has_cmakelists; then
    echo "ERROR: CMakeLists.txt not found in ${SCRIPT_DIR}" >&2
    echo "Make sure you run this script from inside the BadVPN source repo." >&2
    exit 1
  fi

  echo "[1/6] Installing build dependencies..."
  install_deps

  if [[ "$CLEAN_PREFIX" -eq 1 ]]; then
    if [[ -z "${PREFIX}" || "${PREFIX}" == "/" ]]; then
      echo "ERROR: Refusing to clean PREFIX='${PREFIX}'" >&2
      exit 1
    fi
    echo "[2/6] Cleaning install prefix: ${PREFIX}"
    rm -rf -- "${PREFIX}"
  fi

  echo "[2/6] Preparing install prefix: ${PREFIX}"
  mkdir -p -- "${PREFIX}"

  # Build in /tmp so you don't have build/ inside your badvpn folder
  BUILD_DIR="$(mktemp -d -t badvpn-build-XXXXXXXX)"
  trap 'rm -rf -- "${BUILD_DIR}"' EXIT

  echo "[3/6] Configuring (CMake) in: ${BUILD_DIR}"
  CMAKE_ARGS=(
    "${SCRIPT_DIR}"
    "-DCMAKE_INSTALL_PREFIX=${PREFIX}"
    "-DCMAKE_BUILD_TYPE=Release"
  )

  if [[ "$BUILD_FULL" -eq 0 ]]; then
    # Use official flags from README for only tun2socks/udpgw :contentReference[oaicite:1]{index=1}
    CMAKE_ARGS+=(
      "-DBUILD_NOTHING_BY_DEFAULT=1"
    )
    [[ "$BUILD_TUN2SOCKS" -eq 1 ]] && CMAKE_ARGS+=("-DBUILD_TUN2SOCKS=1")
    [[ "$BUILD_UDPGW" -eq 1 ]] && CMAKE_ARGS+=("-DBUILD_UDPGW=1")
  fi

  cmake -S "${SCRIPT_DIR}" -B "${BUILD_DIR}" "${CMAKE_ARGS[@]}"

  echo "[4/6] Building (jobs=${JOBS})..."
  cmake --build "${BUILD_DIR}" -- -j"${JOBS}"

  echo "[5/6] Installing to: ${PREFIX}"
  cmake --install "${BUILD_DIR}"

  # Save manifest for uninstall
  MANIFEST_SRC="${BUILD_DIR}/install_manifest.txt"
  MANIFEST_DST="${PREFIX}/.badvpn_install_manifest.txt"
  if [[ -f "${MANIFEST_SRC}" ]]; then
    cp -f -- "${MANIFEST_SRC}" "${MANIFEST_DST}"
  else
    echo "WARNING: install_manifest.txt not found. Uninstall may not work cleanly." >&2
  fi

  # Save build info
  {
    echo "prefix=${PREFIX}"
    echo "date=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "full_build=${BUILD_FULL}"
    echo "tun2socks=${BUILD_TUN2SOCKS}"
    echo "udpgw=${BUILD_UDPGW}"
    (cd "${SCRIPT_DIR}" && git rev-parse HEAD 2>/dev/null | sed 's/^/git_commit=/' ) || true
  } > "${PREFIX}/.badvpn_build_info.txt"

  echo "[6/6] Done."
  echo "Installed files live under: ${PREFIX}"
  echo "Binaries (if built) should be in: ${PREFIX}/bin"
  echo ""
  echo "Try:"
  [[ -x "${PREFIX}/bin/badvpn-tun2socks" ]] && echo "  ${PREFIX}/bin/badvpn-tun2socks --help"
  [[ -x "${PREFIX}/bin/badvpn-udpgw" ]] && echo "  ${PREFIX}/bin/badvpn-udpgw --help"
}

main "$@"
