#!/usr/bin/env bash
# =============================================================================
# upgrade-qbittorrent-5.2.sh
#
# Controlled in-place upgrade of qbittorrent-nox to the latest stable 5.2.x
# on an existing Swizzin / Debian 12 (Bookworm) server.
#
# Build & packaging deliberately mirror Swizzin PR #1300 / commit 86102c6
# (sources/functions/qbittorrent) without modifying /etc/swizzin.
#
# Reference:
#   https://github.com/swizzin/swizzin/pull/1300
#   https://github.com/swizzin/swizzin/commit/86102c65ace2e989863e5e54878cfc0b24c07e46
#   qBittorrent 5.2.x CMakeLists.txt / INSTALL (GUI=OFF → qbittorrent-nox)
#
# Copyright (C) 2026
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:
#   ./upgrade-qbittorrent-5.2.sh --dry-run
#   ./upgrade-qbittorrent-5.2.sh --yes
#   ./upgrade-qbittorrent-5.2.sh --rollback
#   ./upgrade-qbittorrent-5.2.sh --version 5.2.3
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Constants / defaults
# -----------------------------------------------------------------------------
SCRIPT_NAME="$(basename "${0}")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="1.3.2"
readonly LOG_FILE="${QBT_UPGRADE_LOG:-/var/log/qbittorrent-5.2-upgrade.log}"
readonly WORK_ROOT="${QBT_UPGRADE_WORK:-/var/tmp/qbittorrent-5.2-upgrade}"
readonly DIST_DIR="${QBT_UPGRADE_DIST:-/root/dist}"
readonly BACKUP_ROOT_BASE="/root"
readonly DEFAULT_SERIES="5.2"
readonly QBT_REPO_URL="https://github.com/qbittorrent/qBittorrent"
readonly LIBTORRENT_REPO_URL="https://github.com/arvidn/libtorrent.git"
readonly QT6_CROSSBUILD_REPO="swizzin/qt6_crossbuild"
readonly CMAKE_CROSSBUILD_REPO="swizzin/cmake_crossbuild"
readonly ZLIB_NG_CROSSBUILD_REPO="swizzin/zlib-ng-crossbuild"
readonly MIN_FREE_MIB=4096
readonly NGINX_QBT_CONF="/etc/nginx/apps/qbittorrent.conf"
readonly NGINX_QBT_CONF_ORIG="/etc/nginx/apps/qbittorrent.conf.orig"
# Soft fallbacks ONLY if upstream metadata cannot be read
readonly FALLBACK_CMAKE_MIN="3.16"
readonly FALLBACK_STDCVER="c++20"
readonly FALLBACK_QT_MINIMUM="6.6.0"
readonly FALLBACK_LIBTORRENT1_MINIMUM="1.2.19"
readonly FALLBACK_LIBTORRENT2_MINIMUM="2.0.10"
readonly FALLBACK_BOOST_MINIMUM="1.76"
readonly FALLBACK_OPENSSL_MINIMUM="3.0.2"
readonly FALLBACK_ZLIB_MINIMUM="1.2.11"
readonly QBT_LIBTORRENT_BRANCH_DEFAULT="RC_1_2"

# Runtime flags / state
DRY_RUN=0
ASSUME_YES=0
DO_ROLLBACK=0
TARGET_VERSION_OVERRIDE=""
SERIES_OVERRIDE=""
LIBTORRENT_BRANCH_OVERRIDE=""
BACKUP_DIR=""
SOURCE_DIR=""
BUILD_DIR=""
STAGE_DIR=""
STARTED_SERVICES=()
STOPPED_SERVICES=()
PREVIOUSLY_ACTIVE_SERVICES=()
TMP_MOUNTED_EXEC=0
CLEANUP_PATHS=()
STATE_FILE=""
OPENSSL_VERSION_FOUND=""

# Resolved from upstream source for the target version (resolve_requirements_from_upstream)
SERIES="${DEFAULT_SERIES}"
CMAKE_MIN_VERSION=""
QBT_STDCVER=""
QBT_QT_MINIMUM=""
QBT_LIBTORRENT_MINIMUM=""
QBT_LIBTORRENT2_MINIMUM=""
QBT_BOOST_MINIMUM=""
QBT_OPENSSL_MINIMUM=""
QBT_ZLIB_MINIMUM=""
REQUIREMENTS_SOURCE=""
REQUIREMENTS_RESOLVED=0

# Discovered environment (filled by probe_*)
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
OS_ARCH=""
DPKG_ARCH=""
CURRENT_QBT_VERSION=""
CURRENT_LIBTORRENT_VERSION=""
CURRENT_QT_VERSION=""
CURRENT_CMAKE_VERSION=""
CURRENT_NINJA_VERSION=""
TARGET_VERSION=""
QT_METHOD=""          # repo | swizzin | existing-swizzin
NEED_QT6_SWIZZIN=0
NEED_CMAKE_SWIZZIN=0
NEED_ZLIB_NG=0
NEED_LIBTORRENT_BUILD=0
NEED_BOOST=0
BOOST_VERSION="1_85_0"
BOOST_ROOT_DIR=""
QBT_BINARY=""
QBT_PACKAGE_VERSION=""
FPM_AVAILABLE=0
SWIZZIN_QBT_FUNC=""
CONFIG_PATHS=()
SERVICE_UNITS=()
PLANNED_PACKAGES=()

# -----------------------------------------------------------------------------
# Logging / helpers
# -----------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_ensure_log() {
  if [[ ! -f "${LOG_FILE}" ]]; then
    # Best-effort create; may fail in dry-run as non-root — then fall back to stderr only.
    touch "${LOG_FILE}" 2>/dev/null || true
  fi
}

log() {
  local level="$1"
  shift
  local msg="$*"
  local line
  line="[$( _ts )] [${level}] ${msg}"
  printf '%s\n' "${line}" >&2
  if [[ -w "${LOG_FILE}" ]] || [[ -w "$(dirname "${LOG_FILE}")" ]]; then
    printf '%s\n' "${line}" >> "${LOG_FILE}" 2>/dev/null || true
  fi
}

info()  { log "INFO"  "$*"; }
warn()  { log "WARN"  "$*"; }
error() { log "ERROR" "$*"; }
ok()    { log "OK"    "$*"; }

die() {
  error "$*"
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root (current EUID=${EUID})."
  fi
}

quote_cmd() {
  local out="" arg
  for arg in "$@"; do
    out+="$(printf '%q' "${arg}") "
  done
  printf '%s' "${out% }"
}

run_cmd() {
  # run_cmd [--allow-fail] command args...
  local allow_fail=0
  if [[ "${1:-}" == "--allow-fail" ]]; then
    allow_fail=1
    shift
  fi
  info "CMD: $(quote_cmd "$@")"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "DRY-RUN: command will not be executed."
    return 0
  fi
  if "$@" >> "${LOG_FILE}" 2>&1; then
    return 0
  fi
  if [[ "${allow_fail}" -eq 1 ]]; then
    warn "Command failed (allow-fail): $(quote_cmd "$@")"
    return 1
  fi
  die "Command failed: $(quote_cmd "$@") — see details in ${LOG_FILE}"
}

version_ge() {
  # version_ge A B  → true if A >= B (dpkg)
  dpkg --compare-versions "$1" ge "$2"
}

version_lt() {
  dpkg --compare-versions "$1" lt "$2"
}

confirm() {
  local prompt="$1"
  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    info "Confirmation skipped (--yes): ${prompt}"
    return 0
  fi
  local answer=""
  printf '%s [y/N]: ' "${prompt}" >&2
  read -r answer || true
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) die "Aborted by user." ;;
  esac
}

