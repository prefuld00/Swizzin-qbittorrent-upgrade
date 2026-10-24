#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Constants / defaults
# -----------------------------------------------------------------------------
SCRIPT_NAME="$(basename "${0}")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="1.7.3"
readonly LOG_FILE_ENV="${QBT_UPGRADE_LOG:-}"
readonly WORK_ROOT_ENV="${QBT_UPGRADE_WORK:-}"
# Defaults become versioned after the target qBittorrent release is known
# (see apply_versioned_paths). Env overrides keep a fixed path.
LOG_FILE="${LOG_FILE_ENV:-/var/log/qbittorrent-upgrade.log}"
WORK_ROOT="${WORK_ROOT_ENV:-/var/tmp/qbittorrent-upgrade}"
readonly DIST_DIR="${QBT_UPGRADE_DIST:-/root/dist}"
readonly BACKUP_ROOT_BASE="/root"
readonly QBT_REPO_URL="https://github.com/qbittorrent/qBittorrent"
readonly LIBTORRENT_REPO_URL="https://github.com/arvidn/libtorrent.git"
readonly SWIZZIN_REPO_RAW="https://raw.githubusercontent.com/swizzin/swizzin/master"
readonly SWIZZIN_QBT_FUNC_URL="${SWIZZIN_REPO_RAW}/sources/functions/qbittorrent"
readonly QT6_CROSSBUILD_REPO="swizzin/qt6_crossbuild"
readonly CMAKE_CROSSBUILD_REPO="swizzin/cmake_crossbuild"
readonly ZLIB_NG_CROSSBUILD_REPO="swizzin/zlib-ng-crossbuild"
readonly MIN_FREE_MIB=4096
readonly NGINX_QBT_CONF="/etc/nginx/apps/qbittorrent.conf"
readonly NGINX_QBT_CONF_ORIG="/etc/nginx/apps/qbittorrent.conf.orig"
readonly QBT_LIBTORRENT_BRANCH_DEFAULT="RC_1_2"

# Runtime flags / state
DRY_RUN=0
ASSUME_YES=0
DO_ROLLBACK=0
TARGET_VERSION_OVERRIDE=""
RESOLVE_LATEST_STABLE=0
RESOLVE_LATEST_BETA=0
LIBTORRENT_BRANCH_OVERRIDE=""
BACKUP_DIR=""
SOURCE_DIR=""
BUILD_DIR=""
STAGE_DIR=""
STARTED_SERVICES=()
STOPPED_SERVICES=()
PREVIOUSLY_ACTIVE_SERVICES=()
EXEC_REMOUNT_TARGETS=()
CLEANUP_PATHS=()
STATE_FILE=""
OPENSSL_VERSION_FOUND=""
ZLIB_VERSION_FOUND=""
RECOVERY_DONE=0
NGINX_NEEDS_RESTORE=0
NGINX_RESTORE_SOURCE=""
UPGRADE_SUCCEEDED=0
QBT_PACKAGE_INSTALLED=0
PREV_QBT_DEB=""
LIBTORRENT_PACKAGE_INSTALLED=0
PREV_LIBTORRENT_DEB=""

# Filled after resolve_target_version + resolve_requirements_from_upstream
# (no hard-coded series or dependency floors - always from the chosen release tag).
SERIES=""
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
    # Best-effort create; may fail in dry-run as non-root - then fall back to stderr only.
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
    touch "${LOG_FILE}" 2>/dev/null || true
  fi
}

