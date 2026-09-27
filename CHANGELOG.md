# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

| Change type | Version bump | Example |
| --- | --- | --- |
| Bug fixes, docs, small hardening | **PATCH** | `1.0.0` → `1.0.1` |
| New features, behaviour changes | **MINOR** | `1.1.0` → `1.2.0` |
| Breaking changes to CLI or upgrade contract | **MAJOR** | `1.x.x` → `2.0.0` |

---

## [1.3.2] — 2026-09-27
<a id="132--2026-09-27"></a>

### Added

- Project licensed under **GNU GPL v3.0 or later** (`LICENSE`).
- GPL notice and `SPDX-License-Identifier` in `upgrade-qbittorrent-5.2.sh`.
- License section in `README.md`.

---

## [1.3.1] — 2026-09-27
<a id="131--2026-09-27"></a>

### Changed

- Translated all user-facing messages, help text, comments, dry-run output, and nginx snippet comments in `upgrade-qbittorrent-5.2.sh` to professional English.
- Behaviour and CLI flags are unchanged.

---

## [1.3.0] — 2026-09-27
<a id="130--2026-09-27"></a>

### Added

- Per-user configuration backup before the qBittorrent build:  
  `cp -a /home/<user>/.config/qBittorrent/qBittorrent.conf` → `qBittorrent.conf.orig`
- Multi-user discovery reuses existing config path detection (systemd instances and `/home/*/.config/qBittorrent`).
- If `qBittorrent.conf.orig` already exists, it is left untouched and an additional timestamped `.bak.<timestamp>` copy is created.
- Ownership of `.orig` files is aligned with the live configuration owner/group.
- Copies of `.orig` files are also stored under the central upgrade backup directory.

### Changed

- Dry-run output documents the planned per-user `qBittorrent.conf` backups.

---

## [1.2.0] — 2026-09-27
<a id="120--2026-09-27"></a>

### Added

- Dynamic build-requirement resolution from the official qBittorrent tag `release-<version>`:
  - `CMakeLists.txt` (CMake, Qt, libtorrent, Boost, OpenSSL, zlib minima)
  - `cmake/Modules/CommonConfig.cmake` (C++ standard, e.g. `cxx_std_20`)
- `--series X.Y` to select the latest stable release within a minor series.
- `--version X.Y.Z` accepts any stable release triplet (not limited to 5.2.x only).
- Soft fallback minima only when upstream metadata cannot be fetched.

### Changed

- Removed hard-coded Qt / libtorrent / CMake / C++ / Boost / OpenSSL floors for a single patch release.
- Boost package selection is derived from the upstream Boost minimum.
- Dry-run / planning output shows whether requirements came from upstream or fallbacks.

---

## [1.1.0] — 2026-09-27
<a id="110--2026-09-27"></a>

### Added

- nginx reverse-proxy adaptation for qBittorrent 5.2.x on Swizzin multi-user hosts:
  - Backup: `cp -a /etc/nginx/apps/qbittorrent.conf` → `qbittorrent.conf.orig` (first run only)
  - Install 5.2-compatible location block (forwarded headers, `Authorization ""`)
  - `nginx -t` and `systemctl reload nginx`
- Rollback restores nginx configuration from `.orig` or the upgrade backup.
- Central upgrade backup includes a copy of the nginx application config.

### Changed

- Upgrade flow updates nginx after a successful package build/install.
- Documentation and dry-run planning cover the nginx 5.2.x auth/proxy behaviour.

---

## [1.0.0] — 2026-09-27
<a id="100--2026-09-27"></a>

### Added

- Initial controlled upgrade script for existing Swizzin / Debian 12 (Bookworm) servers.
- Swizzin-aligned build and packaging path (inspired by [PR #1300](https://github.com/swizzin/swizzin/pull/1300) / commit `86102c6`):
  - Official qBittorrent source, CMake + Ninja, `GUI=OFF` → `qbittorrent-nox`
  - Optional static libtorrent build with reuse when compatible
  - `fpm` Debian package install via `dpkg -i` (no blind `apt remove` / `purge`)
  - `apt-mark hold qbittorrent-nox`
- Preflight checks: OS, architecture, installed toolchain versions, services, configs, disk space, GitHub reachability.
- Dry-run mode (`--dry-run`), non-interactive mode (`--yes`), and rollback (`--rollback`).
- Central backup under `/root/qbittorrent-upgrade-backup-YYYY-MM-DD-HHMMSS/`.
- Service handling: stop only previously active units; restart only those after success.
- Logging to `/var/log/qbittorrent-5.2-upgrade.log`.
- Does not modify `/etc/swizzin` sources or check out Swizzin git branches.

---

## Versioning policy (maintainers)

- Prefer **patch** releases for documentation-only updates, log wording, and non-behavioural script cleanup.
- Prefer **minor** releases when adding features (nginx handling, dynamic requirements, new backup steps) or changing upgrade behaviour in a backward-compatible way.
- Prefer **major** releases when changing CLI flags incompatibly, removing rollback guarantees, or altering the on-disk backup layout in a breaking way.

When cutting a release, update `SCRIPT_VERSION` in `upgrade-qbittorrent-5.2.sh` and add a matching section at the top of this changelog.