safe_rm_path() {
  # Only remove paths we explicitly registered under WORK_ROOT / known temps.
  local path="$1"
  if [[ -z "${path}" || "${path}" == "/" || "${path}" == "/root" || "${path}" == "/home" ]]; then
    warn "safe_rm_path: refusing unsafe path: '${path}'"
    return 1
  fi
  case "${path}" in
    "${WORK_ROOT}"/*|"/tmp/dist/qbittorrent"*|"/tmp/dist/libtorrent"*|"/tmp/qbittorrent-upgrade-"*)
      if [[ -e "${path}" || -L "${path}" ]]; then
        info "Cleanup: ${path}"
        rm -rf --one-file-system -- "${path}"
      fi
      ;;
    *)
      warn "safe_rm_path: path not on allowed whitelist: ${path}"
      return 1
      ;;
  esac
}

register_cleanup() {
  CLEANUP_PATHS+=("$1")
}

on_error() {
  local ec=$?
  local line="${1:-?}"
  error "Abort at line ${line} (exit=${ec}). Log: ${LOG_FILE}"
  # Attempt to restore previously active services if we stopped them.
  if [[ "${DRY_RUN}" -eq 0 && ${#PREVIOUSLY_ACTIVE_SERVICES[@]} -gt 0 ]]; then
    local svc
    for svc in "${PREVIOUSLY_ACTIVE_SERVICES[@]}"; do
      if ! systemctl is-active --quiet "${svc}" 2>/dev/null; then
        warn "Error recovery: restarting previously active service: ${svc}"
        systemctl start "${svc}" >> "${LOG_FILE}" 2>&1 || warn "Could not start ${svc}."
      fi
    done
  fi
  if [[ "${TMP_MOUNTED_EXEC}" -eq 1 ]]; then
    mount -o remount,noexec /tmp >> "${LOG_FILE}" 2>&1 || true
    TMP_MOUNTED_EXEC=0
  fi
  exit "${ec}"
}

on_exit() {
  if [[ "${TMP_MOUNTED_EXEC}" -eq 1 ]]; then
    mount -o remount,noexec /tmp >> "${LOG_FILE}" 2>&1 || true
    TMP_MOUNTED_EXEC=0
  fi
}

trap 'on_error ${LINENO}' ERR
trap on_exit EXIT

usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Controlled upgrade of qbittorrent-nox from official source. Build and packaging
follow the Swizzin approach (PR #1300). Build requirements (Qt, libtorrent, CMake,
C++, …) are resolved from the upstream source for the target version — not hard-coded.

Options:
  --dry-run              Analyse and plan only; make no changes
  --yes                  Skip interactive confirmation
  --rollback             Restore the last backup (package + service state)
  --version X.Y.Z        Exact stable version (e.g. 5.2.3; later also 5.3.x)
  --series X.Y           Latest stable release in this series (default: ${DEFAULT_SERIES})
  --libtorrent BRANCH    RC_1_2 (default) or RC_2_0
  --help                 Show this help

Environment variables:
  QBT_UPGRADE_LOG        Log file (default: ${LOG_FILE})
  QBT_UPGRADE_WORK       Work directory (default: ${WORK_ROOT})
  QBT_UPGRADE_DIST       Output directory for .deb packages (default: ${DIST_DIR})

Examples:
  ${SCRIPT_NAME} --dry-run
  ${SCRIPT_NAME} --version 5.2.3 --yes
  ${SCRIPT_NAME} --series 5.2 --yes
  ${SCRIPT_NAME} --rollback
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --rollback) DO_ROLLBACK=1; shift ;;
      --version)
        [[ $# -ge 2 ]] || die "--version requires an argument"
        TARGET_VERSION_OVERRIDE="$2"
        shift 2
        ;;
      --series)
        [[ $# -ge 2 ]] || die "--series requires an argument (e.g. 5.2)"
        SERIES_OVERRIDE="$2"
        shift 2
        ;;
      --libtorrent)
        [[ $# -ge 2 ]] || die "--libtorrent requires RC_1_2 or RC_2_0"
        LIBTORRENT_BRANCH_OVERRIDE="$2"
        shift 2
        ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
  done

  if [[ -n "${LIBTORRENT_BRANCH_OVERRIDE}" ]]; then
    case "${LIBTORRENT_BRANCH_OVERRIDE}" in
      RC_1_2|RC_2_0) ;;
      *) die "--libtorrent must be RC_1_2 or RC_2_0 (Swizzin-compatible)." ;;
    esac
  fi

  if [[ -n "${TARGET_VERSION_OVERRIDE}" ]]; then
    if [[ ! "${TARGET_VERSION_OVERRIDE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      die "--version must be a stable X.Y.Z release (e.g. 5.2.3), not RC/beta."
    fi
    # Derive series from version (5.2.3 → 5.2)
    SERIES="$(printf '%s' "${TARGET_VERSION_OVERRIDE}" | cut -d. -f1-2)"
  fi

  if [[ -n "${SERIES_OVERRIDE}" ]]; then
    if [[ ! "${SERIES_OVERRIDE}" =~ ^[0-9]+\.[0-9]+$ ]]; then
      die "--series must be X.Y (e.g. 5.2)."
    fi
    SERIES="${SERIES_OVERRIDE}"
  fi

  if [[ -z "${SERIES_OVERRIDE}" && -z "${TARGET_VERSION_OVERRIDE}" ]]; then
    SERIES="${DEFAULT_SERIES}"
  fi
}

# -----------------------------------------------------------------------------
# OS / toolchain probes
# -----------------------------------------------------------------------------
probe_os() {
  info "Checking Debian version and architecture…"
  if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release is missing — unsupported system."
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_ARCH="$(uname -m)"
  DPKG_ARCH="$(dpkg --print-architecture)"

  if [[ "${OS_ID}" != "debian" ]]; then
    die "Expected Debian, found ID=${OS_ID}."
  fi
  if [[ "${OS_VERSION_ID}" != "12" && "${OS_CODENAME}" != "bookworm" ]]; then
    die "Expected Debian 12 Bookworm (found ${OS_ID} ${OS_VERSION_ID} / ${OS_CODENAME})."
  fi
  ok "Debian ${OS_VERSION_ID} (${OS_CODENAME}), arch=${OS_ARCH}, dpkg=${DPKG_ARCH}"
}

probe_qbittorrent() {
  info "Detecting installed qBittorrent version…"
  QBT_BINARY="$(command -v qbittorrent-nox || true)"
  if [[ -z "${QBT_BINARY}" ]]; then
    # Common Swizzin path
    if [[ -x /usr/bin/qbittorrent-nox ]]; then
      QBT_BINARY="/usr/bin/qbittorrent-nox"
    fi
  fi
  if [[ -n "${QBT_BINARY}" ]]; then
    CURRENT_QBT_VERSION="$("${QBT_BINARY}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  fi
  if dpkg -s qbittorrent-nox >/dev/null 2>&1; then
    QBT_PACKAGE_VERSION="$(dpkg-query -W -f='${Version}' qbittorrent-nox 2>/dev/null || true)"
    info "dpkg qbittorrent-nox version: ${QBT_PACKAGE_VERSION}"
  else
    warn "Package qbittorrent-nox is not registered with dpkg."
  fi
  if [[ -z "${CURRENT_QBT_VERSION}" ]]; then
    die "qbittorrent-nox could not be found or versioned."
  fi
  ok "Current qBittorrent version: ${CURRENT_QBT_VERSION} (binary: ${QBT_BINARY})"
}

probe_libtorrent() {
  info "Detecting installed libtorrent version…"
  CURRENT_LIBTORRENT_VERSION=""
  if [[ -f /usr/local/lib/libtorrent-rasterbar.a ]]; then
    CURRENT_LIBTORRENT_VERSION="$(
      strings /usr/local/lib/libtorrent-rasterbar.a 2>/dev/null \
        | grep -m1 -E 'libtorrent/[0-9]+\.[0-9]+\.[0-9]+' \
        | cut -d/ -f2 \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' \
        || true
    )"
    info "Static libtorrent under /usr/local/lib: ${CURRENT_LIBTORRENT_VERSION:-unknown}"
  fi
  if [[ -z "${CURRENT_LIBTORRENT_VERSION}" ]] && command -v pkg-config >/dev/null 2>&1; then
    if pkg-config --exists libtorrent-rasterbar 2>/dev/null; then
      CURRENT_LIBTORRENT_VERSION="$(pkg-config --modversion libtorrent-rasterbar 2>/dev/null || true)"
      info "pkg-config libtorrent-rasterbar: ${CURRENT_LIBTORRENT_VERSION}"
    fi
  fi
  if dpkg -s libtorrent-rasterbar >/dev/null 2>&1; then
    local pkgv
    pkgv="$(dpkg-query -W -f='${Version}\n${Description}' libtorrent-rasterbar 2>/dev/null || true)"
    info "dpkg libtorrent-rasterbar: ${pkgv}"
  fi
  if [[ -z "${CURRENT_LIBTORRENT_VERSION}" ]]; then
    warn "Could not determine libtorrent version — a rebuild may be required."
  else
    ok "libtorrent: ${CURRENT_LIBTORRENT_VERSION}"
  fi
}

probe_qt() {
  info "Detecting Qt6 version…"
  CURRENT_QT_VERSION=""
  if command -v qmake6 >/dev/null 2>&1; then
    CURRENT_QT_VERSION="$(qmake6 -query QT_VERSION 2>/dev/null || true)"
  elif [[ -x /opt/local/bin/qmake6 ]]; then
    CURRENT_QT_VERSION="$(/opt/local/bin/qmake6 -query QT_VERSION 2>/dev/null || true)"
  elif command -v qmake >/dev/null 2>&1; then
    CURRENT_QT_VERSION="$(qmake -query QT_VERSION 2>/dev/null || true)"
  fi
  if [[ -z "${CURRENT_QT_VERSION}" ]] && dpkg -s qt6-swizzin >/dev/null 2>&1; then
    CURRENT_QT_VERSION="$(dpkg-query -W -f='${Version}' qt6-swizzin 2>/dev/null | sed 's/+.*//' || true)"
    info "qt6-swizzin package version: ${CURRENT_QT_VERSION}"
  fi
  if [[ -z "${CURRENT_QT_VERSION}" ]]; then
    # Try dpkg qt6-base
    local basev
    basev="$(dpkg-query -W -f='${Version}' qt6-base-dev 2>/dev/null || true)"
    if [[ -n "${basev}" ]]; then
      CURRENT_QT_VERSION="$(printf '%s' "${basev}" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
    fi
  fi
  if [[ -z "${CURRENT_QT_VERSION}" ]]; then
    warn "No Qt6 version found."
  else
    ok "Qt: ${CURRENT_QT_VERSION}"
  fi
}

probe_cmake_ninja() {
  info "Detecting CMake and Ninja versions…"
  local cmake_bin=""
  if [[ -x /opt/local/bin/cmake ]]; then
    cmake_bin="/opt/local/bin/cmake"
  elif command -v cmake >/dev/null 2>&1; then
    cmake_bin="$(command -v cmake)"
  fi
  if [[ -n "${cmake_bin}" ]]; then
    CURRENT_CMAKE_VERSION="$("${cmake_bin}" --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    ok "CMake: ${CURRENT_CMAKE_VERSION} (${cmake_bin})"
  else
    warn "CMake not found."
  fi
  if command -v ninja >/dev/null 2>&1; then
    CURRENT_NINJA_VERSION="$(ninja --version 2>/dev/null || true)"
    ok "Ninja: ${CURRENT_NINJA_VERSION}"
  else
    warn "Ninja not found."
  fi
}

probe_openssl() {
  OPENSSL_VERSION_FOUND=""
  if command -v openssl >/dev/null 2>&1; then
    OPENSSL_VERSION_FOUND="$(openssl version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  fi
  info "OpenSSL: ${OPENSSL_VERSION_FOUND:-unknown}"
}