# Once the target qBittorrent release is known, place log/work under that version
# unless the user overrode QBT_UPGRADE_LOG / QBT_UPGRADE_WORK.
apply_versioned_paths() {
  local ver="$1"
  [[ -n "${ver}" ]] || die "apply_versioned_paths: empty version"
  # Stable X.Y.Z or pre-release like 5.3.0beta1 / 5.3.0rc1
  if [[ ! "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([A-Za-z]+[0-9]*)?$ ]]; then
    die "apply_versioned_paths: invalid version '${ver}'"
  fi

  local path_ver="${ver}"
  local prev_log="${LOG_FILE}"
  if [[ -z "${LOG_FILE_ENV}" ]]; then
    LOG_FILE="/var/log/qbittorrent-${path_ver}-upgrade.log"
  fi
  if [[ -z "${WORK_ROOT_ENV}" ]]; then
    WORK_ROOT="/var/tmp/qbittorrent-${path_ver}-upgrade"
  fi
  validate_work_root "${WORK_ROOT}"

  mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
  _ensure_log
  if [[ "${prev_log}" != "${LOG_FILE}" && -f "${prev_log}" && -s "${prev_log}" ]]; then
    cat "${prev_log}" >> "${LOG_FILE}" 2>/dev/null || true
  fi
  info "Paths for qBittorrent ${ver}: log=${LOG_FILE} work=${WORK_ROOT}"
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

# Extract full qBittorrent version (stable X.Y.Z or pre-release like 5.3.0beta1).
extract_qbt_version() {
  local text="${1:-}"
  printf '%s' "${text}" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([A-Za-z]+[0-9]*)?' \
    | head -n1 \
    || true
}

series_ge_52() {
  local series="${1:-}"
  [[ -n "${series}" ]] || return 1
  # Compare as X.Y.0 so dpkg accepts two-part series strings.
  version_ge "${series}.0" "5.2.0"
}

die() {
  error "$*"
  failure_recovery
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
  die "Command failed: $(quote_cmd "$@") - see details in ${LOG_FILE}"
}

version_ge() {
  # version_ge A B  -> true if A >= B (dpkg) - for toolchain/package versions
  dpkg --compare-versions "$1" ge "$2"
}

version_lt() {
  dpkg --compare-versions "$1" lt "$2"
}

# Map qBittorrent tags (5.3.0beta1) to Debian order so pre-releases sort before the final.
# Debian: 5.3.0~beta1 < 5.3.0 ; without ~, 5.3.0beta1 > 5.3.0 (wrong for qBt).
qbt_to_deb_version() {
  local v="$1"
  if [[ "${v}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)([A-Za-z]+[0-9]*)$ ]]; then
    local pre="${BASH_REMATCH[2]}"
    pre="${pre,,}"
    printf '%s~%s' "${BASH_REMATCH[1]}" "${pre}"
  else
    printf '%s' "${v}"
  fi
}

qbt_version_ge() {
  dpkg --compare-versions "$(qbt_to_deb_version "$1")" ge "$(qbt_to_deb_version "$2")"
}

qbt_version_lt() {
  dpkg --compare-versions "$(qbt_to_deb_version "$1")" lt "$(qbt_to_deb_version "$2")"
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
  # Only remove paths we explicitly registered under a validated WORK_ROOT / known temps.
  local path="$1"
  if [[ -z "${path}" || "${path}" == "/" || "${path}" == "/root" || "${path}" == "/home" ]]; then
    warn "safe_rm_path: refusing unsafe path: '${path}'"
    return 1
  fi
  local real=""
  real="$(realpath -m -- "${path}" 2>/dev/null || true)"
  if [[ -z "${real}" ]]; then
    warn "safe_rm_path: could not resolve path: '${path}'"
    return 1
  fi
  case "${real}" in
    /|/root|/home|/usr|/var|/etc|/boot|/opt|/bin|/sbin|/lib|/lib64)
      warn "safe_rm_path: refusing broad/system path: '${real}'"
      return 1
      ;;
  esac
  # Reject path traversal that escapes intended roots
  case "${real}" in
    "${WORK_ROOT}"|"${WORK_ROOT}"/*)
      ;;
    /tmp/dist/qbittorrent*|/tmp/dist/libtorrent*|/tmp/qbittorrent-upgrade-*|/tmp/qbt-req-*)
      ;;
    /var/tmp/qbittorrent-*-upgrade|/var/tmp/qbittorrent-*-upgrade/*)
      ;;
    *)
      warn "safe_rm_path: path not on allowed whitelist: ${real} (from ${path})"
      return 1
      ;;
  esac
  if [[ -e "${real}" || -L "${real}" ]]; then
    info "Cleanup: ${real}"
    rm -rf --one-file-system -- "${real}"
  fi
}

validate_work_root() {
  local root="${1:-${WORK_ROOT}}"
  [[ -n "${root}" ]] || die "WORK_ROOT is empty."
  local real
  real="$(realpath -m -- "${root}" 2>/dev/null || true)"
  [[ -n "${real}" ]] || die "Could not resolve WORK_ROOT='${root}'."
  case "${real}" in
    /|/root|/home|/usr|/var|/etc|/boot|/opt|/tmp|/var/tmp)
      die "Refusing unsafe WORK_ROOT='${real}' (too broad). Use a subdirectory under /var/tmp, /tmp, or /root."
      ;;
  esac
  case "${real}" in
    /var/tmp/*|/tmp/*|/root/*) ;;
    *)
      die "WORK_ROOT must be under /var/tmp, /tmp, or /root (got '${real}')."
      ;;
  esac
  WORK_ROOT="${real}"
}

register_cleanup() {
  CLEANUP_PATHS+=("$1")
}

drain_cleanup_paths() {
  local path
  for path in "${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}"; do
    safe_rm_path "${path}" 2>/dev/null || true
  done
  CLEANUP_PATHS=()
}

restore_exec_remounts() {
  local mnt
  for mnt in "${EXEC_REMOUNT_TARGETS[@]+"${EXEC_REMOUNT_TARGETS[@]}"}"; do
    [[ -n "${mnt}" ]] || continue
    mount -o remount,noexec "${mnt}" >> "${LOG_FILE}" 2>&1 || true
  done
  EXEC_REMOUNT_TARGETS=()
}

restore_nginx_after_failed_write() {
  if [[ "${NGINX_NEEDS_RESTORE}" -ne 1 ]]; then
    return 0
  fi
  # If the new qbittorrent package is already installed, keep the 5.2+ nginx snippet.
  if [[ "${QBT_PACKAGE_INSTALLED}" -eq 1 ]]; then
    info "Error recovery: keeping nginx 5.2+ config (new qbittorrent package already installed)."
    NGINX_NEEDS_RESTORE=0
    NGINX_RESTORE_SOURCE=""
    return 0
  fi
  local src="${NGINX_RESTORE_SOURCE}"
  if [[ -z "${src}" || ! -f "${src}" ]]; then
    if [[ -f "${NGINX_QBT_CONF_ORIG}" ]]; then
      src="${NGINX_QBT_CONF_ORIG}"
    fi
  fi
  if [[ -n "${src}" && -f "${src}" ]]; then
    warn "Error recovery: restoring nginx config from ${src}"
    cp -a -- "${src}" "${NGINX_QBT_CONF}" >> "${LOG_FILE}" 2>&1 \
      || warn "Could not restore ${NGINX_QBT_CONF}"
    if command -v nginx >/dev/null 2>&1; then
      nginx -t >> "${LOG_FILE}" 2>&1 && systemctl reload nginx >> "${LOG_FILE}" 2>&1 \
        || warn "nginx reload after restore failed - check ${NGINX_QBT_CONF}"
    fi
  else
    warn "Error recovery: nginx config may be broken; no restore source available."
  fi
  NGINX_NEEDS_RESTORE=0
  NGINX_RESTORE_SOURCE=""
}

restore_stopped_services() {
  if [[ "${DRY_RUN}" -ne 0 ]]; then
    return 0
  fi
  # Only touch units we actually stopped. Do not bounce live services on early abort
  # (confirm N / preflight) when STOPPED_SERVICES is still empty.
  if [[ ${#STOPPED_SERVICES[@]} -eq 0 ]]; then
    return 0
  fi
  local svc
  for svc in "${STOPPED_SERVICES[@]}"; do
    # Always restart: after package/binary rollback an already-active unit may still
    # be running the new binary from memory while nginx/package were restored.
    warn "Error recovery: restarting service: ${svc}"
    if ! systemctl restart "${svc}" >> "${LOG_FILE}" 2>&1; then
      systemctl start "${svc}" >> "${LOG_FILE}" 2>&1 || warn "Could not start ${svc}."
    fi
  done
}

restore_previous_packages() {
  # Best-effort: if we installed a new qbittorrent/libtorrent package and later failed, put the old ones back.
  # Stop units first so dpkg maintainer scripts do not race with a live qbittorrent-nox.
  local svc
  for svc in "${STOPPED_SERVICES[@]+"${STOPPED_SERVICES[@]}"}"; do
    systemctl stop "${svc}" >> "${LOG_FILE}" 2>&1 || true
  done

  if [[ "${QBT_PACKAGE_INSTALLED}" -eq 1 ]]; then
    apt-mark unhold qbittorrent-nox >> "${LOG_FILE}" 2>&1 || true
    if [[ -n "${PREV_QBT_DEB}" && -f "${PREV_QBT_DEB}" ]]; then
      warn "Error recovery: restoring previous qbittorrent-nox from ${PREV_QBT_DEB}"
      if dpkg -i "${PREV_QBT_DEB}" >> "${LOG_FILE}" 2>&1; then
        QBT_PACKAGE_INSTALLED=0
        ok "Restored previous qbittorrent-nox package."
      else
        warn "Could not restore qbittorrent-nox from backup .deb - see ${LOG_FILE}"
        if [[ -n "${BACKUP_DIR}" && -x "${BACKUP_DIR}/bin/qbittorrent-nox.prev" && -n "${QBT_BINARY}" ]]; then
          warn "Error recovery: copying previous binary to ${QBT_BINARY} (dpkg metadata may still show the new version - reinstall manually from backup)."
          if cp -a -- "${BACKUP_DIR}/bin/qbittorrent-nox.prev" "${QBT_BINARY}" >> "${LOG_FILE}" 2>&1; then
            QBT_PACKAGE_INSTALLED=0
          else
            warn "Binary restore failed."
          fi
        fi
      fi
    elif [[ -n "${BACKUP_DIR}" && -x "${BACKUP_DIR}/bin/qbittorrent-nox.prev" && -n "${QBT_BINARY}" ]]; then
      warn "Error recovery: no previous .deb - copying binary backup to ${QBT_BINARY} (dpkg may still list the new package; apt-mark unhold applied)."
      if cp -a -- "${BACKUP_DIR}/bin/qbittorrent-nox.prev" "${QBT_BINARY}" >> "${LOG_FILE}" 2>&1; then
        QBT_PACKAGE_INSTALLED=0
      else
        warn "Binary restore failed."
      fi
    else
      warn "Error recovery: no previous qbittorrent .deb or binary backup available."
    fi
  fi
  if [[ "${LIBTORRENT_PACKAGE_INSTALLED}" -eq 1 ]]; then
    if [[ -n "${PREV_LIBTORRENT_DEB}" && -f "${PREV_LIBTORRENT_DEB}" ]]; then
      warn "Error recovery: restoring previous libtorrent-rasterbar from ${PREV_LIBTORRENT_DEB}"
      if dpkg -i "${PREV_LIBTORRENT_DEB}" >> "${LOG_FILE}" 2>&1; then
        LIBTORRENT_PACKAGE_INSTALLED=0
        ok "Restored previous libtorrent-rasterbar package."
      else
        warn "Could not restore libtorrent-rasterbar from backup .deb - see ${LOG_FILE}"
      fi
    else
      warn "Error recovery: libtorrent was replaced but no PREV_LIBTORRENT_DEB - cannot auto-restore (Deluge/other users may be affected)."
    fi
  fi
}

failure_recovery() {
  [[ "${RECOVERY_DONE}" -eq 1 ]] && return 0
  # Ignore further interrupts BEFORE marking recovery done (avoid signal race skipping restore).
  trap '' INT TERM HUP
  RECOVERY_DONE=1
  if [[ "${UPGRADE_SUCCEEDED}" -eq 1 ]]; then
    return 0
  fi
  restore_previous_packages
  restore_nginx_after_failed_write
  restore_stopped_services
}

on_error() {
  local ec=$?
  local line="${1:-?}"
  error "Abort at line ${line} (exit=${ec}). Log: ${LOG_FILE}"
  failure_recovery
  exit "${ec}"
}

on_signal() {
  local sig="${1:-UNKNOWN}"
  # Block further signals immediately (trap - would restore default = terminate mid-recovery).
  trap '' INT TERM HUP
  error "Caught signal ${sig} - restoring services / nginx if needed. Log: ${LOG_FILE}"
  failure_recovery
  case "${sig}" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
    HUP) exit 129 ;;
    *) exit 1 ;;
  esac
}

on_exit() {
  local ec="${1:-0}"
  # Belt-and-suspenders: any non-success exit restores stopped services (covers signals / odd exits).
  if [[ "${ec}" -ne 0 && "${UPGRADE_SUCCEEDED}" -eq 0 ]]; then
    failure_recovery
  fi
  restore_exec_remounts
  # Keep WORK_ROOT on failure for debugging; drain registered temps only on success.
  if [[ "${ec}" -eq 0 || "${UPGRADE_SUCCEEDED}" -eq 1 ]]; then
    drain_cleanup_paths
  else
    local path
    for path in "${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}"; do
      case "${path}" in
        /tmp/qbt-req-*) safe_rm_path "${path}" 2>/dev/null || true ;;
      esac
    done
  fi
}

trap 'on_error ${LINENO}' ERR
trap 'on_exit $?' EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Always builds the current qBittorrent release from official source (default:
newest GitHub stable) and installs the dependencies required by that exact tag.
Build floors (Qt, libtorrent, CMake, C++, Boost, OpenSSL, zlib) are read from
upstream CMakeLists.txt / CommonConfig.cmake for the resolved version -
never hard-coded in this script. Packaging follows Swizzin (PR #1300).

Options:
  --dry-run              Analyse and plan only; make no changes
  --yes                  Skip interactive confirmation
  --rollback             Return to Swizzin current stable via:
                         QBITTORRENT_VERSION=<ver> box upgrade qbittorrent
  --version X.Y.Z        Optional: pin an exact stable instead of "latest"
  --stable               Latest stable from GitHub (same as default / no flags)
  --beta                 Latest upstream beta/RC/pre-release (not for production)
  --libtorrent BRANCH    RC_1_2 (default) or RC_2_0
  --help                 Show this help

Default (no --version / --beta): latest stable + dependency floors from that release.
--beta picks the newest pre-release tag instead.

--rollback resolves the preferred series from the local Swizzin qbittorrent function
(when present; else GitHub master), picks the latest stable patch of that series, then
runs box upgrade (no whiptail dialog).

Environment variables:
  QBT_UPGRADE_LOG        Log file (default: /var/log/qbittorrent-<version>-upgrade.log)
  QBT_UPGRADE_WORK       Work directory (default: /var/tmp/qbittorrent-<version>-upgrade)
  QBT_UPGRADE_DIST       Output directory for .deb packages (default: ${DIST_DIR})

Examples:
  ${SCRIPT_NAME} --dry-run              # plan: latest stable + its deps
  ${SCRIPT_NAME} --yes                  # build: latest stable + its deps
  ${SCRIPT_NAME} --stable --yes         # same as --yes
  ${SCRIPT_NAME} --version 5.3.0 --yes  # optional exact pin
  ${SCRIPT_NAME} --beta --yes
  ${SCRIPT_NAME} --rollback
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --rollback) DO_ROLLBACK=1; shift ;;
      --stable) RESOLVE_LATEST_STABLE=1; shift ;;
      --beta) RESOLVE_LATEST_BETA=1; shift ;;
      --version)
        [[ $# -ge 2 ]] || die "--version requires an argument"
        TARGET_VERSION_OVERRIDE="$2"
        shift 2
        ;;
      --series)
        die "--series was removed. Use --stable (latest stable) or --version X.Y.Z (exact)."
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

  local pin_count=0
  [[ -n "${TARGET_VERSION_OVERRIDE}" ]] && pin_count=$((pin_count + 1))
  [[ "${RESOLVE_LATEST_STABLE}" -eq 1 ]] && pin_count=$((pin_count + 1))
  [[ "${RESOLVE_LATEST_BETA}" -eq 1 ]] && pin_count=$((pin_count + 1))
  if [[ "${pin_count}" -gt 1 ]]; then
    die "Use only one of --version, --stable, or --beta."
  fi

  if [[ -n "${TARGET_VERSION_OVERRIDE}" ]]; then
    if [[ ! "${TARGET_VERSION_OVERRIDE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      die "--version must be a stable X.Y.Z release (e.g. 5.3.0). For pre-releases use --beta."
    fi
    SERIES="$(printf '%s' "${TARGET_VERSION_OVERRIDE}" | cut -d. -f1-2)"
    RESOLVE_LATEST_STABLE=0
    RESOLVE_LATEST_BETA=0
  elif [[ "${RESOLVE_LATEST_BETA}" -eq 1 ]]; then
    RESOLVE_LATEST_STABLE=0
    SERIES=""
  else
    # Default and --stable: newest stable release from GitHub
    RESOLVE_LATEST_STABLE=1
    RESOLVE_LATEST_BETA=0
    SERIES=""
  fi
}

# -----------------------------------------------------------------------------
# OS / toolchain probes
# -----------------------------------------------------------------------------
probe_os() {
  info "Checking Debian version and architecture..."
  if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release is missing - unsupported system."
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
  info "Detecting installed qBittorrent version..."
  QBT_BINARY="$(command -v qbittorrent-nox || true)"
  if [[ -z "${QBT_BINARY}" ]]; then
    # Common Swizzin path
    if [[ -x /usr/bin/qbittorrent-nox ]]; then
      QBT_BINARY="/usr/bin/qbittorrent-nox"
    fi
  fi
  if [[ -n "${QBT_BINARY}" ]]; then
    CURRENT_QBT_VERSION="$(extract_qbt_version "$("${QBT_BINARY}" --version 2>/dev/null || true)")"
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
  info "Detecting installed libtorrent version..."
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
    warn "Could not determine libtorrent version - a rebuild may be required."
  else
    ok "libtorrent: ${CURRENT_LIBTORRENT_VERSION}"
  fi
}

probe_qt() {
  info "Detecting Qt6 version..."
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
  info "Detecting CMake and Ninja versions..."
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

probe_zlib() {
  ZLIB_VERSION_FOUND=""
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists zlib 2>/dev/null; then
    ZLIB_VERSION_FOUND="$(pkg-config --modversion zlib 2>/dev/null || true)"
  fi
  if [[ -z "${ZLIB_VERSION_FOUND}" ]]; then
    local zlib_pkg
    zlib_pkg="$(dpkg-query -W -f='${Version}' zlib1g 2>/dev/null || true)"
    if [[ -n "${zlib_pkg}" ]]; then
      # Strip Debian epoch (e.g. 1:1.2.13.dfsg-1 -> 1.2.13.dfsg-1) then take X.Y.Z.
      zlib_pkg="${zlib_pkg#*:}"
      ZLIB_VERSION_FOUND="$(printf '%s' "${zlib_pkg}" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' || true)"
    fi
  fi
  # Pad to X.Y.Z for later dpkg comparisons.
  if [[ -n "${ZLIB_VERSION_FOUND}" ]]; then
    local parts
    IFS='.' read -r -a parts <<< "${ZLIB_VERSION_FOUND}"
    ZLIB_VERSION_FOUND="${parts[0]:-0}.${parts[1]:-0}.${parts[2]:-0}"
  fi
  info "zlib: ${ZLIB_VERSION_FOUND:-unknown}"
}

probe_services() {
  info "Detecting qBittorrent services (service name is not assumed)..."
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
  info "Detecting qBittorrent configuration paths..."
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
        # Also data dir (BT_backup etc.) - backup only config; mention data
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
  info "Checking free disk space..."
  local check_path="/var/tmp"
  # Prefer the actual work root once known (env override or versioned path).
  if [[ -n "${WORK_ROOT}" ]]; then
    mkdir -p "${WORK_ROOT}" 2>/dev/null || true
    if [[ -d "${WORK_ROOT}" ]]; then
      check_path="${WORK_ROOT}"
    fi
  fi
  local avail_kib
  avail_kib="$(df -Pk "${check_path}" 2>/dev/null | awk 'NR==2{print $4}')"
  [[ -n "${avail_kib}" ]] || die "Could not determine free space for ${check_path}."
  local avail_mib=$(( avail_kib / 1024 ))
  if [[ "${avail_mib}" -lt "${MIN_FREE_MIB}" ]]; then
    die "Insufficient free space under ${check_path}: ${avail_mib} MiB (at least ${MIN_FREE_MIB} MiB recommended)."
  fi
  ok "Free space ${check_path}: ~${avail_mib} MiB"

  info "Checking Internet / GitHub reachability..."
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
    if grep -qE '5\.(2|3)\.\*' "${SWIZZIN_QBT_FUNC}" 2>/dev/null; then
      ok "Local Swizzin function already includes 5.2.*/5.3.* series labels."
    else
      warn "Local Swizzin function may not list 5.2.*/5.3.* yet. This script operates independently."
    fi
  else
    info "No /etc/swizzin/sources/functions/qbittorrent - script runs standalone following PR #1300."
  fi
}

# -----------------------------------------------------------------------------
# Version resolution
# -----------------------------------------------------------------------------
github_qbt_tags_api() {
  # Paginate GitHub tags API; print version strings (no release- prefix), newest first.
  # mode: stable | beta | series - for series, pass series as $2 (e.g. 5.1).
  local mode="${1:-stable}"
  local series="${2:-}"
  local page=1
  local max_pages=15
  local all_json="["
  local first=1
  local chunk=""
  local count=0

  while [[ "${page}" -le "${max_pages}" ]]; do
    chunk="$(curl -fsSL "https://api.github.com/repos/qbittorrent/qBittorrent/tags?per_page=100&page=${page}" 2>/dev/null || true)"
    [[ -n "${chunk}" ]] || break
    count="$(python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
  print(len(d) if isinstance(d,list) else 0)
except Exception:
  print(0)' <<< "${chunk}" 2>/dev/null || echo 0)"
    if [[ "${count}" -eq 0 ]]; then
      break
    fi
    # Append array elements into one JSON list
    local inner
    inner="$(python3 -c 'import json,sys
d=json.load(sys.stdin)
print(",".join(json.dumps(x) for x in d))' <<< "${chunk}" 2>/dev/null || true)"
    if [[ -n "${inner}" ]]; then
      if [[ "${first}" -eq 1 ]]; then
        all_json+="${inner}"
        first=0
      else
        all_json+=",${inner}"
      fi
    fi
    if [[ "${count}" -lt 100 ]]; then
      break
    fi
    page=$((page + 1))
  done
  all_json+="]"

  MODE_ENV="${mode}" SERIES_ENV="${series}" python3 -c '
import json, os, re, sys
mode = os.environ.get("MODE_ENV", "stable")
series = os.environ.get("SERIES_ENV", "")
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, list) or not data:
    sys.exit(0)
vers = []
for t in data:
    name = t.get("name", "")
    if mode == "beta":
        m = re.match(r"^release-(\d+\.\d+\.\d+(?:alpha|beta|rc)\d*)$", name, re.I)
    elif mode == "series":
        m = re.match(r"^release-(" + re.escape(series) + r"\.\d+)$", name)
    else:
        m = re.match(r"^release-(\d+\.\d+\.\d+)$", name)
    if m:
        vers.append(m.group(1))
if not vers:
    sys.exit(0)

def beta_key(v):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)([A-Za-z]+)(\d*)$", v)
    if not m:
        return (0, 0, 0, 99, 0)
    kind = {"alpha": 0, "beta": 1, "rc": 2}.get(m.group(4).lower(), 3)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), kind, int(m.group(5) or 0))

def stable_key(v):
    return [int(x) for x in v.split(".")]

key = beta_key if mode == "beta" else stable_key
print("\n".join(sorted(set(vers), key=key, reverse=True)))
' <<< "${all_json}" 2>/dev/null || true
}

git_ls_remote_qbt_tags() {
  local mode="${1:-stable}"
  local series="${2:-}"
  local raw
  raw="$(git ls-remote -t --refs "${QBT_REPO_URL}.git" 2>/dev/null \
    | awk '{print $2}' \
    | sed 's#refs/tags/release-##' || true)"
  [[ -n "${raw}" ]] || return 0
  case "${mode}" in
    beta)
      printf '%s\n' "${raw}" \
        | grep -iE '^[0-9]+\.[0-9]+\.[0-9]+(alpha|beta|rc)[0-9]*$' \
        | sort -Vr || true
      ;;
    series)
      local series_re
      series_re="$(printf '%s' "${series}" | sed 's/\./\\./g')"
      printf '%s\n' "${raw}" \
        | grep -E "^${series_re}\.[0-9]+$" \
        | grep -viE 'beta|rc|alpha|dev|nightly' \
        | sort -Vr || true
      ;;
    *)
      printf '%s\n' "${raw}" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | grep -viE 'beta|rc|alpha|dev|nightly' \
        | sort -Vr || true
      ;;
  esac
}

resolve_qbt_tags() {
  local mode="${1:-stable}"
  local series="${2:-}"
  local tags=""
  tags="$(git_ls_remote_qbt_tags "${mode}" "${series}")"
  if [[ -z "${tags}" ]]; then
    tags="$(github_qbt_tags_api "${mode}" "${series}")"
  fi
  # Deduplicate; for beta, re-sort with pre-release-aware key (sort -V is wrong for alpha/beta/rc).
  if [[ "${mode}" == "beta" ]]; then
    printf '%s\n' "${tags}" | awk 'NF && !seen[$0]++' | python3 -c '
import sys, re
vers = [l.strip() for l in sys.stdin if l.strip()]
def key(v):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)([A-Za-z]+)(\d*)$", v)
    if not m:
        return (0, 0, 0, 99, 0)
    kind = {"alpha": 0, "beta": 1, "rc": 2}.get(m.group(4).lower(), 3)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), kind, int(m.group(5) or 0))
print("\n".join(sorted(vers, key=key, reverse=True)))
'
  else
    printf '%s\n' "${tags}" | awk 'NF && !seen[$0]++'
  fi
}