probe_services() {
  info "Detecting qBittorrent services (service name is not assumed)…"
  SERVICE_UNITS=()
  PREVIOUSLY_ACTIVE_SERVICES=()
  local unit
  # Template instances qbittorrent@*
  while IFS= read -r unit; do
    [[ -n "${unit}" ]] || continue
    SERVICE_UNITS+=("${unit}")
  done < <(systemctl list-units --all --type=service --no-legend --plain 2>/dev/null \
            | awk '{print $1}' \
            | grep -E '^qbittorrent(@.+)?\.service$' || true)

  # Also catch enabled but inactive units
  while IFS= read -r unit; do
    [[ -n "${unit}" ]] || continue
    local found=0
    local existing
    for existing in "${SERVICE_UNITS[@]+"${SERVICE_UNITS[@]}"}"; do
      if [[ "${existing}" == "${unit}" ]]; then found=1; break; fi
    done
    if [[ "${found}" -eq 0 ]]; then
      SERVICE_UNITS+=("${unit}")
    fi
  done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null \
            | awk '{print $1}' \
            | grep -E '^qbittorrent(@.+)?\.service$' || true)

  if [[ ${#SERVICE_UNITS[@]} -eq 0 ]]; then
    warn "No qbittorrent*.service found."
  else
    for unit in "${SERVICE_UNITS[@]}"; do
      local st
      st="$(systemctl is-active "${unit}" 2>/dev/null || true)"
      info "Service ${unit}: ${st}"
      if [[ "${st}" == "active" ]]; then
        PREVIOUSLY_ACTIVE_SERVICES+=("${unit}")
      fi
    done
    ok "Services found: ${SERVICE_UNITS[*]}"
  fi
}

probe_configs() {
  info "Detecting qBittorrent configuration paths…"
  CONFIG_PATHS=()
  local home conf user unit
  # From service users
  for unit in "${SERVICE_UNITS[@]+"${SERVICE_UNITS[@]}"}"; do
    user="$(systemctl show -p User --value "${unit}" 2>/dev/null || true)"
    if [[ -z "${user}" || "${user}" == "root" ]]; then
      # Try instance name from qbittorrent@user
      if [[ "${unit}" =~ ^qbittorrent@(.+)\.service$ ]]; then
        user="${BASH_REMATCH[1]}"
      fi
    fi
    if [[ -n "${user}" ]]; then
      home="$(getent passwd "${user}" | cut -d: -f6 || true)"
      if [[ -n "${home}" ]]; then
        conf="${home}/.config/qBittorrent"
        if [[ -d "${conf}" ]]; then
          CONFIG_PATHS+=("${conf}")
        fi
        # Also data dir (BT_backup etc.) — backup only config; mention data
        if [[ -d "${home}/.local/share/qBittorrent" ]]; then
          info "Data directory found (will not be overwritten): ${home}/.local/share/qBittorrent"
        fi
      fi
    fi
  done
  # Fallback: scan /home/*/.config/qBittorrent
  local d
  for d in /home/*/.config/qBittorrent /root/.config/qBittorrent; do
    if [[ -d "${d}" ]]; then
      local already=0
      local existing
      for existing in "${CONFIG_PATHS[@]+"${CONFIG_PATHS[@]}"}"; do
        if [[ "${existing}" == "${d}" ]]; then already=1; break; fi
      done
      if [[ "${already}" -eq 0 ]]; then
        CONFIG_PATHS+=("${d}")
      fi
    fi
  done
  if [[ ${#CONFIG_PATHS[@]} -eq 0 ]]; then
    warn "No qBittorrent configuration found."
  else
    ok "Configurations: ${CONFIG_PATHS[*]}"
  fi
}

probe_disk_network() {
  info "Checking free disk space…"
  local avail_kib
  avail_kib="$(df -Pk /var/tmp 2>/dev/null | awk 'NR==2{print $4}')"
  local avail_mib=$(( avail_kib / 1024 ))
  if [[ "${avail_mib}" -lt "${MIN_FREE_MIB}" ]]; then
    die "Insufficient free space under /var/tmp: ${avail_mib} MiB (at least ${MIN_FREE_MIB} MiB recommended)."
  fi
  ok "Free space /var/tmp: ~${avail_mib} MiB"

  info "Checking Internet / GitHub reachability…"
  if ! curl -fsSIL --connect-timeout 10 --max-time 30 "https://github.com/" >/dev/null 2>&1; then
    die "https://github.com is not reachable."
  fi
  if ! curl -fsSIL --connect-timeout 10 --max-time 30 "${QBT_REPO_URL}" >/dev/null 2>&1; then
    die "${QBT_REPO_URL} is not reachable."
  fi
  ok "GitHub / qBittorrent repository reachable"
}

probe_swizzin_reference() {
  SWIZZIN_QBT_FUNC=""
  if [[ -f /etc/swizzin/sources/functions/qbittorrent ]]; then
    SWIZZIN_QBT_FUNC="/etc/swizzin/sources/functions/qbittorrent"
    info "Swizzin reference found (analysis only, no modification): ${SWIZZIN_QBT_FUNC}"
    if grep -q '5\.2\.\*' "${SWIZZIN_QBT_FUNC}" 2>/dev/null; then
      ok "Local Swizzin function already includes 5.2.* support."
    else
      warn "Local Swizzin function may not know 5.2.* yet (PR #1300 not merged). This script operates independently."
    fi
  else
    info "No /etc/swizzin/sources/functions/qbittorrent — script runs standalone following PR #1300."
  fi
}

# -----------------------------------------------------------------------------
# Version resolution (stable releases of the selected series)
# -----------------------------------------------------------------------------
resolve_target_version() {
  info "Resolving target version for series ${SERIES}.x (stable releases only)…"
  if [[ -n "${TARGET_VERSION_OVERRIDE}" ]]; then
    TARGET_VERSION="${TARGET_VERSION_OVERRIDE}"
    SERIES="$(printf '%s' "${TARGET_VERSION}" | cut -d. -f1-2)"
    ok "Target version (override): ${TARGET_VERSION}"
    return 0
  fi

  local series_re
  series_re="$(printf '%s' "${SERIES}" | sed 's/\./\\./g')"

  local tags
  tags="$(git ls-remote -t --refs "${QBT_REPO_URL}.git" 2>/dev/null \
    | awk '{print $2}' \
    | sed 's#refs/tags/release-##' \
    | grep -E "^${series_re}\.[0-9]+$" \
    | grep -viE 'beta|rc|alpha|dev|nightly' \
    | sort -Vr || true)"

  if [[ -z "${tags}" ]]; then
    tags="$(curl -fsSL "https://api.github.com/repos/qbittorrent/qBittorrent/tags?per_page=100" \
      | SERIES_ENV="${SERIES}" python3 -c "
import sys, json, re, os
series = os.environ.get('SERIES_ENV', '5.2')
pat = re.compile(r'^release-(' + re.escape(series) + r'\.\d+)$')
data = json.load(sys.stdin)
vers = []
for t in data:
    m = pat.match(t.get('name',''))
    if m:
        vers.append(m.group(1))
print('\n'.join(sorted(vers, key=lambda v: [int(x) for x in v.split('.')], reverse=True)))
" 2>/dev/null || true)"
  fi

  TARGET_VERSION="$(printf '%s\n' "${tags}" | head -n1)"
  if [[ -z "${TARGET_VERSION}" ]]; then
    die "Could not determine a stable ${SERIES}.x version from GitHub."
  fi
  if [[ ! "${TARGET_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Invalid target version resolved: ${TARGET_VERSION}"
  fi
  ok "Latest stable ${SERIES}.x: ${TARGET_VERSION}"
}

# -----------------------------------------------------------------------------
# Read build requirements from upstream source for the target version
# -----------------------------------------------------------------------------
fetch_upstream_text() {
  local rel_path="$1"
  local url="https://raw.githubusercontent.com/qbittorrent/qBittorrent/release-${TARGET_VERSION}/${rel_path}"
  curl -fsSL --connect-timeout 15 --max-time 60 "${url}" 2>/dev/null || true
}

normalize_version_triplet() {
  # 6.6 / 6.6.0 / 1.2.19 → at least major.minor.patch for dpkg comparisons
  local v="$1"
  local parts
  IFS='.' read -r -a parts <<< "${v}"
  local a="${parts[0]:-0}"
  local b="${parts[1]:-0}"
  local c="${parts[2]:-0}"
  printf '%s.%s.%s' "${a}" "${b}" "${c}"
}

pick_boost_version_for_minimum() {
  # Pick a Boost source version >= minimum; prefer 1_85_0 (Swizzin/Bookworm), else next higher.
  local min_dot
  min_dot="$(normalize_version_triplet "${1}")"
  if version_ge "1.85.0" "${min_dot}"; then
    printf '%s' "1_85_0"
    return 0
  fi
  local candidates=("1_86_0" "1_87_0" "1_88_0" "1_89_0" "1_90_0")
  local cand cand_dot
  for cand in "${candidates[@]}"; do
    cand_dot="$(normalize_version_triplet "${cand//_/.}")"
    if version_ge "${cand_dot}" "${min_dot}"; then
      printf '%s' "${cand}"
      return 0
    fi
  done
  local maj minor
  maj="$(printf '%s' "${min_dot}" | cut -d. -f1)"
  minor="$(printf '%s' "${min_dot}" | cut -d. -f2)"
  printf '%s_%s_0' "${maj}" "${minor}"
}

resolve_requirements_from_upstream() {
  [[ -n "${TARGET_VERSION}" ]] || die "TARGET_VERSION ist leer — zuerst resolve_target_version aufrufen."
  info "Resolving build requirements from upstream release-${TARGET_VERSION}…"

  local cmake_txt cfg_txt tmpd
  tmpd="$(mktemp -d /tmp/qbt-req-XXXXXX)"
  cmake_txt="$(fetch_upstream_text "CMakeLists.txt")"
  cfg_txt="$(fetch_upstream_text "cmake/Modules/CommonConfig.cmake")"
  if [[ -z "${cfg_txt}" ]]; then
    cfg_txt="$(fetch_upstream_text "cmake/CommonConfig.cmake")"
  fi

  if [[ -z "${cmake_txt}" ]]; then
    rm -rf --one-file-system -- "${tmpd}"
    warn "Could not fetch CMakeLists.txt for release-${TARGET_VERSION} — using fallbacks."
    CMAKE_MIN_VERSION="$(normalize_version_triplet "${FALLBACK_CMAKE_MIN}")"
    QBT_STDCVER="${FALLBACK_STDCVER}"
    QBT_QT_MINIMUM="$(normalize_version_triplet "${FALLBACK_QT_MINIMUM}")"
    QBT_LIBTORRENT_MINIMUM="$(normalize_version_triplet "${FALLBACK_LIBTORRENT1_MINIMUM}")"
    QBT_LIBTORRENT2_MINIMUM="$(normalize_version_triplet "${FALLBACK_LIBTORRENT2_MINIMUM}")"
    QBT_BOOST_MINIMUM="$(normalize_version_triplet "${FALLBACK_BOOST_MINIMUM}")"
    QBT_OPENSSL_MINIMUM="$(normalize_version_triplet "${FALLBACK_OPENSSL_MINIMUM}")"
    QBT_ZLIB_MINIMUM="$(normalize_version_triplet "${FALLBACK_ZLIB_MINIMUM}")"
    REQUIREMENTS_SOURCE="fallback"
    REQUIREMENTS_RESOLVED=0
    return 0
  fi

  printf '%s\n' "${cmake_txt}" > "${tmpd}/CMakeLists.txt"
  printf '%s\n' "${cfg_txt}" > "${tmpd}/CommonConfig.cmake"

  local parsed
  parsed="$(
    python3 - "${tmpd}/CMakeLists.txt" "${tmpd}/CommonConfig.cmake" <<'PY'
import re, sys
from pathlib import Path

cmake = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
cfg = Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace") if Path(sys.argv[2]).stat().st_size else ""

def grab(pattern, text, default=""):
    m = re.search(pattern, text, re.M | re.I)
    return m.group(1).strip() if m else default

cmake_min = grab(r'cmake_minimum_required\s*\(\s*VERSION\s+([0-9]+(?:\.[0-9]+){1,2})', cmake, "3.16")
boost = grab(r'set\s*\(\s*minBoostVersion\s+([0-9]+(?:\.[0-9]+){1,2})\s*\)', cmake)
qt = grab(r'set\s*\(\s*minQt6Version\s+([0-9]+(?:\.[0-9]+){1,2})\s*\)', cmake)
if not qt:
    qt = grab(r'set\s*\(\s*minQtVersion\s+([0-9]+(?:\.[0-9]+){1,2})\s*\)', cmake)
openssl = grab(r'set\s*\(\s*minOpenSSLVersion\s+([0-9]+(?:\.[0-9]+){1,2})\s*\)', cmake)
lt1 = grab(r'set\s*\(\s*minLibtorrent1Version\s+([0-9]+(?:\.[0-9]+){1,2})\s*\)', cmake)
lt2 = grab(r'set\s*\(\s*minLibtorrentVersion\s+([0-9]+(?:\.[0-9]+){1,2})\s*\)', cmake)
zlib = grab(r'set\s*\(\s*minZlibVersion\s+([0-9]+(?:\.[0-9]+){1,2})\s*\)', cmake)

stdc = ""
m = re.search(r'cxx_std_(\d+)', cfg) or re.search(r'cxx_std_(\d+)', cmake)
if m:
    stdc = f"c++{m.group(1)}"
else:
    m = re.search(r'CMAKE_CXX_STANDARD\s+(\d+)', cfg + "\n" + cmake)
    if m:
        stdc = f"c++{m.group(1)}"

boost = boost or "1.76"
qt = qt or "6.6.0"
openssl = openssl or "3.0.2"
lt1 = lt1 or "1.2.19"
lt2 = lt2 or "2.0.10"
zlib = zlib or "1.2.11"
stdc = stdc or "c++20"

print(f"CMAKE_MIN={cmake_min}")
print(f"BOOST={boost}")
print(f"QT={qt}")
print(f"OPENSSL={openssl}")
print(f"LT1={lt1}")
print(f"LT2={lt2}")
print(f"ZLIB={zlib}")
print(f"STDC={stdc}")
PY
  )" || {
    rm -rf --one-file-system -- "${tmpd}"
    die "Failed to parse upstream CMakeLists."
  }
  rm -rf --one-file-system -- "${tmpd}"

  local line key val
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    case "${key}" in
      CMAKE_MIN) CMAKE_MIN_VERSION="$(normalize_version_triplet "${val}")" ;;
      BOOST) QBT_BOOST_MINIMUM="$(normalize_version_triplet "${val}")" ;;
      QT) QBT_QT_MINIMUM="$(normalize_version_triplet "${val}")" ;;
      OPENSSL) QBT_OPENSSL_MINIMUM="$(normalize_version_triplet "${val}")" ;;
      LT1) QBT_LIBTORRENT_MINIMUM="$(normalize_version_triplet "${val}")" ;;
      LT2) QBT_LIBTORRENT2_MINIMUM="$(normalize_version_triplet "${val}")" ;;
      ZLIB) QBT_ZLIB_MINIMUM="$(normalize_version_triplet "${val}")" ;;
      STDC) QBT_STDCVER="${val}" ;;
    esac
  done <<< "${parsed}"

  REQUIREMENTS_SOURCE="https://raw.githubusercontent.com/qbittorrent/qBittorrent/release-${TARGET_VERSION}/CMakeLists.txt (+ CommonConfig.cmake)"
  REQUIREMENTS_RESOLVED=1

  ok "Upstream requirements for ${TARGET_VERSION}:"
  info "  CMake >= ${CMAKE_MIN_VERSION}"
  info "  C++ ${QBT_STDCVER}"
  info "  Qt >= ${QBT_QT_MINIMUM}"
  info "  libtorrent 1.x >= ${QBT_LIBTORRENT_MINIMUM} / 2.x >= ${QBT_LIBTORRENT2_MINIMUM}"
  info "  Boost >= ${QBT_BOOST_MINIMUM}"
  info "  OpenSSL >= ${QBT_OPENSSL_MINIMUM}"
  info "  zlib >= ${QBT_ZLIB_MINIMUM}"
  info "  Source: ${REQUIREMENTS_SOURCE}"
}

# -----------------------------------------------------------------------------
# Dependency planning (from dynamic upstream requirements)
# -----------------------------------------------------------------------------
plan_dependencies() {
  info "Planning dependencies from resolved requirements…"
  [[ -n "${QBT_QT_MINIMUM}" && -n "${CMAKE_MIN_VERSION}" && -n "${QBT_STDCVER}" ]] \
    || die "Requirements not set — did resolve_requirements_from_upstream fail?"

  PLANNED_PACKAGES=(
    build-essential
    automake
    pkg-config
    libtool
    git
    curl
    ca-certificates
    zlib1g-dev
    libssl-dev
    libgeoip-dev
    python3
    ninja-build
    ruby
    ruby-dev
    libffi-dev
    libdouble-conversion-dev
    libdouble-conversion3
    libmd4c0
    libmd4c-dev
    libmd4c-html0
    libmd4c-html0-dev
  )
  PLANNED_PACKAGES+=(libicu-dev libiconv-hook-dev)

  NEED_QT6_SWIZZIN=0
  NEED_ZLIB_NG=0
  NEED_CMAKE_SWIZZIN=0
  NEED_LIBTORRENT_BUILD=0
  NEED_BOOST=0
  QT_METHOD="repo"

  if [[ -n "${CURRENT_QT_VERSION}" ]] && version_ge "${CURRENT_QT_VERSION}" "${QBT_QT_MINIMUM}"; then
    if dpkg -s qt6-swizzin >/dev/null 2>&1; then
      QT_METHOD="existing-swizzin"
      info "Existing qt6-swizzin (${CURRENT_QT_VERSION}) is sufficient (>= ${QBT_QT_MINIMUM})."
    else
      QT_METHOD="repo"
      PLANNED_PACKAGES+=(qt6-base-dev qt6-tools-dev qt6-l10n-tools qt6-tools-dev-tools qt6-base-private-dev)
      info "Repo/system Qt ${CURRENT_QT_VERSION} is sufficient (>= ${QBT_QT_MINIMUM})."
    fi
  else
    NEED_QT6_SWIZZIN=1
    NEED_ZLIB_NG=1
    QT_METHOD="swizzin"
    warn "Qt ${CURRENT_QT_VERSION:-missing} < ${QBT_QT_MINIMUM}. Planned: install qt6-swizzin (+ zlib-ng) — NO Qt source compilation."
  fi

  if [[ -z "${CURRENT_CMAKE_VERSION}" ]] || version_lt "${CURRENT_CMAKE_VERSION}" "${CMAKE_MIN_VERSION}"; then
    NEED_CMAKE_SWIZZIN=1
    warn "CMake ${CURRENT_CMAKE_VERSION:-missing} < ${CMAKE_MIN_VERSION} → cmake-swizzin planned."
  else
    PLANNED_PACKAGES+=(cmake)
  fi

  if [[ -z "${CURRENT_NINJA_VERSION}" ]]; then
    PLANNED_PACKAGES+=(ninja-build)
  fi

  local branch="${LIBTORRENT_BRANCH_OVERRIDE:-${QBT_LIBTORRENT_BRANCH_DEFAULT}}"
  local lt_needed="${QBT_LIBTORRENT_MINIMUM}"
  if [[ "${branch}" == "RC_2_0" ]]; then
    lt_needed="${QBT_LIBTORRENT2_MINIMUM}"
  elif [[ -n "${CURRENT_LIBTORRENT_VERSION}" && "${CURRENT_LIBTORRENT_VERSION}" =~ ^2\. ]]; then
    lt_needed="${QBT_LIBTORRENT2_MINIMUM}"
  fi

  if [[ -n "${CURRENT_LIBTORRENT_VERSION}" ]] \
     && version_ge "${CURRENT_LIBTORRENT_VERSION}" "${lt_needed}" \
     && [[ -f /usr/local/lib/libtorrent-rasterbar.a ]]; then
    if dpkg -s libtorrent-rasterbar 2>/dev/null | grep -q "${QBT_STDCVER}"; then
      NEED_LIBTORRENT_BUILD=0
      ok "Existing static libtorrent ${CURRENT_LIBTORRENT_VERSION} is compatible (>= ${lt_needed}, ${QBT_STDCVER}) — will be reused."
    else
      NEED_LIBTORRENT_BUILD=1
      warn "libtorrent present, but C++ standard tag (${QBT_STDCVER}) not confirmed → rebuild planned (${branch})."
    fi
  else
    NEED_LIBTORRENT_BUILD=1
    info "libtorrent build planned (branch ${branch}, minimum ${lt_needed})."
  fi

  NEED_BOOST=1
  BOOST_VERSION="$(pick_boost_version_for_minimum "${QBT_BOOST_MINIMUM}")"
  BOOST_ROOT_DIR="/opt/boost_${BOOST_VERSION}"
  info "Boost target: ${BOOST_VERSION} (minimum from source: ${QBT_BOOST_MINIMUM})"

  if command -v fpm >/dev/null 2>&1; then
    FPM_AVAILABLE=1
  else
    FPM_AVAILABLE=0
    info "fpm missing — will be installed via gem (same as Swizzin install_fpm)."
  fi
}

github_latest_tag() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))"
}

# -----------------------------------------------------------------------------
# Dry-run report
# -----------------------------------------------------------------------------
print_dry_run_report() {
  local backup_preview="${BACKUP_ROOT_BASE}/qbittorrent-upgrade-backup-YYYY-MM-DD-HHMMSS/"
  SOURCE_DIR="${WORK_ROOT}/src/qBittorrent-release-${TARGET_VERSION}"
  BUILD_DIR="${SOURCE_DIR}/build"
  STAGE_DIR="${WORK_ROOT}/stage/qbittorrent"

  cat <<EOF

========== DRY-RUN / PLAN ==========
Debian:              ${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME})
Architecture:        ${OS_ARCH} / ${DPKG_ARCH}
qBittorrent current: ${CURRENT_QBT_VERSION}
qBittorrent target:  ${TARGET_VERSION} (series ${SERIES}.x, stable)
Requirements from:   ${REQUIREMENTS_SOURCE:-not resolved yet}$([[ ${REQUIREMENTS_RESOLVED} -eq 1 ]] && echo " (upstream)" || echo " (fallback)")
libtorrent current:  ${CURRENT_LIBTORRENT_VERSION:-unknown}
libtorrent minimum:  1.x>=${QBT_LIBTORRENT_MINIMUM} / 2.x>=${QBT_LIBTORRENT2_MINIMUM} (branch ${LIBTORRENT_BRANCH_OVERRIDE:-${QBT_LIBTORRENT_BRANCH_DEFAULT}})
libtorrent action:   $([[ ${NEED_LIBTORRENT_BUILD} -eq 1 ]] && echo "build+package" || echo "reuse")
Qt current:          ${CURRENT_QT_VERSION:-unknown} (minimum ${QBT_QT_MINIMUM} from source)
Qt method:           ${QT_METHOD}$([[ ${NEED_QT6_SWIZZIN} -eq 1 ]] && echo " → qt6-swizzin DEB (NO Qt source compilation)" || true)
CMake:               ${CURRENT_CMAKE_VERSION:-unknown} (minimum ${CMAKE_MIN_VERSION})$([[ ${NEED_CMAKE_SWIZZIN} -eq 1 ]] && echo " → cmake-swizzin" || true)
Ninja:               ${CURRENT_NINJA_VERSION:-unknown}
Boost:               ${BOOST_VERSION} → ${BOOST_ROOT_DIR} (minimum ${QBT_BOOST_MINIMUM})
OpenSSL:             ${OPENSSL_VERSION_FOUND:-unknown} (minimum ${QBT_OPENSSL_MINIMUM})
C++ standard:        ${QBT_STDCVER} (from upstream CommonConfig/CMake)
Build type:          CMake + Ninja, GUI=OFF (qbittorrent-nox), headless
Source directory:    ${SOURCE_DIR}
Build directory:     ${BUILD_DIR}
Staging:             ${STAGE_DIR}
Install path:        /usr (via Debian package qbittorrent-nox, as in Swizzin)
Package output:      ${DIST_DIR}/qbittorrent-nox_${TARGET_VERSION}_*.deb
Backup path:         ${backup_preview}
Log file:            ${LOG_FILE}
Services found:      ${SERVICE_UNITS[*]:-none}
Services active:     ${PREVIOUSLY_ACTIVE_SERVICES[*]:-none}
Configurations:      ${CONFIG_PATHS[*]:-none}
Swizzin reference:   ${SWIZZIN_QBT_FUNC:-not present (standalone)}

Planned APT packages (excerpt):
  ${PLANNED_PACKAGES[*]}

Planned changes:
  - Backup configuration, systemd status, package list, optional dpkg-repack of qbittorrent-nox
  - Controlled stop of previously active qbittorrent services
  - Install build dependencies (no apt remove/purge of qbittorrent)
  - $([[ ${NEED_QT6_SWIZZIN} -eq 1 ]] && echo "install qt6-swizzin + zlib-ng DEBs" || echo "reuse existing Qt")
  - $([[ ${NEED_LIBTORRENT_BUILD} -eq 1 ]] && echo "build static libtorrent-rasterbar and install as DEB" || echo "reuse libtorrent")
  - Build qBittorrent ${TARGET_VERSION} from official source (GUI=OFF)
  - Create fpm package qbittorrent-nox_${TARGET_VERSION}_*.deb and install via dpkg -i
  - apt-mark hold qbittorrent-nox (Swizzin behaviour)
  - Restart previously active services; leave inactive ones stopped
  - Check WebUI reachability locally
  - nginx: backup ${NGINX_QBT_CONF} → ${NGINX_QBT_CONF_ORIG} (cp), then write 5.2.x proxy config
  - Per user: cp ~/.config/qBittorrent/qBittorrent.conf → qBittorrent.conf.orig (before qBittorrent build)
  - DO NOT change WebUI passwords in qBittorrent.conf
  - DO NOT modify /etc/swizzin (except the nginx app file under /etc/nginx/apps/)
=======================================
EOF

  emit_webui_notes
}

emit_webui_notes() {
  cat <<'EOF'

[NOTE] qBittorrent 5.2.x WebUI / reverse proxy:
  - This script adapts /etc/nginx/apps/qbittorrent.conf for 5.2.x (strip Authorization header,
    add forwarded headers). Original: /etc/nginx/apps/qbittorrent.conf.orig
  - Additionally recommended (manual, per user) if not already set:
      WebUI\TrustedReverseProxiesList=127.0.0.1
    in ~/.config/qBittorrent/qBittorrent.conf
  - Existing username/password/WebUI settings in qBittorrent.conf are NOT overwritten.
EOF
}

# -----------------------------------------------------------------------------
# Backup / rollback metadata
# -----------------------------------------------------------------------------
create_backup() {
  local stamp
  stamp="$(date '+%Y-%m-%d-%H%M%S')"
  BACKUP_DIR="${BACKUP_ROOT_BASE}/qbittorrent-upgrade-backup-${stamp}"
  STATE_FILE="${BACKUP_DIR}/upgrade-state.env"

  info "Creating backup under ${BACKUP_DIR}…"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "DRY-RUN: backup would be written to ${BACKUP_DIR}."
    return 0
  fi

  mkdir -p "${BACKUP_DIR}/config" "${BACKUP_DIR}/systemd" "${BACKUP_DIR}/packages" "${BACKUP_DIR}/bin" "${BACKUP_DIR}/nginx"

  if [[ -f "${NGINX_QBT_CONF}" ]]; then
    cp -a -- "${NGINX_QBT_CONF}" "${BACKUP_DIR}/nginx/qbittorrent.conf"
    info "nginx config copied into backup: ${NGINX_QBT_CONF}"
  fi

  {
    echo "BACKUP_CREATED=$(_ts)"
    echo "PREV_QBT_VERSION=${CURRENT_QBT_VERSION}"
    echo "PREV_QBT_PACKAGE=${QBT_PACKAGE_VERSION}"
    echo "PREV_LIBTORRENT=${CURRENT_LIBTORRENT_VERSION}"
    echo "PREV_QT=${CURRENT_QT_VERSION}"
    echo "TARGET_VERSION=${TARGET_VERSION}"
    echo "OS=${OS_ID} ${OS_VERSION_ID} ${OS_CODENAME} ${DPKG_ARCH}"
  } > "${BACKUP_DIR}/VERSIONS.txt"

  dpkg -l > "${BACKUP_DIR}/packages/dpkg-l.txt" 2>/dev/null || true
  dpkg-query -W > "${BACKUP_DIR}/packages/dpkg-query-W.txt" 2>/dev/null || true
  if dpkg -s qbittorrent-nox >/dev/null 2>&1; then
    dpkg -s qbittorrent-nox > "${BACKUP_DIR}/packages/qbittorrent-nox.status" 2>/dev/null || true
  fi
  if dpkg -s libtorrent-rasterbar >/dev/null 2>&1; then
    dpkg -s libtorrent-rasterbar > "${BACKUP_DIR}/packages/libtorrent-rasterbar.status" 2>/dev/null || true
  fi

  # Save binary for emergency rollback if dpkg-repack fails
  if [[ -n "${QBT_BINARY}" && -x "${QBT_BINARY}" ]]; then
    cp -a -- "${QBT_BINARY}" "${BACKUP_DIR}/bin/qbittorrent-nox.prev" || true
  fi

  # dpkg-repack for clean rollback
  if command -v dpkg-repack >/dev/null 2>&1 && dpkg -s qbittorrent-nox >/dev/null 2>&1; then
    info "Creating rollback package via dpkg-repack…"
    ( cd "${BACKUP_DIR}/packages" && dpkg-repack qbittorrent-nox ) >> "${LOG_FILE}" 2>&1 \
      || warn "dpkg-repack qbittorrent-nox failed — binary backup remains available."
  else
    warn "dpkg-repack not available. Optional: apt-get install -y dpkg-repack"
    # Try copy existing swizzin dist deb
    local olddeb
    olddeb="$(ls -1t "${DIST_DIR}"/qbittorrent-nox_"${CURRENT_QBT_VERSION}"_*.deb 2>/dev/null | head -n1 || true)"
    if [[ -n "${olddeb}" ]]; then
      cp -a -- "${olddeb}" "${BACKUP_DIR}/packages/" || true
      info "Copied existing dist package: ${olddeb}"
    fi
  fi

  local conf
  for conf in "${CONFIG_PATHS[@]+"${CONFIG_PATHS[@]}"}"; do
    local dest
    dest="${BACKUP_DIR}/config/$(echo "${conf}" | sed 's#^/##; s#/#_#g')"
    mkdir -p "${dest}"
    cp -a -- "${conf}/." "${dest}/" || warn "Could not copy config: ${conf}"
  done

  local unit
  for unit in "${SERVICE_UNITS[@]+"${SERVICE_UNITS[@]}"}"; do
    systemctl status "${unit}" --no-pager -l > "${BACKUP_DIR}/systemd/${unit}.status.txt" 2>&1 || true
    systemctl cat "${unit}" > "${BACKUP_DIR}/systemd/${unit}.unit.txt" 2>&1 || true
    systemctl is-enabled "${unit}" > "${BACKUP_DIR}/systemd/${unit}.enabled" 2>&1 || true
    systemctl is-active "${unit}" > "${BACKUP_DIR}/systemd/${unit}.active" 2>&1 || true
  done
  printf '%s\n' "${PREVIOUSLY_ACTIVE_SERVICES[@]+"${PREVIOUSLY_ACTIVE_SERVICES[@]}"}" \
    > "${BACKUP_DIR}/systemd/previously-active.txt"

  {
    echo "BACKUP_DIR=${BACKUP_DIR}"
    echo "PREV_QBT_VERSION=${CURRENT_QBT_VERSION}"
    echo "TARGET_VERSION=${TARGET_VERSION}"
  } > "${STATE_FILE}"

  # Pointer to latest backup for --rollback
  ln -sfn "${BACKUP_DIR}" "${BACKUP_ROOT_BASE}/qbittorrent-upgrade-backup-latest"

  ok "Backup created: ${BACKUP_DIR}"
}

find_latest_backup() {
  local latest="${BACKUP_ROOT_BASE}/qbittorrent-upgrade-backup-latest"
  if [[ -L "${latest}" || -d "${latest}" ]]; then
    readlink -f "${latest}"
    return 0
  fi
  ls -1dt "${BACKUP_ROOT_BASE}"/qbittorrent-upgrade-backup-* 2>/dev/null | head -n1 || true
}

do_rollback() {
  require_root
  _ensure_log
  info "Starting rollback…"
  local backup
  backup="$(find_latest_backup)"
  [[ -n "${backup}" && -d "${backup}" ]] || die "No backup found under ${BACKUP_ROOT_BASE}/qbittorrent-upgrade-backup-*"

  info "Using backup: ${backup}"
  confirm "Roll back to the state in ${backup}?"

  # Stop current services
  probe_services
  local unit
  for unit in "${SERVICE_UNITS[@]+"${SERVICE_UNITS[@]}"}"; do
    if systemctl is-active --quiet "${unit}" 2>/dev/null; then
      run_cmd systemctl stop "${unit}"
    fi
  done

  local deb
  deb="$(ls -1t "${backup}/packages"/qbittorrent-nox_*.deb 2>/dev/null | head -n1 || true)"
  if [[ -n "${deb}" ]]; then
    info "Installing rollback package: ${deb}"
    run_cmd dpkg -i "${deb}"
  elif [[ -x "${backup}/bin/qbittorrent-nox.prev" ]]; then
    warn "No .deb in backup — restoring binary as emergency fallback."
    local target_bin="/usr/bin/qbittorrent-nox"
    run_cmd cp -a -- "${backup}/bin/qbittorrent-nox.prev" "${target_bin}"
  else
    die "Neither .deb nor binary found in backup — rollback not possible."
  fi

  # Restore configs ONLY if current configs missing critical files — never overwrite newer passwords blindly.
  # We restore from backup only files that user confirms or if --yes: restore entire tree carefully.
  info "Configuration: backup is under ${backup}/config/ — existing live configs will NOT be overwritten."
  info "Compare/copy manually if needed. Passwords/WebUI settings are preserved."

  # Restore nginx qbittorrent app config
  if [[ -f "${NGINX_QBT_CONF_ORIG}" ]]; then
    info "Restoring nginx config from ${NGINX_QBT_CONF_ORIG}…"
    run_cmd cp -a -- "${NGINX_QBT_CONF_ORIG}" "${NGINX_QBT_CONF}"
    if command -v nginx >/dev/null 2>&1; then
      run_cmd nginx -t
      run_cmd systemctl reload nginx
    fi
  elif [[ -f "${backup}/nginx/qbittorrent.conf" ]]; then
    info "Restoring nginx config from backup…"
    run_cmd cp -a -- "${backup}/nginx/qbittorrent.conf" "${NGINX_QBT_CONF}"
    if command -v nginx >/dev/null 2>&1; then
      run_cmd nginx -t
      run_cmd systemctl reload nginx
    fi
  else
    warn "No nginx qbittorrent.conf available to restore."
  fi

  # Restart previously active
  if [[ -f "${backup}/systemd/previously-active.txt" ]]; then
    while IFS= read -r unit; do
      [[ -n "${unit}" ]] || continue
      run_cmd systemctl start "${unit}"
      run_cmd --allow-fail systemctl --no-pager --full status "${unit}" || true
    done < "${backup}/systemd/previously-active.txt"
  fi

  local ver
  ver="$(qbittorrent-nox --version 2>/dev/null || true)"
  ok "Rollback complete. Version: ${ver}"
}

# -----------------------------------------------------------------------------
# nginx reverse proxy for qBittorrent 5.2.x (Swizzin multi-user)
# -----------------------------------------------------------------------------
write_nginx_qbittorrent_52_conf() {
  local dest="$1"
  cat > "${dest}" <<'QBTNGINX'
location /qbt {
    return 301 /qbittorrent/;
}
location /qbittorrent/ {
    # Multi-user: panel user → upstream user.qbittorrent (127.0.0.1:WEBUI-PORT)
    proxy_pass         http://$remote_user.qbittorrent;
    proxy_http_version 1.1;
    proxy_set_header Host              $http_host;
    proxy_set_header X-Forwarded-Host  $http_host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    # qBittorrent 5.2.x validates Basic Auth itself.
    # Panel auth (/etc/htpasswd) must NOT be forwarded to the instance,
    # or you get "Unauthorized" when panel password ≠ that user's WebUI password.
    proxy_set_header Authorization "";
    # Optional only if panel password === qBittorrent WebUI password (per user):
    # remove the Authorization "" line for SSO-like Basic Auth passthrough.
    http2_push_preload on;
    auth_basic           "What's the password?";
    auth_basic_user_file /etc/htpasswd;
    rewrite ^/qbittorrent/(.*) /$1 break;
    proxy_cookie_path / "/qbittorrent/; Secure";
    proxy_buffering off;
    proxy_read_timeout 600s;
}
QBTNGINX
}

apply_nginx_qbittorrent_52() {
  info "Updating nginx reverse proxy for qBittorrent 5.2.x…"

  if [[ ! -f "${NGINX_QBT_CONF}" ]]; then
    warn "${NGINX_QBT_CONF} not found — skipping nginx adaptation."
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "DRY-RUN: would copy ${NGINX_QBT_CONF} to ${NGINX_QBT_CONF_ORIG} and write 5.2.x config."
    return 0
  fi

  # Preserve the original only once so re-runs do not overwrite the true original
  if [[ ! -f "${NGINX_QBT_CONF_ORIG}" ]]; then
    info "Backup (cp): ${NGINX_QBT_CONF} → ${NGINX_QBT_CONF_ORIG}"
    run_cmd cp -a -- "${NGINX_QBT_CONF}" "${NGINX_QBT_CONF_ORIG}"
  else
    info "${NGINX_QBT_CONF_ORIG} already exists — will not overwrite."
    # Still create a timestamped backup of the current file if it was already modified
    run_cmd cp -a -- "${NGINX_QBT_CONF}" "${NGINX_QBT_CONF}.bak.$(date '+%Y%m%d-%H%M%S')"
  fi

  # Also copy into the upgrade backup if create_backup ran earlier
  if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
    mkdir -p "${BACKUP_DIR}/nginx"
    if [[ -f "${NGINX_QBT_CONF_ORIG}" ]]; then
      cp -a -- "${NGINX_QBT_CONF_ORIG}" "${BACKUP_DIR}/nginx/qbittorrent.conf.orig" || true
    fi
  fi

  write_nginx_qbittorrent_52_conf "${NGINX_QBT_CONF}"
  ok "nginx config written: ${NGINX_QBT_CONF}"

  if command -v nginx >/dev/null 2>&1; then
    run_cmd nginx -t
    run_cmd systemctl reload nginx
    ok "nginx reloaded."
  else
    warn "nginx binary not found — config written, but not reloaded."
  fi
}

# -----------------------------------------------------------------------------
# Per-user backup: qBittorrent.conf → qBittorrent.conf.orig
# -----------------------------------------------------------------------------
backup_user_qbittorrent_confs() {
  info "Backing up each user's qBittorrent.conf to qBittorrent.conf.orig…"

  if [[ ${#CONFIG_PATHS[@]} -eq 0 ]]; then
    warn "No qBittorrent config directories found — skipping user config backup."
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    local conf_dir
    for conf_dir in "${CONFIG_PATHS[@]}"; do
      local conf_file="${conf_dir}/qBittorrent.conf"
      local orig_file="${conf_dir}/qBittorrent.conf.orig"
      if [[ -f "${conf_file}" ]]; then
        info "DRY-RUN: would cp -a ${conf_file} → ${orig_file}"
      fi
    done
    return 0
  fi

  local conf_dir conf_file orig_file count=0
  for conf_dir in "${CONFIG_PATHS[@]}"; do
    conf_file="${conf_dir}/qBittorrent.conf"
    orig_file="${conf_dir}/qBittorrent.conf.orig"

    if [[ ! -f "${conf_file}" ]]; then
      info "No qBittorrent.conf in ${conf_dir} — skipped."
      continue
    fi

    # Preserve live config ownership/permissions on .orig
    local conf_owner conf_group
    conf_owner="$(stat -c '%u' "${conf_file}" 2>/dev/null || true)"
    conf_group="$(stat -c '%g' "${conf_file}" 2>/dev/null || true)"

    if [[ ! -f "${orig_file}" ]]; then
      info "Backup (cp): ${conf_file} → ${orig_file}"
      run_cmd cp -a -- "${conf_file}" "${orig_file}"
    else
      info "${orig_file} already exists — original left intact."
      local stamped="${conf_file}.bak.$(date '+%Y%m%d-%H%M%S')"
      run_cmd cp -a -- "${conf_file}" "${stamped}"
      info "Additional backup: ${stamped}"
    fi

    # Ensure .orig belongs to the config owner (not root-only)
    if [[ -f "${orig_file}" && -n "${conf_owner}" && -n "${conf_group}" ]]; then
      chown "${conf_owner}:${conf_group}" -- "${orig_file}" 2>/dev/null || true
    fi

    # Also copy into the central upgrade backup
    if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
      local dest_name
      dest_name="$(echo "${conf_file}" | sed 's#^/##; s#/#_#g')"
      mkdir -p "${BACKUP_DIR}/config-orig"
      cp -a -- "${orig_file}" "${BACKUP_DIR}/config-orig/${dest_name}.orig" 2>/dev/null || true
    fi

    count=$((count + 1))
  done

  ok "User config backups complete (${count} file(s))."
}

# -----------------------------------------------------------------------------
# Service control
# -----------------------------------------------------------------------------
stop_active_services() {
  STOPPED_SERVICES=()
  local unit
  for unit in "${PREVIOUSLY_ACTIVE_SERVICES[@]+"${PREVIOUSLY_ACTIVE_SERVICES[@]}"}"; do
    info "Stopping service: ${unit}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      continue
    fi
    systemctl stop "${unit}" >> "${LOG_FILE}" 2>&1 || die "Could not stop ${unit}."
    STOPPED_SERVICES+=("${unit}")
  done
}

start_previous_services() {
  local unit
  for unit in "${PREVIOUSLY_ACTIVE_SERVICES[@]+"${PREVIOUSLY_ACTIVE_SERVICES[@]}"}"; do
    info "Starting previously active service: ${unit}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      continue
    fi
    systemctl start "${unit}" >> "${LOG_FILE}" 2>&1 || die "Could not start ${unit}."
    systemctl --no-pager --full status "${unit}" >> "${LOG_FILE}" 2>&1 || warn "Status of ${unit} is not clean."
    STARTED_SERVICES+=("${unit}")
  done
  if [[ ${#PREVIOUSLY_ACTIVE_SERVICES[@]} -eq 0 ]]; then
    info "No qBittorrent service was running before the upgrade — none will be started automatically."
  fi
}

# -----------------------------------------------------------------------------
# Build dependency installation
# -----------------------------------------------------------------------------
maybe_remount_tmp_exec() {
  if grep -E '[[:space:]]/tmp[[:space:]]' /etc/fstab 2>/dev/null | grep -q noexec; then
    info "/tmp is mounted noexec — remounting exec for build…"
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      mount -o remount,exec /tmp >> "${LOG_FILE}" 2>&1 || die "Failed to remount /tmp as exec."
      TMP_MOUNTED_EXEC=1
    fi
  fi
}

apt_install_packages() {
  info "Installing build dependencies via apt…"
  # Resolve wildcards carefully for libstdc++ / libicu without blind remove
  local pkgs=()
  local p
  for p in "${PLANNED_PACKAGES[@]}"; do
    pkgs+=("${p}")
  done
  # Add matching libstdc++-*-dev (newest available)
  local stdcpp
  stdcpp="$(apt-cache search --names-only '^libstdc\+\+-[0-9]+-dev$' 2>/dev/null | awk '{print $1}' | sort -V | tail -n1 || true)"
  if [[ -n "${stdcpp}" ]]; then
    pkgs+=("${stdcpp}")
  fi
  local icu
  icu="$(apt-cache search --names-only '^libicu[0-9]+$' 2>/dev/null | awk '{print $1}' | sort -V | tail -n1 || true)"
  if [[ -n "${icu}" ]]; then
    pkgs+=("${icu}")
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "DRY-RUN apt packages: ${pkgs[*]}"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  run_cmd apt-get update -y
  run_cmd apt-get install -y --no-install-recommends "${pkgs[@]}"
  if [[ "${FPM_AVAILABLE}" -eq 0 ]]; then
    info "Installing fpm via gem…"
    run_cmd gem install fpm
  fi
  # Optional dpkg-repack for better backups next time
  run_cmd --allow-fail apt-get install -y --no-install-recommends dpkg-repack || true
}

install_swizzin_crossbuild_deb() {
  local repo="$1"
  local pkg_name="$2"   # e.g. qt6-swizzin
  local asset_suffix="$3" # e.g. qt6-swizzin

  local tag
  tag="$(github_latest_tag "${repo}")"
  [[ -n "${tag}" ]] || die "Could not determine latest release of ${repo}."

  local distro="debian"
  local codename="${OS_CODENAME}"
  local arch="${DPKG_ARCH}"
  # Swizzin asset naming: debian-bookworm-qt6-swizzin-amd64.deb
  local asset="${distro}-${codename}-${asset_suffix}-${arch}.deb"
  local url="https://github.com/${repo}/releases/download/${tag}/${asset}"
  local dest="${WORK_ROOT}/debs/${asset}"

  info "Downloading ${pkg_name} ${tag}: ${url}"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  mkdir -p "${WORK_ROOT}/debs"
  register_cleanup "${WORK_ROOT}/debs"
  run_cmd curl -fL --retry 3 -o "${dest}" "${url}"
  run_cmd dpkg -i "${dest}"
  ok "${pkg_name} installed (${tag})"
}

ensure_qt() {
  if [[ "${NEED_QT6_SWIZZIN}" -eq 1 ]]; then
    warn "=== NOTICE: installing qt6-swizzin (prebuilt Swizzin package, no Qt source compilation). ==="
    if [[ "${NEED_ZLIB_NG}" -eq 1 ]]; then
      install_swizzin_crossbuild_deb "${ZLIB_NG_CROSSBUILD_REPO}" "zlib-ng" "zlib-ng"
    fi
    install_swizzin_crossbuild_deb "${QT6_CROSSBUILD_REPO}" "qt6-swizzin" "qt6-swizzin"
    QT_METHOD="swizzin"
  else
    if [[ "${QT_METHOD}" == "repo" ]]; then
      info "Ensuring repository Qt6 packages…"
      if [[ "${DRY_RUN}" -eq 0 ]]; then
        run_cmd apt-get install -y --no-install-recommends \
          qt6-base-dev qt6-tools-dev qt6-l10n-tools qt6-tools-dev-tools qt6-base-private-dev
      fi
    fi
  fi
}

ensure_cmake_swizzin() {
  if [[ "${NEED_CMAKE_SWIZZIN}" -eq 1 ]]; then
    install_swizzin_crossbuild_deb "${CMAKE_CROSSBUILD_REPO}" "cmake-swizzin" "cmake-swizzin"
  fi
}

ensure_boost() {
  if [[ "${NEED_BOOST}" -ne 1 ]]; then
    return 0
  fi
  BOOST_ROOT_DIR="/opt/boost_${BOOST_VERSION}"
  export BOOST_ROOT="${BOOST_ROOT_DIR}"
  export BOOST_INCLUDEDIR="${BOOST_ROOT_DIR}"
  export BOOST_BUILD_PATH="${BOOST_ROOT_DIR}"

  if [[ -d "${BOOST_ROOT_DIR}" ]]; then
    ok "Boost already present: ${BOOST_ROOT_DIR}"
    return 0
  fi
  info "Installing Boost ${BOOST_VERSION} to ${BOOST_ROOT_DIR} (Swizzin booststrap)…"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi

  local ver_dot="${BOOST_VERSION//_/.}"
  local tarball="boost_${BOOST_VERSION}.tar.gz"
  local urls=(
    "https://archives.boost.io/release/${ver_dot}/source/${tarball}"
    "https://boostorg.jfrog.io/artifactory/main/release/${ver_dot}/source/${tarball}"
    "https://deac-ams.dl.sourceforge.net/project/boost/boost/${ver_dot}/${tarball}"
  )
  mkdir -p /opt
  local url ok_dl=0
  for url in "${urls[@]}"; do
    info "Boost download attempt: ${url}"
    if curl -fL --retry 2 -o "/opt/${tarball}" "${url}" >> "${LOG_FILE}" 2>&1; then
      ok_dl=1
      break
    fi
  done
  [[ "${ok_dl}" -eq 1 ]] || die "Boost download failed."
  tar -xzf "/opt/${tarball}" -C /opt >> "${LOG_FILE}" 2>&1
  rm -f "/opt/${tarball}"
  (
    cd "${BOOST_ROOT_DIR}"
    ./bootstrap.sh --with-libraries=system >> "${LOG_FILE}" 2>&1
  ) || die "Boost bootstrap failed."
  ok "Boost installed: ${BOOST_ROOT_DIR}"
}

# -----------------------------------------------------------------------------
# libtorrent build (Swizzin build_libtorrent_qbittorrent, cmake path)
# -----------------------------------------------------------------------------
build_libtorrent_if_needed() {
  if [[ "${NEED_LIBTORRENT_BUILD}" -ne 1 ]]; then
    info "Skipping libtorrent build (compatible version present)."
    return 0
  fi

  local branch="${LIBTORRENT_BRANCH_OVERRIDE:-${QBT_LIBTORRENT_BRANCH_DEFAULT}}"
  info "Building static libtorrent (${branch}) — Swizzin procedure…"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi

  local lt_dir="${WORK_ROOT}/src/libtorrent"
  local lt_stage="${WORK_ROOT}/stage/libtorrent"
  mkdir -p "${WORK_ROOT}/src"
  if [[ -e "${lt_dir}" ]]; then
    safe_rm_path "${lt_dir}" || die "Could not remove old libtorrent work directory: ${lt_dir}"
  fi
  if [[ -e "${lt_stage}" ]]; then
    safe_rm_path "${lt_stage}" || die "Could not remove old libtorrent staging directory: ${lt_stage}"
  fi
  mkdir -p "${lt_stage}"
  register_cleanup "${lt_dir}"
  register_cleanup "${lt_stage}"

  # Resolve latest tag for 1.2 or 2.0 series (Swizzin libtorrent_clone)
  local tag_prefix
  case "${branch}" in
    RC_1_2) tag_prefix="v1.2" ;;
    RC_2_0) tag_prefix="v2.0" ;;
    *) die "Invalid libtorrent branch: ${branch}" ;;
  esac
  local tags_list tag
  tags_list="$(git ls-remote -q -t --refs "${LIBTORRENT_REPO_URL}" \
    | awk '{print $2}' | sed 's#refs/tags/##' \
    | grep -E "^${tag_prefix}\.[0-9]+$" | sort -Vr || true)"
  tag="$(printf '%s\n' "${tags_list}" | head -n1)"
  [[ -n "${tag}" ]] || die "Could not resolve libtorrent tag for ${branch}."
  info "libtorrent tag: ${tag}"

  run_cmd git clone --no-tags --single-branch --branch "${tag}" \
    --shallow-submodules --recurse-submodules -j"$(nproc)" --depth 1 \
    "${LIBTORRENT_REPO_URL}" "${lt_dir}"

  if [[ -f "/root/libtorrent-${branch}.patch" ]]; then
    info "Applying patch /root/libtorrent-${branch}.patch…"
    ( cd "${lt_dir}" && patch -p1 < "/root/libtorrent-${branch}.patch" ) >> "${LOG_FILE}" 2>&1 \
      || die "libtorrent patch failed."
  fi

  local cxx_num="${QBT_STDCVER//[^0-9]/}"
  export CFLAGS="${CFLAGS:--O3 -march=native}"
  export CXXFLAGS="${CXXFLAGS:--O3 -march=native}"
  export PATH="/opt/local/bin:${PATH}"

  (
    cd "${lt_dir}"
    cmake -Wno-dev -Wno-deprecated -G Ninja -B build \
      -D CMAKE_BUILD_TYPE="Release" \
      -D CMAKE_CXX_STANDARD="${cxx_num}" \
      -D BOOST_INCLUDEDIR="${BOOST_ROOT_DIR}" \
      -D BUILD_SHARED_LIBS=OFF \
      -D CMAKE_CXX_FLAGS="${CXXFLAGS}" \
      -D CMAKE_C_FLAGS="${CFLAGS}" \
      -D CMAKE_INSTALL_PREFIX="${lt_stage}/usr/local"
    cmake --build build
    cmake --install build
  ) >> "${LOG_FILE}" 2>&1 || die "libtorrent cmake/build/install failed — see ${LOG_FILE}"

  # Fix pkgconfig paths (Swizzin)
  local pc="${lt_stage}/usr/local/lib/pkgconfig/libtorrent-rasterbar.pc"
  if [[ -f "${pc}" ]]; then
    sed -i "s|${lt_stage}||g" "${pc}"
    sed -i 's|-ltorrent-rasterbar|-l:libtorrent-rasterbar.a|g' "${pc}"
  fi

  local version
  version="$(grep -oE 'VERSION = [0-9]+\.[0-9]+\.[0-9]+' "${lt_dir}/Jamfile" 2>/dev/null | awk '{print $3}' || true)"
  if [[ -z "${version}" ]]; then
    version="$(printf '%s' "${tag}" | sed 's/^v//')"
  fi

  mkdir -p "${DIST_DIR}"
  local tagdesc=" static with ${QBT_STDCVER} O3 march=native"
  (
    fpm -f -C "${lt_stage}" -p "${DIST_DIR}/libtorrent-rasterbar_VERSION.deb" \
      -s dir -t deb -n libtorrent-rasterbar --version "${version}" \
      --description "Libtorrent rasterbar compiled by qbittorrent-5.2-upgrade${tagdesc}"
  ) >> "${LOG_FILE}" 2>&1 || die "fpm libtorrent failed."

  local lt_deb
  lt_deb="$(ls -1t "${DIST_DIR}"/libtorrent-rasterbar_"${version}"*.deb 2>/dev/null | head -n1)"
  [[ -n "${lt_deb}" ]] || die "libtorrent .deb not found."
  run_cmd dpkg -i "${lt_deb}"
  ok "libtorrent-rasterbar ${version} installed"
}

# -----------------------------------------------------------------------------
# qBittorrent build
# -----------------------------------------------------------------------------
verify_cmake_options_from_source() {
  local src="$1"
  info "Verifying CMake options in source tree ${TARGET_VERSION}…"
  local cmakelists="${src}/CMakeLists.txt"
  [[ -f "${cmakelists}" ]] || die "CMakeLists.txt fehlt in ${src}"

  if ! grep -q 'feature_option(GUI' "${cmakelists}"; then
    die "CMake option GUI is unexpectedly missing in ${TARGET_VERSION}."
  fi
  ok "CMake option GUI exists."

  if grep -qE 'feature_option\(QT6|option\(QT6' "${cmakelists}" \
     || grep -rqE 'option\(QT6|feature_option\(QT6' "${src}/cmake" 2>/dev/null; then
    info "CMake option QT6 exists in this source — will be set (Swizzin-compatible)."
    echo "HAS_QT6=1"
  else
    # qBittorrent 5.2.x is Qt6-only; Swizzin still passes -D QT6=ON but it is unused.
    info "CMake option QT6 does NOT exist in ${TARGET_VERSION} (Qt6-only). Parameter omitted (no invented flags)."
    echo "HAS_QT6=0"
  fi

  local min_qt
  min_qt="$(grep -E 'set\(minQt6Version|set\(minQtVersion' "${cmakelists}" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
  if [[ -n "${min_qt}" ]]; then
    info "Source minQt version=${min_qt} (planned minimum was ${QBT_QT_MINIMUM})"
  fi
}

build_qbittorrent() {
  info "Downloading qBittorrent source release-${TARGET_VERSION}…"
  SOURCE_DIR="${WORK_ROOT}/src/qBittorrent-release-${TARGET_VERSION}"
  BUILD_DIR="${SOURCE_DIR}/build"
  STAGE_DIR="${WORK_ROOT}/stage/qbittorrent"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "DRY-RUN: would download source to ${SOURCE_DIR} and stage to ${STAGE_DIR}."
    return 0
  fi

  mkdir -p "${WORK_ROOT}/src" "${STAGE_DIR}" "${DIST_DIR}"
  register_cleanup "${SOURCE_DIR}"
  register_cleanup "${STAGE_DIR}"

  local tarball="${WORK_ROOT}/src/release-${TARGET_VERSION}.tar.gz"
  run_cmd curl -fL --retry 3 -o "${tarball}" \
    "https://github.com/qbittorrent/qBittorrent/archive/release-${TARGET_VERSION}.tar.gz"

  if [[ -e "${SOURCE_DIR}" ]]; then
    safe_rm_path "${SOURCE_DIR}" || die "Could not remove old source directory: ${SOURCE_DIR}"
  fi
  mkdir -p "${SOURCE_DIR}"
  tar -xzf "${tarball}" -C "${SOURCE_DIR}" --strip-components=1 >> "${LOG_FILE}" 2>&1 \
    || die "Failed to extract qBittorrent source."
  rm -f -- "${tarball}"

  local has_qt6_line has_qt6=0
  has_qt6_line="$(verify_cmake_options_from_source "${SOURCE_DIR}" | tail -n1)"
  if [[ "${has_qt6_line}" == "HAS_QT6=1" ]]; then
    has_qt6=1
  fi

  export CFLAGS="${CFLAGS:--O3 -march=native}"
  export CXXFLAGS="${CXXFLAGS:--O3 -march=native}"
  export PATH="/opt/local/bin:${PATH}"
  export BOOST_ROOT="${BOOST_ROOT_DIR}"
  export BOOST_INCLUDEDIR="${BOOST_ROOT_DIR}"

  local cxx_num="${QBT_STDCVER//[^0-9]/}"
  # Official INSTALL uses Release; Swizzin historically used lowercase "release".
  # We use Release (validated against upstream INSTALL for 5.2.x).
  local cmake_args=(
    -Wno-dev -Wno-deprecated -G Ninja -B build
    -D CMAKE_BUILD_TYPE="Release"
    -D CMAKE_CXX_STANDARD="${cxx_num}"
    -D Boost_NO_BOOST_CMAKE=TRUE
    -D CMAKE_CXX_FLAGS="${CXXFLAGS}"
    -D CMAKE_C_FLAGS="${CFLAGS}"
    -D GUI=OFF
    -D CMAKE_INSTALL_PREFIX="${STAGE_DIR}/usr"
  )
  if [[ "${has_qt6}" -eq 1 ]]; then
    cmake_args+=(-D QT6=ON)
  fi

  info "CMake configuration: cmake ${cmake_args[*]}"
  (
    cd "${SOURCE_DIR}"
    cmake "${cmake_args[@]}"
    cmake --build build
    cmake --install build
  ) >> "${LOG_FILE}" 2>&1 || die "qBittorrent build failed — log: ${LOG_FILE}"

  if [[ ! -x "${STAGE_DIR}/usr/bin/qbittorrent-nox" ]]; then
    die "Build did not produce ${STAGE_DIR}/usr/bin/qbittorrent-nox"
  fi
  ok "qbittorrent-nox binary built."

  # Optional: qbt-cli like Swizzin (best-effort, non-fatal)
  install_qbt_cli_into_stage || warn "qbt-cli could not be added (non-critical)."

  local tagdesc=" static with ${QBT_STDCVER} O3 march=native"
  (
    fpm -f -C "${STAGE_DIR}" -p "${DIST_DIR}/qbittorrent-nox_VERSION.deb" \
      -s dir -t deb -n qbittorrent-nox --version "${TARGET_VERSION}" \
      --description "qbittorrent-nox compiled by qbittorrent-5.2-upgrade${tagdesc}"
  ) >> "${LOG_FILE}" 2>&1 || die "fpm qbittorrent-nox failed."

  local deb
  deb="$(ls -1t "${DIST_DIR}"/qbittorrent-nox_"${TARGET_VERSION}"*.deb 2>/dev/null | head -n1)"
  [[ -n "${deb}" ]] || die "qbittorrent-nox .deb not found in ${DIST_DIR}"
  info "Installing ${deb} (no apt remove/purge)…"
  run_cmd dpkg -i "${deb}"
  run_cmd apt-mark hold qbittorrent-nox
  ok "qbittorrent-nox ${TARGET_VERSION} installed and held (apt-mark hold)."
}

install_qbt_cli_into_stage() {
  local arch="${DPKG_ARCH}"
  local tag
  tag="$(github_latest_tag "ludviglundgren/qbittorrent-cli" || true)"
  [[ -n "${tag}" ]] || return 1
  local ver="${tag#v}"
  local url="https://github.com/ludviglundgren/qbittorrent-cli/releases/download/${tag}/qbittorrent-cli_${ver}_linux_${arch}.tar.gz"
  local tmp="${WORK_ROOT}/qbtcli"
  mkdir -p "${tmp}" "${STAGE_DIR}/usr/bin"
  curl -fL --retry 2 -o "${tmp}/qbtcli.tar.gz" "${url}" >> "${LOG_FILE}" 2>&1 || return 1
  tar -xzf "${tmp}/qbtcli.tar.gz" -C "${STAGE_DIR}/usr/bin" >> "${LOG_FILE}" 2>&1 || return 1
  rm -f "${STAGE_DIR}/usr/bin/README.md" "${tmp}/qbtcli.tar.gz" 2>/dev/null || true
  return 0
}

# -----------------------------------------------------------------------------
# Post-install verification
# -----------------------------------------------------------------------------
verify_installation() {
  info "Verifying installation…"
  local newver
  newver="$(qbittorrent-nox --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  info "Installed version: ${newver}"
  if [[ "${newver}" != "${TARGET_VERSION}" ]]; then
    die "Version mismatch: expected ${TARGET_VERSION}, found ${newver}"
  fi
  ok "Version ${newver} confirmed."

  local unit
  for unit in "${STARTED_SERVICES[@]+"${STARTED_SERVICES[@]}"}"; do
    if systemctl is-active --quiet "${unit}"; then
      ok "Service active: ${unit}"
    else
      warn "Service not active: ${unit}"
    fi
  done

  check_webui_local
  emit_webui_notes
}

check_webui_local() {
  info "Checking local WebUI reachability (best-effort)…"
  local conf port addr
  for conf in "${CONFIG_PATHS[@]+"${CONFIG_PATHS[@]}"}"; do
    local conf_file="${conf}/qBittorrent.conf"
    [[ -f "${conf_file}" ]] || continue
    port="$(grep -E '^WebUI\\Port=' "${conf_file}" 2>/dev/null | tail -n1 | cut -d= -f2 | tr -d '\r' || true)"
    addr="$(grep -E '^WebUI\\Address=' "${conf_file}" 2>/dev/null | tail -n1 | cut -d= -f2 | tr -d '\r' || true)"
    [[ -n "${port}" ]] || continue
    if [[ -z "${addr}" || "${addr}" == "*" ]]; then
      addr="127.0.0.1"
    fi
    info "WebUI check ${addr}:${port} (from ${conf_file})"
    if curl -fsS -o /dev/null --connect-timeout 3 --max-time 5 "http://${addr}:${port}/" 2>/dev/null \
       || curl -fsS -o /dev/null --connect-timeout 3 --max-time 5 -k "https://${addr}:${port}/" 2>/dev/null; then
      ok "WebUI responds on ${addr}:${port}"
    else
      # HTTP 401/403 still means reachable
      local code
      code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "http://${addr}:${port}/" || true)"
      if [[ "${code}" =~ ^[0-9]+$ && "${code}" != "000" ]]; then
        ok "WebUI reachable (${addr}:${port}, HTTP ${code})"
      else
        warn "WebUI on ${addr}:${port} not reachable (service may still be starting, or only via reverse proxy)."
      fi
    fi
  done
}

# -----------------------------------------------------------------------------
# Main upgrade flow
# -----------------------------------------------------------------------------
run_upgrade() {
  require_root
  mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
  _ensure_log
  info "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} start ==="
  info "Log: ${LOG_FILE}"

  probe_os
  probe_qbittorrent
  probe_libtorrent
  probe_qt
  probe_cmake_ninja
  probe_openssl
  probe_services
  probe_configs
  probe_disk_network
  probe_swizzin_reference
  resolve_target_version
  resolve_requirements_from_upstream
  plan_dependencies

  if version_ge "${CURRENT_QBT_VERSION}" "${TARGET_VERSION}" \
     && [[ "${CURRENT_QBT_VERSION}" == "${TARGET_VERSION}" ]]; then
    warn "Target version ${TARGET_VERSION} is already installed."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      print_dry_run_report
      exit 0
    fi
    confirm "Rebuild and reinstall anyway?"
  elif version_lt "${TARGET_VERSION}" "${CURRENT_QBT_VERSION}"; then
    die "Target version ${TARGET_VERSION} is older than installed ${CURRENT_QBT_VERSION}."
  fi

  if [[ ! "${CURRENT_QBT_VERSION}" =~ ^5\.1\. ]]; then
    warn "Installed version is ${CURRENT_QBT_VERSION} (typically expected 5.1.x). Continue only after review."
  fi

  print_dry_run_report

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    ok "DRY-RUN complete — no changes made."
    exit 0
  fi

  confirm "Proceed with upgrade from qBittorrent ${CURRENT_QBT_VERSION} → ${TARGET_VERSION}?"

  mkdir -p "${WORK_ROOT}" "${DIST_DIR}"
  create_backup
  maybe_remount_tmp_exec
  stop_active_services
  apt_install_packages
  ensure_cmake_swizzin
  ensure_qt
  ensure_boost
  build_libtorrent_if_needed
  backup_user_qbittorrent_confs
  build_qbittorrent
  apply_nginx_qbittorrent_52
  start_previous_services
  verify_installation

  # Cleanup work dirs (keep debs in DIST_DIR and backup)
  if [[ -d "${WORK_ROOT}" && "${WORK_ROOT}" == /var/tmp/qbittorrent-5.2-upgrade* ]]; then
    info "Cleaning work directory: ${WORK_ROOT}"
    rm -rf --one-file-system -- "${WORK_ROOT}"
  fi

  ok "=== Upgrade to qBittorrent ${TARGET_VERSION} succeeded ==="
  info "Backup: ${BACKUP_DIR}"
  info "Package: ${DIST_DIR}/qbittorrent-nox_${TARGET_VERSION}_*.deb"
  info "Rollback: ${SCRIPT_NAME} --rollback"
}

main() {
  parse_args "$@"
  if [[ "${DO_ROLLBACK}" -eq 1 ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      die "--rollback and --dry-run cannot be combined."
    fi
    do_rollback
    exit 0
  fi
  run_upgrade
}

main "$@"