resolve_target_version() {
  if [[ -n "${TARGET_VERSION_OVERRIDE}" ]]; then
    TARGET_VERSION="${TARGET_VERSION_OVERRIDE}"
    SERIES="$(printf '%s' "${TARGET_VERSION}" | cut -d. -f1-2)"
    ok "Target version (exact --version pin): ${TARGET_VERSION}"
    info "Dependency floors will be read from upstream release-${TARGET_VERSION}."
    return 0
  fi

  local tags=""

  if [[ "${RESOLVE_LATEST_BETA}" -eq 1 ]]; then
    info "Resolving newest qBittorrent beta/RC/pre-release from GitHub..."
    tags="$(resolve_qbt_tags beta)"
    TARGET_VERSION="$(printf '%s\n' "${tags}" | head -n1)"
    if [[ -z "${TARGET_VERSION}" ]]; then
      die "Could not determine the latest qBittorrent beta/RC from GitHub."
    fi
    SERIES="$(printf '%s' "${TARGET_VERSION}" | grep -oE '^[0-9]+\.[0-9]+' | head -n1)"
    warn "Pre-release target selected (--beta): ${TARGET_VERSION} - not recommended for production."
    ok "Current pre-release qBittorrent: ${TARGET_VERSION}"
    info "Dependency floors will be read from upstream release-${TARGET_VERSION}."
    return 0
  fi

  if [[ "${RESOLVE_LATEST_STABLE}" -eq 1 ]]; then
    info "Resolving current (newest) stable qBittorrent release from GitHub..."
    tags="$(resolve_qbt_tags stable)"
    TARGET_VERSION="$(printf '%s\n' "${tags}" | head -n1)"
    if [[ -z "${TARGET_VERSION}" ]]; then
      die "Could not determine the latest stable qBittorrent version from GitHub."
    fi
    SERIES="$(printf '%s' "${TARGET_VERSION}" | cut -d. -f1-2)"
    ok "Current stable qBittorrent: ${TARGET_VERSION} (series ${SERIES}.x)"
    info "Dependency floors will be read from upstream release-${TARGET_VERSION} (not hard-coded)."
    return 0
  fi

  die "Internal error: no version resolution mode selected."
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
  # 6.6 / 6.6.0 / 1.2.19 -> at least major.minor.patch for dpkg comparisons
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
  local candidates=("1_86_0" "1_87_0" "1_88_0" "1_89_0" "1_90_0" "1_91_0" "1_92_0")
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
  [[ -n "${TARGET_VERSION}" ]] || die "TARGET_VERSION is empty - call resolve_target_version first."
  info "Resolving build requirements from upstream release-${TARGET_VERSION}..."

  local cmake_txt cfg_txt tmpd
  tmpd="$(mktemp -d /tmp/qbt-req-XXXXXX)"
  CLEANUP_PATHS+=("${tmpd}")
  cmake_txt="$(fetch_upstream_text "CMakeLists.txt")"
  cfg_txt="$(fetch_upstream_text "cmake/Modules/CommonConfig.cmake")"
  if [[ -z "${cfg_txt}" ]]; then
    cfg_txt="$(fetch_upstream_text "cmake/CommonConfig.cmake")"
  fi

  if [[ -z "${cmake_txt}" ]]; then
    rm -rf --one-file-system -- "${tmpd}"
    die "Could not fetch CMakeLists.txt for release-${TARGET_VERSION}. Cannot resolve Qt/libtorrent/Boost/OpenSSL/zlib minima without upstream source."
  fi

  printf '%s\n' "${cmake_txt}" > "${tmpd}/CMakeLists.txt"
  printf '%s\n' "${cfg_txt}" > "${tmpd}/CommonConfig.cmake"

  local parsed
  parsed="$(
    python3 - "${tmpd}/CMakeLists.txt" "${tmpd}/CommonConfig.cmake" <<'PY'
import re, sys
from pathlib import Path

cmake = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
cfg_path = Path(sys.argv[2])
cfg = cfg_path.read_text(encoding="utf-8", errors="replace") if cfg_path.is_file() and cfg_path.stat().st_size else ""

def grab(pattern, text, default=""):
    m = re.search(pattern, text, re.M | re.I)
    return m.group(1).strip() if m else default

cmake_min = grab(r'cmake_minimum_required\s*\(\s*VERSION\s+([0-9]+(?:\.[0-9]+){1,2})', cmake)
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

missing = [n for n, v in [
    ("cmake_minimum_required", cmake_min),
    ("minBoostVersion", boost),
    ("minQt6Version/minQtVersion", qt),
    ("minOpenSSLVersion", openssl),
    ("minLibtorrent1Version", lt1),
    ("minLibtorrentVersion", lt2),
    ("minZlibVersion", zlib),
    ("cxx_std / CMAKE_CXX_STANDARD", stdc),
] if not v]
if missing:
    print("MISSING=" + ",".join(missing), file=sys.stderr)
    sys.exit(2)

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
    local rc=$?
    rm -rf --one-file-system -- "${tmpd}"
    if [[ "${rc}" -eq 2 ]]; then
      die "Upstream release-${TARGET_VERSION} CMakeLists.txt is missing required version fields. Refusing hard-coded fallbacks."
    fi
    die "Failed to parse upstream CMakeLists for release-${TARGET_VERSION}."
  }
  rm -rf --one-file-system -- "${tmpd}"

  local line key val
  CMAKE_MIN_VERSION=""
  QBT_BOOST_MINIMUM=""
  QBT_QT_MINIMUM=""
  QBT_OPENSSL_MINIMUM=""
  QBT_LIBTORRENT_MINIMUM=""
  QBT_LIBTORRENT2_MINIMUM=""
  QBT_ZLIB_MINIMUM=""
  QBT_STDCVER=""
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

  [[ -n "${CMAKE_MIN_VERSION}" && -n "${QBT_QT_MINIMUM}" && -n "${QBT_STDCVER}" \
     && -n "${QBT_BOOST_MINIMUM}" && -n "${QBT_OPENSSL_MINIMUM}" \
     && -n "${QBT_LIBTORRENT_MINIMUM}" && -n "${QBT_LIBTORRENT2_MINIMUM}" \
     && -n "${QBT_ZLIB_MINIMUM}" ]] \
    || die "Incomplete requirements parsed for release-${TARGET_VERSION}."

  REQUIREMENTS_SOURCE="https://raw.githubusercontent.com/qbittorrent/qBittorrent/release-${TARGET_VERSION}/CMakeLists.txt (+ CommonConfig.cmake)"
  REQUIREMENTS_RESOLVED=1

  ok "Upstream-prescribed dependency floors for ${TARGET_VERSION}:"
  info "  CMake >= ${CMAKE_MIN_VERSION}"
  info "  C++ ${QBT_STDCVER}"
  info "  Qt >= ${QBT_QT_MINIMUM}"
  info "  libtorrent 1.x >= ${QBT_LIBTORRENT_MINIMUM} / 2.x >= ${QBT_LIBTORRENT2_MINIMUM}"
  info "  Boost >= ${QBT_BOOST_MINIMUM}"
  info "  OpenSSL >= ${QBT_OPENSSL_MINIMUM}"
  info "  zlib >= ${QBT_ZLIB_MINIMUM}"
  info "  Source: ${REQUIREMENTS_SOURCE}"
  info "These floors drive Qt/libtorrent/Boost/CMake planning for this run only."
}

# -----------------------------------------------------------------------------
# Dependency planning (from dynamic upstream requirements)
# -----------------------------------------------------------------------------
plan_dependencies() {
  info "Planning dependencies from resolved requirements..."
  [[ -n "${QBT_QT_MINIMUM}" && -n "${CMAKE_MIN_VERSION}" && -n "${QBT_STDCVER}" ]] \
    || die "Requirements not set - did resolve_requirements_from_upstream fail?"

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
    warn "Qt ${CURRENT_QT_VERSION:-missing} < ${QBT_QT_MINIMUM}. Planned: install qt6-swizzin (+ zlib-ng) - NO Qt source compilation."
  fi

  if [[ -z "${CURRENT_CMAKE_VERSION}" ]] || version_lt "${CURRENT_CMAKE_VERSION}" "${CMAKE_MIN_VERSION}"; then
    NEED_CMAKE_SWIZZIN=1
    warn "CMake ${CURRENT_CMAKE_VERSION:-missing} < ${CMAKE_MIN_VERSION} -> cmake-swizzin planned."
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
    # Only auto-select 2.x minima when the user did not force RC_1_2.
    if [[ "${LIBTORRENT_BRANCH_OVERRIDE:-}" != "RC_1_2" ]]; then
      lt_needed="${QBT_LIBTORRENT2_MINIMUM}"
    fi
  fi

  # Upstream INSTALL (5.3.0): libtorrent 1.2.19-1.2.x or 2.0.10-2.0.x.
  # Default RC_1_2 tracks the newest v1.2.* tag (Swizzin-compatible).
  info "libtorrent plan: branch ${branch}, minimum ${lt_needed} (upstream 1.x>=${QBT_LIBTORRENT_MINIMUM} / 2.x>=${QBT_LIBTORRENT2_MINIMUM})."

  if [[ -n "${CURRENT_LIBTORRENT_VERSION}" ]] \
     && version_ge "${CURRENT_LIBTORRENT_VERSION}" "${lt_needed}" \
     && [[ -f /usr/local/lib/libtorrent-rasterbar.a ]]; then
    if dpkg -s libtorrent-rasterbar 2>/dev/null | grep -q "${QBT_STDCVER}"; then
      NEED_LIBTORRENT_BUILD=0
      ok "Existing static libtorrent ${CURRENT_LIBTORRENT_VERSION} is compatible (>= ${lt_needed}, ${QBT_STDCVER}) - will be reused."
    else
      NEED_LIBTORRENT_BUILD=1
      warn "libtorrent present, but C++ standard tag (${QBT_STDCVER}) not confirmed -> rebuild planned (${branch})."
    fi
  else
    NEED_LIBTORRENT_BUILD=1
    info "libtorrent build planned (branch ${branch}, minimum ${lt_needed})."
  fi

  # Honour explicit --libtorrent: rebuild when installed major series does not match the requested branch.
  if [[ -n "${LIBTORRENT_BRANCH_OVERRIDE}" ]]; then
    local want_major=1
    [[ "${LIBTORRENT_BRANCH_OVERRIDE}" == "RC_2_0" ]] && want_major=2
    local have_major=""
    if [[ "${CURRENT_LIBTORRENT_VERSION}" =~ ^([0-9]+)\. ]]; then
      have_major="${BASH_REMATCH[1]}"
    fi
    if [[ "${have_major}" != "${want_major}" ]]; then
      NEED_LIBTORRENT_BUILD=1
      warn "--libtorrent ${LIBTORRENT_BRANCH_OVERRIDE} requested; installed ${CURRENT_LIBTORRENT_VERSION:-none} is not ${want_major}.x -> rebuild planned."
    fi
  fi

  NEED_BOOST=1
  BOOST_VERSION="$(pick_boost_version_for_minimum "${QBT_BOOST_MINIMUM}")"
  BOOST_ROOT_DIR="/opt/boost_${BOOST_VERSION}"
  info "Boost target: ${BOOST_VERSION} (minimum from source: ${QBT_BOOST_MINIMUM})"

  if command -v fpm >/dev/null 2>&1; then
    FPM_AVAILABLE=1
  else
    FPM_AVAILABLE=0
    info "fpm missing - will be installed via gem (same as Swizzin install_fpm)."
  fi

  if [[ -n "${QBT_OPENSSL_MINIMUM}" ]]; then
    if [[ -z "${OPENSSL_VERSION_FOUND}" ]]; then
      die "OpenSSL version unknown - upstream requires >= ${QBT_OPENSSL_MINIMUM}. Install openssl/libssl and retry."
    elif version_lt "${OPENSSL_VERSION_FOUND}" "${QBT_OPENSSL_MINIMUM}"; then
      die "OpenSSL ${OPENSSL_VERSION_FOUND} < required ${QBT_OPENSSL_MINIMUM} (from upstream). Upgrade libssl before continuing."
    else
      ok "OpenSSL ${OPENSSL_VERSION_FOUND} satisfies >= ${QBT_OPENSSL_MINIMUM}"
    fi
  fi

  if [[ -n "${QBT_ZLIB_MINIMUM}" ]]; then
    if [[ -z "${ZLIB_VERSION_FOUND}" ]]; then
      if [[ "${NEED_ZLIB_NG}" -eq 1 ]]; then
        info "zlib version unknown; zlib-ng via Swizzin crossbuild is planned (upstream requires >= ${QBT_ZLIB_MINIMUM})."
      else
        die "zlib version unknown - upstream requires >= ${QBT_ZLIB_MINIMUM}. Install zlib1g-dev / pkg-config zlib and retry."
      fi
    elif version_lt "${ZLIB_VERSION_FOUND}" "${QBT_ZLIB_MINIMUM}"; then
      if [[ "${NEED_ZLIB_NG}" -eq 1 ]]; then
        info "System zlib ${ZLIB_VERSION_FOUND} < ${QBT_ZLIB_MINIMUM}; zlib-ng via Swizzin crossbuild is already planned."
      else
        die "zlib ${ZLIB_VERSION_FOUND} < required ${QBT_ZLIB_MINIMUM} (from upstream)."
      fi
    else
      ok "zlib ${ZLIB_VERSION_FOUND} satisfies >= ${QBT_ZLIB_MINIMUM}"
    fi
  fi
}

github_latest_tag() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))"
}

# HEAD-check planned Swizzin cross-build DEBs so dry-run / preflight fail before stopping services.
preflight_remote_assets() {
  local -a checks=()
  if [[ "${NEED_ZLIB_NG}" -eq 1 ]]; then
    checks+=("${ZLIB_NG_CROSSBUILD_REPO}|zlib-ng")
  fi
  if [[ "${NEED_QT6_SWIZZIN}" -eq 1 ]]; then
    checks+=("${QT6_CROSSBUILD_REPO}|qt6-swizzin")
  fi
  if [[ "${NEED_CMAKE_SWIZZIN}" -eq 1 ]]; then
    checks+=("${CMAKE_CROSSBUILD_REPO}|cmake-swizzin")
  fi
  if [[ ${#checks[@]} -eq 0 ]]; then
    return 0
  fi

  info "Preflight: verifying Swizzin cross-build release assets are reachable..."
  local entry repo asset_suffix tag asset url
  for entry in "${checks[@]}"; do
    repo="${entry%%|*}"
    asset_suffix="${entry#*|}"
    tag="$(github_latest_tag "${repo}")"
    [[ -n "${tag}" ]] || die "Preflight: could not resolve latest release for ${repo}."
    asset="debian-${OS_CODENAME}-${asset_suffix}-${DPKG_ARCH}.deb"
    url="https://github.com/${repo}/releases/download/${tag}/${asset}"
    info "Preflight HEAD: ${url}"
    if ! curl -fsSIL --connect-timeout 15 --max-time 45 "${url}" >/dev/null 2>&1; then
      die "Preflight: missing or unreachable asset ${asset} (${repo} ${tag}). Aborting before stopping services."
    fi
    ok "Preflight OK: ${asset} (${tag})"
  done
}

find_deb_by_name_version() {
  # Locate pkg in DIST_DIR by exact dpkg Version. Prefer Version match over filename heuristics.
  # fpm often writes NAME_VERSION.deb (no arch); sometimes NAME_VERSION_ARCH.deb.
  local pkg_name="$1"
  local pkg_ver="$2"
  local deb="" candidate ver
  shopt -s nullglob
  local -a candidates=(
    "${DIST_DIR}/${pkg_name}_${pkg_ver}.deb"
    "${DIST_DIR}/${pkg_name}_${pkg_ver}_"*.deb
    "${DIST_DIR}/${pkg_name}_"*.deb
  )
  shopt -u nullglob
  for candidate in "${candidates[@]+"${candidates[@]}"}"; do
    [[ -f "${candidate}" ]] || continue
    ver="$(dpkg-deb -f "${candidate}" Version 2>/dev/null || true)"
    if [[ "${ver}" == "${pkg_ver}" ]]; then
      deb="${candidate}"
      break
    fi
  done
  printf '%s' "${deb}"
}

find_qbittorrent_deb() {
  find_deb_by_name_version "qbittorrent-nox" "$1"
}

find_libtorrent_deb() {
  find_deb_by_name_version "libtorrent-rasterbar" "$1"
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
qBittorrent target:  ${TARGET_VERSION} (series ${SERIES}.x)$([[ ${RESOLVE_LATEST_BETA} -eq 1 ]] && echo ", pre-release [--beta]" || echo ", stable")$([[ ${RESOLVE_LATEST_STABLE} -eq 1 ]] && echo " [latest from GitHub]" || true)
Requirements from:   ${REQUIREMENTS_SOURCE:-not resolved yet} (upstream for release-${TARGET_VERSION})
  Qt minimum:        ${QBT_QT_MINIMUM} (method: ${QT_METHOD}$([[ ${NEED_QT6_SWIZZIN} -eq 1 ]] && echo ", install qt6-swizzin" || true))
  libtorrent min:    1.x>=${QBT_LIBTORRENT_MINIMUM} / 2.x>=${QBT_LIBTORRENT2_MINIMUM} (branch ${LIBTORRENT_BRANCH_OVERRIDE:-${QBT_LIBTORRENT_BRANCH_DEFAULT}})
  Boost minimum:     ${QBT_BOOST_MINIMUM} -> use ${BOOST_VERSION}
  OpenSSL minimum:   ${QBT_OPENSSL_MINIMUM} (system: ${OPENSSL_VERSION_FOUND:-unknown})
  zlib minimum:      ${QBT_ZLIB_MINIMUM} (system: ${ZLIB_VERSION_FOUND:-unknown})
  CMake minimum:     ${CMAKE_MIN_VERSION}
  C++ standard:      ${QBT_STDCVER}
libtorrent current:  ${CURRENT_LIBTORRENT_VERSION:-unknown}
libtorrent action:   $([[ ${NEED_LIBTORRENT_BUILD} -eq 1 ]] && echo "build+package" || echo "reuse")
Qt current:          ${CURRENT_QT_VERSION:-unknown}
CMake:               ${CURRENT_CMAKE_VERSION:-unknown}$([[ ${NEED_CMAKE_SWIZZIN} -eq 1 ]] && echo " -> cmake-swizzin" || true)
Ninja:               ${CURRENT_NINJA_VERSION:-unknown}
Boost path:          ${BOOST_ROOT_DIR}
Build type:          CMake + Ninja, GUI=OFF WEBUI=ON (qbittorrent-nox); PLUGINS left at upstream default (ON in 5.3+, bundled Lua)
Source directory:    ${SOURCE_DIR}
Build directory:     ${BUILD_DIR}
Staging:             ${STAGE_DIR}
Install path:        /usr (via Debian package qbittorrent-nox, as in Swizzin)
Package output:      ${DIST_DIR}/qbittorrent-nox_$(qbt_to_deb_version "${TARGET_VERSION}")_*.deb
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
  - $([[ ${NEED_LIBTORRENT_BUILD} -eq 1 ]] && echo "build static libtorrent-rasterbar (${LIBTORRENT_BRANCH_OVERRIDE:-${QBT_LIBTORRENT_BRANCH_DEFAULT}}, >=${QBT_LIBTORRENT_MINIMUM} / >=${QBT_LIBTORRENT2_MINIMUM}) and install as DEB" || echo "reuse libtorrent")
  - Build qBittorrent ${TARGET_VERSION} from official source (GUI=OFF, WEBUI=ON)
  - Create fpm package qbittorrent-nox_$(qbt_to_deb_version "${TARGET_VERSION}")_*.deb and install via dpkg -i
  - apt-mark hold qbittorrent-nox (Swizzin behaviour)
  - Restart previously active services; leave inactive ones stopped
  - Check WebUI reachability locally
  - nginx: $(if series_ge_52 "${SERIES}"; then echo "backup ${NGINX_QBT_CONF} -> ${NGINX_QBT_CONF_ORIG}, write 5.2+ proxy config before package install (test+restore on failure)"; else echo "skip (series ${SERIES:-?} < 5.2)"; fi)
  - Per user: cp ~/.config/qBittorrent/qBittorrent.conf -> qBittorrent.conf.orig (before qBittorrent build)
  - DO NOT change WebUI passwords in qBittorrent.conf
  - DO NOT modify /etc/swizzin (except the nginx app file under /etc/nginx/apps/)
=======================================
EOF

  emit_webui_notes
}

emit_webui_notes() {
  if ! series_ge_52 "${SERIES}"; then
    return 0
  fi
  cat <<'EOF'

[NOTE] qBittorrent 5.2+ WebUI / reverse proxy:
  - This script adapts /etc/nginx/apps/qbittorrent.conf for 5.2+ (strip Authorization header,
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

  info "Creating backup under ${BACKUP_DIR}..."
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

  # dpkg-repack for clean rollback; always try DIST fallback if repack missing or failed.
  PREV_QBT_DEB=""
  PREV_LIBTORRENT_DEB=""
  local prev_pkg_ver
  prev_pkg_ver="$(qbt_to_deb_version "${CURRENT_QBT_VERSION}")"

  if command -v dpkg-repack >/dev/null 2>&1 && dpkg -s qbittorrent-nox >/dev/null 2>&1; then
    info "Creating rollback package via dpkg-repack..."
    ( cd "${BACKUP_DIR}/packages" && dpkg-repack qbittorrent-nox ) >> "${LOG_FILE}" 2>&1 \
      || warn "dpkg-repack qbittorrent-nox failed - will try DIST / binary backup."
  else
    warn "dpkg-repack not available or qbittorrent-nox not dpkg-managed - trying DIST / binary backup."
  fi
  # If no repacked .deb yet, copy a Version-verified package from DIST (handles ~ pre-releases).
  if ! ls -1 "${BACKUP_DIR}/packages"/qbittorrent-nox_*.deb >/dev/null 2>&1; then
    local olddeb=""
    olddeb="$(find_deb_by_name_version "qbittorrent-nox" "${prev_pkg_ver}")"
    if [[ -n "${olddeb}" && -f "${olddeb}" ]]; then
      cp -a -- "${olddeb}" "${BACKUP_DIR}/packages/" || true
      info "Copied existing dist package: ${olddeb}"
    fi
  fi

  if command -v dpkg-repack >/dev/null 2>&1 && dpkg -s libtorrent-rasterbar >/dev/null 2>&1; then
    info "Creating libtorrent rollback package via dpkg-repack..."
    ( cd "${BACKUP_DIR}/packages" && dpkg-repack libtorrent-rasterbar ) >> "${LOG_FILE}" 2>&1 \
      || warn "dpkg-repack libtorrent-rasterbar failed - will try DIST."
  fi
  if ! ls -1 "${BACKUP_DIR}/packages"/libtorrent-rasterbar_*.deb >/dev/null 2>&1; then
    local lt_old=""
    if [[ -n "${CURRENT_LIBTORRENT_VERSION}" ]]; then
      lt_old="$(find_deb_by_name_version "libtorrent-rasterbar" "${CURRENT_LIBTORRENT_VERSION}")"
    fi
    if [[ -n "${lt_old}" && -f "${lt_old}" ]]; then
      cp -a -- "${lt_old}" "${BACKUP_DIR}/packages/" || true
      info "Copied existing libtorrent dist package: ${lt_old}"
    fi
  fi

  PREV_QBT_DEB="$(ls -1t "${BACKUP_DIR}/packages"/qbittorrent-nox_*.deb 2>/dev/null | head -n1 || true)"
  PREV_LIBTORRENT_DEB="$(ls -1t "${BACKUP_DIR}/packages"/libtorrent-rasterbar_*.deb 2>/dev/null | head -n1 || true)"
  # Verify PREV_QBT_DEB Version matches current install; empty Version is not trusted.
  if [[ -n "${PREV_QBT_DEB}" ]]; then
    local prev_ver
    prev_ver="$(dpkg-deb -f "${PREV_QBT_DEB}" Version 2>/dev/null || true)"
    if [[ -z "${prev_ver}" ]]; then
      warn "Backup qbittorrent .deb has empty Version - ignoring for recovery."
      PREV_QBT_DEB=""
    elif [[ "${prev_ver}" != "${prev_pkg_ver}" && "${prev_ver}" != "${CURRENT_QBT_VERSION}" ]]; then
      warn "Backup qbittorrent .deb Version ${prev_ver} != installed ${CURRENT_QBT_VERSION}/${prev_pkg_ver} - ignoring for recovery."
      PREV_QBT_DEB=""
    else
      info "Previous qbittorrent .deb for recovery: ${PREV_QBT_DEB}"
    fi
  fi
  if [[ -n "${PREV_LIBTORRENT_DEB}" ]]; then
    local lt_prev_ver lt_base
    lt_prev_ver="$(dpkg-deb -f "${PREV_LIBTORRENT_DEB}" Version 2>/dev/null || true)"
    lt_base="${lt_prev_ver%%-*}"
    if [[ -z "${lt_prev_ver}" ]]; then
      warn "Backup libtorrent .deb has empty Version - ignoring for recovery."
      PREV_LIBTORRENT_DEB=""
    elif [[ -n "${CURRENT_LIBTORRENT_VERSION}" \
         && "${lt_prev_ver}" != "${CURRENT_LIBTORRENT_VERSION}" \
         && "${lt_base}" != "${CURRENT_LIBTORRENT_VERSION}" ]]; then
      warn "Backup libtorrent .deb Version ${lt_prev_ver} != ${CURRENT_LIBTORRENT_VERSION} - ignoring."
      PREV_LIBTORRENT_DEB=""
    else
      info "Previous libtorrent .deb for recovery: ${PREV_LIBTORRENT_DEB}"
    fi
  fi

  if [[ "${NEED_LIBTORRENT_BUILD}" -eq 1 ]] && dpkg -s libtorrent-rasterbar >/dev/null 2>&1 \
     && [[ -z "${PREV_LIBTORRENT_DEB}" ]]; then
    die "libtorrent-rasterbar is installed and will be rebuilt, but no rollback .deb was created. Install/fix dpkg-repack (or place a matching .deb in ${DIST_DIR}) and retry."
  fi
  # Require a recovery artifact whenever we will replace qbittorrent (packaged or not).
  if [[ -z "${PREV_QBT_DEB}" && ! -x "${BACKUP_DIR}/bin/qbittorrent-nox.prev" ]]; then
    die "No qbittorrent-nox rollback .deb or binary backup available. Install dpkg-repack and/or ensure the binary is readable, then retry."
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

  # Pointer to latest backup (manual recovery; --rollback uses Swizzin box upgrade)
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

# Resolve the qBittorrent series Swizzin currently offers first (after Repo) for this OS,
# then the latest stable patch of that series - matching Swizzin whiptail defaults.
resolve_swizzin_stable_version() {
  info "Resolving Swizzin current stable qBittorrent..."

  local codename="${OS_CODENAME:-}"
  if [[ -z "${codename}" && -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    codename="${VERSION_CODENAME:-}"
  fi
  [[ -n "${codename}" ]] || die "Could not determine OS codename for Swizzin version lookup."

  local func_txt=""
  local func_source=""
  # Prefer the local Swizzin function (matches what `box upgrade` will actually accept).
  if [[ -n "${SWIZZIN_QBT_FUNC}" && -f "${SWIZZIN_QBT_FUNC}" ]]; then
    func_txt="$(cat "${SWIZZIN_QBT_FUNC}" 2>/dev/null || true)"
    func_source="${SWIZZIN_QBT_FUNC}"
  elif [[ -f /etc/swizzin/sources/functions/qbittorrent ]]; then
    SWIZZIN_QBT_FUNC="/etc/swizzin/sources/functions/qbittorrent"
    func_txt="$(cat "${SWIZZIN_QBT_FUNC}" 2>/dev/null || true)"
    func_source="${SWIZZIN_QBT_FUNC}"
  fi
  if [[ -z "${func_txt}" ]]; then
    info "Local Swizzin qbittorrent function missing - falling back to GitHub master."
    func_txt="$(curl -fsSL "${SWIZZIN_QBT_FUNC_URL}" 2>/dev/null || true)"
    func_source="${SWIZZIN_QBT_FUNC_URL}"
  fi
  if [[ -z "${func_txt}" ]]; then
    die "Could not read Swizzin qbittorrent function (local or ${SWIZZIN_QBT_FUNC_URL})."
  fi
  info "Using Swizzin qbittorrent function from: ${func_source}"

  local series=""
  series="$(
    CODENAME_ENV="${codename}" python3 -c '
import os, re, sys
text = sys.stdin.read()
codename = os.environ.get("CODENAME_ENV", "").strip().lower()

m = re.search(r"function whiptail_qbittorrent\(\)\s*\{(.*?)^\}", text, re.S | re.M)
if not m:
    sys.exit("whiptail_qbittorrent not found")
body = m.group(1)
cm = re.search(r"case \$\{?codename\}? in(.*?)esac", body, re.S)
if not cm:
    sys.exit("codename case not found")
case_body = cm.group(1)

def parse_arm(arm_body):
    for lab in re.findall(r"\"(\d+\.\d+|Repo)\"", arm_body):
        if lab != "Repo":
            return lab
    return ""

# Only real case labels: "buster") / "bullseye" | "focal") / *)
# Reject whiptail lines like "4.1" "(${latestv41})" ... )
label_line = re.compile(
    r"(?m)^[ \t]*("
    r"(?:\"(?!\d+\.\d)[^\"]+\"(?:[ \t]*\|[ \t]*)*)+"
    r"|\*"
    r")\)[ \t]*$"
)

lines = case_body.splitlines()
indices = []
for i, line in enumerate(lines):
    if label_line.match(line):
        indices.append(i)

chosen = ""
fallback_star = ""
for n, start in enumerate(indices):
    end = indices[n + 1] if n + 1 < len(indices) else len(lines)
    key_line = lines[start]
    arm = "\n".join(lines[start + 1 : end])
    km = label_line.match(key_line)
    key = km.group(1).strip()
    if key == "*":
        fallback_star = parse_arm(arm)
        continue
    names = [n.lower() for n in re.findall(r"\"([^\"]+)\"", key)]
    if codename in names:
        chosen = parse_arm(arm)
        break

if not chosen:
    chosen = fallback_star

if not chosen:
    series_list = re.findall(r"latestv(\d)(\d)\b", body)
    if series_list:
        best = max((int(a), int(b)) for a, b in series_list)
        chosen = f"{best[0]}.{best[1]}"

if not chosen:
    sys.exit("no series")
print(chosen)
' <<< "${func_txt}" 2>/dev/null || true
  )"

  if [[ -z "${series}" ]]; then
    # Safe Debian-12 / bookworm fallback matching current Swizzin master menu
    warn "Could not parse Swizzin menu for codename=${codename}; falling back to series 5.1."
    series="5.1"
  fi

  info "Swizzin preferred series for ${codename}: ${series}.x"

  local tags=""
  tags="$(resolve_qbt_tags series "${series}")"

  local ver
  ver="$(printf '%s\n' "${tags}" | head -n1)"
  [[ -n "${ver}" ]] || die "Could not resolve latest stable for Swizzin series ${series}.x"
  ok "Swizzin stable target: ${ver}"
  printf '%s' "${ver}"
}

restore_nginx_from_orig() {
  if [[ -f "${NGINX_QBT_CONF_ORIG}" ]]; then
    info "Restoring nginx config from ${NGINX_QBT_CONF_ORIG}..."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      info "DRY-RUN: would restore nginx from .orig"
      return 0
    fi
    local live_bak="" bak_ok=0
    live_bak="$(mktemp "${NGINX_QBT_CONF}.rollback.XXXXXX")"
    if [[ -f "${NGINX_QBT_CONF}" ]] && cp -a -- "${NGINX_QBT_CONF}" "${live_bak}" 2>/dev/null && [[ -s "${live_bak}" ]]; then
      bak_ok=1
    else
      rm -f -- "${live_bak}" 2>/dev/null || true
      live_bak=""
    fi
    run_cmd cp -a -- "${NGINX_QBT_CONF_ORIG}" "${NGINX_QBT_CONF}"
    if command -v nginx >/dev/null 2>&1; then
      if ! nginx -t >> "${LOG_FILE}" 2>&1; then
        error "nginx -t failed after restoring .orig - putting previous live config back."
        if [[ "${bak_ok}" -eq 1 && -n "${live_bak}" && -s "${live_bak}" ]]; then
          cp -a -- "${live_bak}" "${NGINX_QBT_CONF}" || true
        fi
        [[ -n "${live_bak}" ]] && rm -f -- "${live_bak}" 2>/dev/null || true
        die "nginx configuration test failed after rollback restore. See ${LOG_FILE}"
      fi
      if ! systemctl reload nginx >> "${LOG_FILE}" 2>&1; then
        error "nginx reload failed after restoring .orig - putting previous live config back."
        if [[ "${bak_ok}" -eq 1 && -n "${live_bak}" && -s "${live_bak}" ]]; then
          cp -a -- "${live_bak}" "${NGINX_QBT_CONF}" || true
        fi
        [[ -n "${live_bak}" ]] && rm -f -- "${live_bak}" 2>/dev/null || true
        die "nginx reload failed after rollback restore. See ${LOG_FILE}"
      fi
    fi
    [[ -n "${live_bak}" ]] && rm -f -- "${live_bak}" 2>/dev/null || true
    ok "nginx qbittorrent.conf restored to pre-upgrade (Swizzin) copy"
  else
    info "No ${NGINX_QBT_CONF_ORIG} - leaving nginx config unchanged."
  fi
}

do_rollback() {
  require_root
  _ensure_log
  info "Starting rollback via Swizzin box upgrade..."

  if ! command -v box >/dev/null 2>&1; then
    die "'box' not found in PATH - is Swizzin installed?"
  fi

  probe_os
  local swizzin_ver
  swizzin_ver="$(resolve_swizzin_stable_version)"
  [[ -n "${swizzin_ver}" ]] || die "Empty Swizzin stable version."
  apply_versioned_paths "${swizzin_ver}"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "DRY-RUN rollback plan:"
    info "  Target: qBittorrent ${swizzin_ver} (preferred series from local Swizzin function, else GitHub)"
    info "  Command: QBITTORRENT_VERSION=${swizzin_ver} box upgrade qbittorrent"
    info "  apt-mark unhold qbittorrent-nox, then box upgrade"
    info "  nginx: restore .orig only if target series < 5.2; keep 5.2+ snippet otherwise"
    ok "DRY-RUN complete - no changes made."
    return 0
  fi

  confirm "Roll back to Swizzin stable qBittorrent ${swizzin_ver} via box upgrade?"

  # Hold must not block Swizzin/apt paths; dpkg -i usually ignores hold, but unhold is safer.
  if dpkg -s qbittorrent-nox >/dev/null 2>&1; then
    info "Removing apt-mark hold on qbittorrent-nox before box upgrade..."
    run_cmd --allow-fail apt-mark unhold qbittorrent-nox || true
  fi

  info "Running: QBITTORRENT_VERSION=${swizzin_ver} box upgrade qbittorrent"
  # Export so child processes / sourced upgrade scripts see it (skips whiptail)
  export QBITTORRENT_VERSION="${swizzin_ver}"
  if ! QBITTORRENT_VERSION="${swizzin_ver}" box upgrade qbittorrent; then
    die "box upgrade qbittorrent failed (QBITTORRENT_VERSION=${swizzin_ver}). nginx left unchanged."
  fi

  # Restore Swizzin nginx only after a successful box upgrade, and only when the
  # rolled-back target is older than 5.2 (5.2+ still needs the Authorization strip).
  local rb_series
  rb_series="$(printf '%s' "${swizzin_ver}" | cut -d. -f1-2)"
  if series_ge_52 "${rb_series}"; then
    info "Rollback target ${swizzin_ver} is series ${rb_series}.x >= 5.2 - keeping current 5.2+ nginx snippet (not restoring .orig)."
  else
    restore_nginx_from_orig
  fi

  local ver
  ver="$(qbittorrent-nox --version 2>/dev/null || true)"
  ok "Rollback complete via Swizzin. Reported version: ${ver}"
  info "Installed with: QBITTORRENT_VERSION=${swizzin_ver} box upgrade qbittorrent"
}

# -----------------------------------------------------------------------------
# nginx reverse proxy for qBittorrent 5.2+/5.3.x (Swizzin multi-user)
# -----------------------------------------------------------------------------
write_nginx_qbittorrent_52_conf() {
  local dest="$1"
  cat > "${dest}" <<'QBTNGINX'
location /qbt {
    return 301 /qbittorrent/;
}
location /qbittorrent/ {
    # Multi-user: panel user -> upstream user.qbittorrent (127.0.0.1:WEBUI-PORT)
    proxy_pass         http://$remote_user.qbittorrent;
    proxy_http_version 1.1;
    proxy_set_header Host              $http_host;
    proxy_set_header X-Forwarded-Host  $http_host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    # qBittorrent 5.2+/5.3.x validates Basic Auth itself.
    # Panel auth (/etc/htpasswd) must NOT be forwarded to the instance,
    # or you get Unauthorized when panel password != qBittorrent WebUI password.
    proxy_set_header Authorization "";
    # Optional only if panel password === qBittorrent WebUI password (per user):
    # remove the Authorization "" line for SSO-like Basic Auth passthrough.
    http2_push_preload on;
    auth_basic           "Password required";
    auth_basic_user_file /etc/htpasswd;
    rewrite ^/qbittorrent/(.*) /$1 break;
    proxy_cookie_path / "/qbittorrent/; Secure";
    proxy_buffering off;
    proxy_read_timeout 600s;
}
QBTNGINX
}

apply_nginx_qbittorrent_52() {
  if ! series_ge_52 "${SERIES}"; then
    info "Target series ${SERIES:-unknown}.x < 5.2 - skipping 5.2+ nginx reverse-proxy adaptation."
    return 0
  fi

  info "Updating nginx reverse proxy for qBittorrent ${SERIES}.x+ (Authorization strip / forwarded headers)..."

  if [[ ! -f "${NGINX_QBT_CONF}" ]]; then
    warn "${NGINX_QBT_CONF} not found - skipping nginx adaptation."
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    info "DRY-RUN: would copy ${NGINX_QBT_CONF} to ${NGINX_QBT_CONF_ORIG} and write 5.2+ proxy config."
    return 0
  fi

  local stamped_bak=""
  # Preserve the original only once so re-runs do not overwrite the true original
  if [[ ! -f "${NGINX_QBT_CONF_ORIG}" ]]; then
    info "Backup (cp): ${NGINX_QBT_CONF} -> ${NGINX_QBT_CONF_ORIG}"
    run_cmd cp -a -- "${NGINX_QBT_CONF}" "${NGINX_QBT_CONF_ORIG}"
    NGINX_RESTORE_SOURCE="${NGINX_QBT_CONF_ORIG}"
  else
    info "${NGINX_QBT_CONF_ORIG} already exists - will not overwrite."
    stamped_bak="${NGINX_QBT_CONF}.bak.$(date '+%Y%m%d-%H%M%S')"
    run_cmd cp -a -- "${NGINX_QBT_CONF}" "${stamped_bak}"
    NGINX_RESTORE_SOURCE="${stamped_bak}"
  fi

  # Also copy into the upgrade backup if create_backup ran earlier
  if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
    mkdir -p "${BACKUP_DIR}/nginx"
    if [[ -f "${NGINX_QBT_CONF_ORIG}" ]]; then
      cp -a -- "${NGINX_QBT_CONF_ORIG}" "${BACKUP_DIR}/nginx/qbittorrent.conf.orig" || true
    fi
  fi

  # Write to a temp file first so a failed/partial write never truncates the live conf.
  local nginx_tmp
  nginx_tmp="$(mktemp "${NGINX_QBT_CONF}.new.XXXXXX")"
  NGINX_NEEDS_RESTORE=1
  if ! write_nginx_qbittorrent_52_conf "${nginx_tmp}"; then
    rm -f -- "${nginx_tmp}" 2>/dev/null || true
    restore_nginx_after_failed_write
    die "Failed to write nginx config draft for ${NGINX_QBT_CONF}"
  fi
  if ! mv -f -- "${nginx_tmp}" "${NGINX_QBT_CONF}"; then
    rm -f -- "${nginx_tmp}" 2>/dev/null || true
    restore_nginx_after_failed_write
    die "Failed to install nginx config at ${NGINX_QBT_CONF}"
  fi
  ok "nginx config written: ${NGINX_QBT_CONF}"

  if command -v nginx >/dev/null 2>&1; then
    if ! nginx -t >> "${LOG_FILE}" 2>&1; then
      error "nginx -t failed after writing ${NGINX_QBT_CONF} - restoring previous config."
      restore_nginx_after_failed_write
      die "nginx configuration test failed - previous config restored (qbittorrent package not yet replaced). See ${LOG_FILE}"
    fi
    # Keep restore armed until reload succeeds (file is new; workers may still serve old conf).
    if ! systemctl reload nginx >> "${LOG_FILE}" 2>&1; then
      error "nginx reload failed - restoring previous config."
      restore_nginx_after_failed_write
      die "nginx reload failed - previous config restored. See ${LOG_FILE}"
    fi
    # Keep NGINX_NEEDS_RESTORE=1 until the new qbittorrent package is installed / upgrade succeeds.
    ok "nginx reloaded."
  else
    warn "nginx binary not found - config written, but not reloaded."
    # Keep restore armed until package install succeeds.
  fi
}

# -----------------------------------------------------------------------------
# Per-user backup: qBittorrent.conf -> qBittorrent.conf.orig
# -----------------------------------------------------------------------------
backup_user_qbittorrent_confs() {
  info "Backing up per-user qBittorrent.conf to qBittorrent.conf.orig..."

  if [[ ${#CONFIG_PATHS[@]} -eq 0 ]]; then
    warn "No qBittorrent config directories found - skipping user config backup."
    return 0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    local conf_dir
    for conf_dir in "${CONFIG_PATHS[@]}"; do
      local conf_file="${conf_dir}/qBittorrent.conf"
      local orig_file="${conf_dir}/qBittorrent.conf.orig"
      if [[ -f "${conf_file}" ]]; then
        info "DRY-RUN: would cp -a ${conf_file} -> ${orig_file}"
      fi
    done
    return 0
  fi

  local conf_dir conf_file orig_file count=0
  for conf_dir in "${CONFIG_PATHS[@]}"; do
    conf_file="${conf_dir}/qBittorrent.conf"
    orig_file="${conf_dir}/qBittorrent.conf.orig"

    if [[ ! -f "${conf_file}" ]]; then
      info "No qBittorrent.conf in ${conf_dir} - skipped."
      continue
    fi

    # Preserve live config ownership/permissions on .orig
    local conf_owner conf_group
    conf_owner="$(stat -c '%u' "${conf_file}" 2>/dev/null || true)"
    conf_group="$(stat -c '%g' "${conf_file}" 2>/dev/null || true)"

    if [[ ! -f "${orig_file}" ]]; then
      info "Backup (cp): ${conf_file} -> ${orig_file}"
      run_cmd cp -a -- "${conf_file}" "${orig_file}"
    else
      info "${orig_file} already exists - original left intact."
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
    info "No qBittorrent service was running before the upgrade - none will be started automatically."
  fi
}

# -----------------------------------------------------------------------------
# Build dependency installation
# -----------------------------------------------------------------------------
maybe_remount_build_dirs_exec() {
  # Builds use WORK_ROOT (default under /var/tmp); also remount /tmp if noexec (booststrap / tools).
  local path mnt opts
  local -a candidates=()
  candidates+=("/tmp")
  if [[ -n "${WORK_ROOT}" ]]; then
    mkdir -p "${WORK_ROOT}" 2>/dev/null || true
    candidates+=("${WORK_ROOT}")
  else
    candidates+=("/var/tmp")
  fi

  for path in "${candidates[@]}"; do
    opts="$(findmnt -n -o OPTIONS --target "${path}" 2>/dev/null || true)"
    [[ -n "${opts}" ]] || continue
    case ",${opts}," in
      *,noexec,*) ;;
      *) continue ;;
    esac
    mnt="$(findmnt -n -o TARGET --target "${path}" 2>/dev/null || true)"
    [[ -n "${mnt}" ]] || continue
    # Skip if we already remounted this mountpoint
    local already=0 existing
    for existing in "${EXEC_REMOUNT_TARGETS[@]+"${EXEC_REMOUNT_TARGETS[@]}"}"; do
      if [[ "${existing}" == "${mnt}" ]]; then already=1; break; fi
    done
    if [[ "${already}" -eq 1 ]]; then
      continue
    fi
    info "${mnt} is mounted noexec (needed for builds under ${path}) - remounting exec..."
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      mount -o remount,exec "${mnt}" >> "${LOG_FILE}" 2>&1 \
        || die "Failed to remount ${mnt} as exec."
      EXEC_REMOUNT_TARGETS+=("${mnt}")
    fi
  done
}

apt_install_packages() {
  info "Installing build dependencies via apt..."
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
    info "Installing fpm via gem..."
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
      info "Ensuring repository Qt6 packages..."
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
    # Require a usable Boost tree (incomplete extract/bootstrap must not be treated as success).
    if [[ -f "${BOOST_ROOT_DIR}/boost/version.hpp" || -f "${BOOST_ROOT_DIR}/boost/system/error_code.hpp" ]] \
       && { [[ -x "${BOOST_ROOT_DIR}/b2" ]] || [[ -x "${BOOST_ROOT_DIR}/bjam" ]]; }; then
      ok "Boost already present: ${BOOST_ROOT_DIR}"
      return 0
    fi
    warn "Incomplete Boost tree at ${BOOST_ROOT_DIR} - removing and reinstalling."
    rm -rf --one-file-system -- "${BOOST_ROOT_DIR}"
  fi
  info "Installing Boost ${BOOST_VERSION} to ${BOOST_ROOT_DIR} (Swizzin booststrap)..."
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
  info "Building static libtorrent (${branch}) - Swizzin procedure..."

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
    info "Applying patch /root/libtorrent-${branch}.patch..."
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
  ) >> "${LOG_FILE}" 2>&1 || die "libtorrent cmake/build/install failed - see ${LOG_FILE}"

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
      --description "Libtorrent rasterbar compiled by qbittorrent-upgrade${tagdesc}"
  ) >> "${LOG_FILE}" 2>&1 || die "fpm libtorrent failed."

  local lt_deb
  lt_deb="$(find_libtorrent_deb "${version}")"
  [[ -n "${lt_deb}" ]] || die "libtorrent-rasterbar .deb for version ${version} not found in ${DIST_DIR}"
  run_cmd dpkg -i "${lt_deb}"
  LIBTORRENT_PACKAGE_INSTALLED=1
  ok "libtorrent-rasterbar ${version} installed"
}

# -----------------------------------------------------------------------------
# qBittorrent build
# -----------------------------------------------------------------------------
verify_cmake_options_from_source() {
  local src="$1"
  info "Verifying CMake options in source tree ${TARGET_VERSION}..."
  local cmakelists="${src}/CMakeLists.txt"
  [[ -f "${cmakelists}" ]] || die "CMakeLists.txt missing in ${src}"

  if ! grep -q 'feature_option(GUI' "${cmakelists}"; then
    die "CMake option GUI is unexpectedly missing in ${TARGET_VERSION}."
  fi
  ok "CMake option GUI exists."

  local has_webui=0 has_qt6=0
  if grep -q 'feature_option(WEBUI' "${cmakelists}"; then
    has_webui=1
    ok "CMake option WEBUI exists - will force ON for qbittorrent-nox."
  else
    warn "CMake option WEBUI missing in ${TARGET_VERSION} - relying on upstream defaults."
  fi

  if grep -q 'feature_option(PLUGINS' "${cmakelists}"; then
    info "CMake option PLUGINS present (5.3+ Lua engine, bundled sources) - leaving upstream default (ON)."
  fi

  if grep -qE 'feature_option\(QT6|option\(QT6' "${cmakelists}" \
     || grep -rqE 'option\(QT6|feature_option\(QT6' "${src}/cmake" 2>/dev/null; then
    has_qt6=1
    info "CMake option QT6 exists in this source - will be set (Swizzin-compatible)."
  else
    # qBittorrent 5.2+/5.3.x is Qt6-only; Swizzin still passes -D QT6=ON but it is unused.
    info "CMake option QT6 does NOT exist in ${TARGET_VERSION} (Qt6-only). Parameter omitted (no invented flags)."
  fi

  local min_qt
  min_qt="$(grep -E 'set\(minQt6Version|set\(minQtVersion' "${cmakelists}" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
  if [[ -n "${min_qt}" ]]; then
    info "Source minQt version=${min_qt} (planned minimum was ${QBT_QT_MINIMUM})"
  fi

  echo "HAS_WEBUI=${has_webui}"
  echo "HAS_QT6=${has_qt6}"
}

build_qbittorrent() {
  info "Downloading qBittorrent source release-${TARGET_VERSION}..."
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

  local verify_out has_qt6=0 has_webui=0
  verify_out="$(verify_cmake_options_from_source "${SOURCE_DIR}")"
  if printf '%s\n' "${verify_out}" | grep -qx 'HAS_QT6=1'; then
    has_qt6=1
  fi
  if printf '%s\n' "${verify_out}" | grep -qx 'HAS_WEBUI=1'; then
    has_webui=1
  fi

  export CFLAGS="${CFLAGS:--O3 -march=native}"
  export CXXFLAGS="${CXXFLAGS:--O3 -march=native}"
  export PATH="/opt/local/bin:${PATH}"
  export BOOST_ROOT="${BOOST_ROOT_DIR}"
  export BOOST_INCLUDEDIR="${BOOST_ROOT_DIR}"

  local cxx_num="${QBT_STDCVER//[^0-9]/}"
  # Official INSTALL uses Release; Swizzin historically used lowercase "release".
  # We use Release (validated against upstream INSTALL for 5.2.x / 5.3.x).
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
  if [[ "${has_webui}" -eq 1 ]]; then
    cmake_args+=(-D WEBUI=ON)
  fi
  if [[ "${has_qt6}" -eq 1 ]]; then
    cmake_args+=(-D QT6=ON)
  fi

  info "CMake configuration: cmake ${cmake_args[*]}"
  (
    cd "${SOURCE_DIR}"
    cmake "${cmake_args[@]}"
    cmake --build build
    cmake --install build
  ) >> "${LOG_FILE}" 2>&1 || die "qBittorrent build failed - log: ${LOG_FILE}"

  if [[ ! -x "${STAGE_DIR}/usr/bin/qbittorrent-nox" ]]; then
    die "Build did not produce ${STAGE_DIR}/usr/bin/qbittorrent-nox"
  fi
  ok "qbittorrent-nox binary built."

  # Optional: qbt-cli like Swizzin (best-effort, non-fatal)
  install_qbt_cli_into_stage || warn "qbt-cli could not be added (non-critical)."

  local tagdesc=" static with ${QBT_STDCVER} O3 march=native"
  # Debian package version must use ~ for pre-releases (5.3.0~beta1 < 5.3.0).
  local pkg_ver
  pkg_ver="$(qbt_to_deb_version "${TARGET_VERSION}")"
  (
    fpm -f -C "${STAGE_DIR}" -p "${DIST_DIR}/qbittorrent-nox_VERSION.deb" \
      -s dir -t deb -n qbittorrent-nox --version "${pkg_ver}" \
      --description "qbittorrent-nox compiled by qbittorrent-upgrade${tagdesc}"
  ) >> "${LOG_FILE}" 2>&1 || die "fpm qbittorrent-nox failed."

  local deb
  deb="$(find_qbittorrent_deb "${pkg_ver}")"
  [[ -n "${deb}" ]] || die "qbittorrent-nox .deb for version ${pkg_ver} not found in ${DIST_DIR}"
  info "Installing ${deb} (package version ${pkg_ver}, no apt remove/purge)..."
  run_cmd dpkg -i "${deb}"
  QBT_PACKAGE_INSTALLED=1
  run_cmd apt-mark hold qbittorrent-nox
  # Keep NGINX_NEEDS_RESTORE armed until UPGRADE_SUCCEEDED so a later package
  # rollback can also restore nginx (see restore_nginx_after_failed_write).
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
  info "Verifying installation..."
  local newver
  newver="$(extract_qbt_version "$(qbittorrent-nox --version 2>/dev/null || true)")"
  info "Installed version: ${newver}"
  if [[ "${newver}" != "${TARGET_VERSION}" ]]; then
    die "Version mismatch: expected ${TARGET_VERSION}, found ${newver:-empty}"
  fi
  ok "Version ${newver} confirmed."

  local unit
  local inactive=0
  for unit in "${STARTED_SERVICES[@]+"${STARTED_SERVICES[@]}"}"; do
    if systemctl is-active --quiet "${unit}"; then
      ok "Service active: ${unit}"
    else
      error "Service not active after start: ${unit}"
      inactive=1
    fi
  done
  if [[ "${inactive}" -eq 1 ]]; then
    die "One or more previously active qBittorrent services failed to stay running after upgrade."
  fi

  check_webui_local
  emit_webui_notes
}

check_webui_local() {
  info "Checking local WebUI reachability (best-effort)..."
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
      # curl write-out format in a variable avoids fragile '%{http_code}' nesting.
      local curl_http_fmt='%{http_code}'
      code="$(curl -s -o /dev/null -w "${curl_http_fmt}" --connect-timeout 3 --max-time 5 "http://${addr}:${port}/" || true)"
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
  if [[ -n "${TARGET_VERSION_OVERRIDE}" ]]; then
    info "Mode: exact pin --version ${TARGET_VERSION_OVERRIDE} + deps from that tag"
  elif [[ "${RESOLVE_LATEST_BETA}" -eq 1 ]]; then
    info "Mode: current pre-release (--beta) + deps from that tag"
  else
    info "Mode: current GitHub stable (latest) + deps from that tag"
  fi

  probe_os
  probe_qbittorrent
  probe_libtorrent
  probe_qt
  probe_cmake_ninja
  probe_openssl
  probe_zlib
  probe_services
  probe_configs
  probe_swizzin_reference
  resolve_target_version
  apply_versioned_paths "${TARGET_VERSION}"
  # Disk check after versioned WORK_ROOT is known (honours QBT_UPGRADE_WORK).
  probe_disk_network
  resolve_requirements_from_upstream
  [[ "${REQUIREMENTS_RESOLVED}" -eq 1 ]] \
    || die "Upstream dependency floors were not resolved for ${TARGET_VERSION}."
  plan_dependencies

  if qbt_version_ge "${CURRENT_QBT_VERSION}" "${TARGET_VERSION}" \
     && [[ "${CURRENT_QBT_VERSION}" == "${TARGET_VERSION}" ]]; then
    warn "Target version ${TARGET_VERSION} is already installed."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      print_dry_run_report
      exit 0
    fi
    confirm "Rebuild and reinstall anyway?"
  elif qbt_version_lt "${TARGET_VERSION}" "${CURRENT_QBT_VERSION}"; then
    die "Target version ${TARGET_VERSION} is older than installed ${CURRENT_QBT_VERSION}."
  fi

  if [[ "${RESOLVE_LATEST_BETA}" -eq 1 ]]; then
    warn "Installing a pre-release (--beta). Validate on a non-production host first."
  fi

  print_dry_run_report
  preflight_remote_assets

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    ok "DRY-RUN complete - no changes made."
    exit 0
  fi

  confirm "Proceed with upgrade from qBittorrent ${CURRENT_QBT_VERSION} -> ${TARGET_VERSION}?"

  mkdir -p "${WORK_ROOT}" "${DIST_DIR}"
  # Ensure dpkg-repack exists before backup so PREV_*_DEB recovery packages are available.
  export DEBIAN_FRONTEND=noninteractive
  run_cmd --allow-fail apt-get update -y || true
  run_cmd --allow-fail apt-get install -y --no-install-recommends dpkg-repack || true
  create_backup
  maybe_remount_build_dirs_exec
  stop_active_services
  apt_install_packages
  ensure_cmake_swizzin
  ensure_qt
  ensure_boost
  build_libtorrent_if_needed
  backup_user_qbittorrent_confs
  # Apply nginx before replacing the binary so a failed nginx -t leaves the old package intact.
  apply_nginx_qbittorrent_52
  build_qbittorrent
  start_previous_services
  verify_installation

  # Mark success before cleanup so a cleanup failure is not treated as a failed upgrade.
  UPGRADE_SUCCEEDED=1
  NGINX_NEEDS_RESTORE=0

  # Cleanup work dirs (keep debs in DIST_DIR and backup)
  if [[ -z "${WORK_ROOT_ENV}" && -d "${WORK_ROOT}" ]]; then
    info "Cleaning work directory: ${WORK_ROOT}"
    safe_rm_path "${WORK_ROOT}" || warn "Could not remove work directory ${WORK_ROOT} (non-fatal)."
  fi

  ok "=== Upgrade to qBittorrent ${TARGET_VERSION} succeeded ==="
  info "Backup: ${BACKUP_DIR}"
  info "Package: ${DIST_DIR}/qbittorrent-nox_$(qbt_to_deb_version "${TARGET_VERSION}")_*.deb"
  info "Rollback: ${SCRIPT_NAME} --rollback"
}

main() {
  parse_args "$@"
  if [[ "${DO_ROLLBACK}" -eq 1 ]]; then
    do_rollback
    exit 0
  fi
  run_upgrade
}

main "$@"
