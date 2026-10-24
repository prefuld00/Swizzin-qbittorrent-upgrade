# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html):


| Change type                                 | Version bump | Example           |
| ------------------------------------------- | ------------ | ----------------- |
| Bug fixes, docs, small hardening            | **PATCH**    | `1.0.0` → `1.0.1` |
| New features, behaviour changes             | **MINOR**    | `1.1.0` → `1.2.0` |
| Breaking changes to CLI or upgrade contract | **MAJOR**    | `1.x.x` → `2.0.0` |


---

## [1.7.4] — 2026-10-24
<a id="174--2026-10-24"></a>

### Changed

- **README**: merge legacy GitHub docs (v1.3.x / `upgrade-qbittorrent-5.2.sh`) with the auto-upgrade narrative — migration table, clearer default behaviour, updated CLI and risks.

---

## [1.7.3] — 2026-10-24
<a id="173--2026-10-24"></a>

### Changed

- **Rename**: `upgrade-qbittorrent-5.2.sh` → **`qbittorrent-auto-upgrade.sh`** so the filename reflects auto-upgrade to the current GitHub stable (no fixed 5.2 series in the name).

---

## [1.7.2] — 2026-10-20
<a id="172--2026-10-20"></a>

### Fixed

- **Syntax / quoting**: remove Unicode punctuation and apostrophe-heavy strings that could confuse parsers after copy/encoding; harden curl `%{http_code}` write-out quoting (error near `{ip'` / `{http_code}'`).

---

## [1.7.1] — 2026-10-20
<a id="171--2026-10-20"></a>

### Changed

- **Always current stable**: default path is explicitly “newest GitHub `release-*` tag + dependency floors from that tag’s CMakeLists/CommonConfig”; removed hard-coded `DEFAULT_SERIES`.
- **Docs / usage**: lead with latest-stable mode; `--version` documented as optional pin only.
- Dropped the “typically expected 5.1.x” warn so upgrades from 5.2/5.3 are not mis-flagged.

---

## [1.7.0] — 2026-10-20
<a id="170--2026-10-20"></a>

### Changed

- **qBittorrent 5.3.0**: verified target; default series hint `5.3`; examples and docs updated.
- **Build**: force `-D WEBUI=ON` with `GUI=OFF`; keep upstream `PLUGINS` default (bundled Lua in 5.3+, no system Lua package).
- **libtorrent**: planning log states upstream floors (1.2.19+ / 2.0.10+); default remains Swizzin-compatible `RC_1_2`.
- **Boost picker**: candidate list extended through 1.92 for future minima.

### Notes

- Upstream 5.3.0 CMake floors match 5.2.4 (CMake ≥ 3.16, C++20, Qt ≥ 6.6, Boost ≥ 1.76, OpenSSL ≥ 3.0.2, zlib ≥ 1.2.11, libtorrent 1.2.19+ or 2.0.10+). Bookworm still uses **qt6-swizzin** when distro Qt is too old. nginx Authorization-strip for ≥ 5.2 is unchanged.

---

## [1.6.13] — 2026-09-27
<a id="1613--2026-09-27"></a>

### Fixed

- **`verify_installation`**: inactive previously-started services are fatal (triggers package/nginx recovery) instead of a soft warn + false success.
- **libtorrent backup**: Version-verified DIST fallback when dpkg-repack is missing/fails; reject empty Version on PREV_* debs.

---

## [1.6.12] — 2026-09-27
<a id="1612--2026-09-27"></a>

### Fixed

- **Backup recovery artifacts**: always try Version-verified DIST `.deb` when dpkg-repack is missing **or** fails; drop unverified `ls` filename fallbacks; verify `PREV_QBT_DEB` Version; require `.deb` or binary backup for any qbittorrent replace (packaged or not).
- **CHANGELOG**: remove orphaned duplicate bullets after 1.6.6; restore missing 1.6.5 / 1.6.4 sections.

---

## [1.6.11] — 2026-09-27
<a id="1611--2026-09-27"></a>

### Fixed

- **`probe_zlib`**: strip Debian epoch (`1:…`) so zlib1g versions parse correctly.
- **`find_deb_by_name_version`**: match by `dpkg-deb` Version only; support fpm `NAME_VERSION.deb` (no arch suffix); never keep an unverified primary hit.
- **Backup DIST fallback**: locate previous qbittorrent debs via `qbt_to_deb_version` (handles `~` pre-releases).
- **Recovery packages**: refuse to proceed if libtorrent will be rebuilt without a rollback `.deb`, or qbittorrent has neither `.deb` nor binary backup.
- **`restore_previous_packages`**: stop units before `dpkg -i`; always `apt-mark unhold` on binary-only restore paths.

---

## [1.6.10] — 2026-09-27
<a id="1610--2026-09-27"></a>

### Fixed

- **`--rollback` nginx**: restore `.orig` only when the Swizzin target series is &lt; 5.2; keep the 5.2+ Authorization-strip snippet for ≥ 5.2 targets.
- **`restore_nginx_from_orig`**: put-back only from a successfully copied, non-empty live backup (never an empty `mktemp` file).
- **`ensure_boost`**: require `b2`/`bjam` (not merely `project-config.jam`) before treating Boost as present.

---

## [1.6.9] — 2026-09-27
<a id="169--2026-09-27"></a>

### Fixed

- **Early-abort service bounce**: recovery only restarts units listed in `STOPPED_SERVICES` (no restart of live instances on confirm-abort / preflight failure).
- **`failure_recovery` signal race**: ignore INT/TERM/HUP before setting `RECOVERY_DONE`.
- **`--rollback` nginx restore**: keep a live backup and put it back if `nginx -t` / reload fails after applying `.orig`.

---

## [1.6.8] — 2026-09-27
<a id="168--2026-09-27"></a>

### Fixed

- **Recovery after services started**: always `systemctl restart` previously active units so a rolled-back package/binary is actually loaded (not just skipping already-active units).
- **Docs**: `--rollback` / `usage()` now state that the local Swizzin function is preferred over GitHub master.

---

## [1.6.7] — 2026-09-27
<a id="167--2026-09-27"></a>

### Fixed

- **nginx vs package rollback**: keep `NGINX_NEEDS_RESTORE` until `UPGRADE_SUCCEEDED`; after restoring the old `.deb`, nginx rolls back too (no old-binary + 5.2-proxy mismatch).
- **`QBT_PACKAGE_INSTALLED`**: set immediately after successful `dpkg -i` (before `apt-mark hold`).
- **`dpkg-repack`**: install before `create_backup` so first-run recovery `.deb`s exist for qbittorrent and libtorrent.
- Binary-only qBittorrent restore now clears `QBT_PACKAGE_INSTALLED` so nginx restore can follow.

---

## [1.6.6] — 2026-09-27
<a id="166--2026-09-27"></a>

### Fixed

- **nginx + later failure**: keep restore armed until the new qbittorrent package is installed; restore old nginx if build fails before `dpkg -i`.
- **Package recovery**: on failure after installing qbittorrent/libtorrent, reinstall previous `.deb` from backup (`dpkg-repack`) or copy the binary backup.
- **`--rollback` series source**: prefer local `/etc/swizzin/sources/functions/qbittorrent` (what `box` accepts); GitHub master only as fallback.
- **`ensure_boost`**: detect incomplete `/opt/boost_*` trees and reinstall instead of skipping.
- **`safe_rm_path` / `WORK_ROOT`**: canonicalize paths, reject broad roots (`/`, `/usr`, …), allow only under `/var/tmp`, `/tmp`, or `/root`.

---

## [1.6.5] — 2026-09-27
<a id="165--2026-09-27"></a>

### Fixed

- **Signal-safe recovery**: ignore INT/TERM/HUP while `failure_recovery` runs (Ctrl+C mid-restore can no longer leave services stopped).
- **libtorrent `.deb` selection**: same strict version matching as qbittorrent-nox (`find_libtorrent_deb` / `dpkg-deb`), avoiding prefix collisions like `1.2.1*` → `1.2.19`.

---

## [1.6.4] — 2026-09-27
<a id="164--2026-09-27"></a>

### Fixed

- **SIGINT / SIGTERM / SIGHUP**: restore stopped services (and nginx if needed) on interrupt / hangup during long builds.
- **`on_exit`**: also runs `failure_recovery` on any non-success exit when the upgrade has not completed.
- **fpm `.deb` selection**: match by package version (`~` pre-release / `dpkg-deb`); never install an unrelated newest file from `DIST_DIR`.
- **`UPGRADE_SUCCEEDED`**: set before workdir cleanup so a cleanup hiccup is non-fatal and not treated as a failed upgrade.
- **`--libtorrent`**: force rebuild when the requested branch major (1.x vs 2.x) does not match the installed libtorrent.
- **Preflight**: HEAD-check planned Swizzin cross-build DEBs (qt6/cmake/zlib-ng) before stopping services — also during `--dry-run`.
- **Rollback**: `apt-mark unhold qbittorrent-nox` before `box upgrade`.
- **nginx reload**: restore previous conf if reload fails (not only on `nginx -t` failure).

---

## [1.6.3] — 2026-09-27
<a id="163--2026-09-27"></a>

### Fixed

- **nginx**: write via temp file + `mv`; set restore flag before replacing the live conf (no truncated conf on I/O failure).
- **nginx before package install**: apply/test the 5.2+ proxy snippet before `dpkg -i`, so a failed `nginx -t` leaves the old qbittorrent package intact.
- **`--beta` packaging**: `fpm --version` uses Debian `~` pre-release form (`5.3.0~beta1`) so the .deb sorts below the matching stable.
- **`--beta` downgrade guard**: refuse installing a pre-release older than the currently installed version (no longer skipped for `--beta`).
- **OpenSSL / zlib**: unknown versions are fatal (unless zlib-ng is already planned).
- **Disk space**: check free space on the filesystem backing `WORK_ROOT` (after versioned paths / `QBT_UPGRADE_WORK`), not only `/var/tmp`.

---

## [1.6.2] — 2026-09-27
<a id="162--2026-09-27"></a>

### Fixed

- **`die()` / failure paths** now restart services that were stopped for the upgrade (previously only the `ERR` trap did, so most failures left qBittorrent down).
- **`--beta` version detection / verify**: parse full pre-release strings (e.g. `5.3.0beta1`) instead of stripping to `5.3.0`.
- **qBittorrent version compare**: map pre-releases to Debian `~` ordering so `5.3.0beta1` < `5.3.0` (plain `dpkg` gets this wrong).
- **nginx**: on `nginx -t` failure, restore the previous config before aborting.
- **Build dirs with `noexec`**: remount the filesystem backing `WORK_ROOT` (and `/tmp` if needed), not only `/tmp` from fstab.
- **OpenSSL / zlib**: enforce upstream minima before stopping services (zlib-ng plan satisfies a low system zlib when Qt swizzin is planned).
- **GitHub tags fallback**: paginate the tags API when `git ls-remote` is unavailable.
- **`--rollback`**: run `box upgrade` first; restore nginx `.orig` only after success (avoids mixed binary/proxy state).
- Drain registered temp cleanup paths on success; keep `WORK_ROOT` on failure for debugging.
- Apply the 5.2+ nginx snippet only when the target series is ≥ 5.2.

---

## [1.6.1] — 2026-09-27
<a id="161--2026-09-27"></a>

### Changed

- Replaced **`--series X.Y`** with **`--stable`** (latest stable from GitHub; same as running with no version flags).
- `--series` now errors with a pointer to `--stable` / `--version`.

---

## [1.6.0] — 2026-09-27
<a id="160--2026-09-27"></a>


### Added

- `**--beta**`: resolve and build the latest upstream pre-release tag (alpha/beta/RC), e.g. `5.3.0beta1`. Not for production.

### Clarified

- Default (no version flags) = **latest stable**.
- Use `**--beta**` for pre-releases (see also 1.6.1 for `--stable`).

---

## [1.5.2] — 2026-09-27



### Changed

- Default log and work paths now include the **resolved target version**, e.g. `/var/log/qbittorrent-5.2.3-upgrade.log` and `/var/tmp/qbittorrent-5.2.3-upgrade`.
- `QBT_UPGRADE_LOG` / `QBT_UPGRADE_WORK` still override to a fixed path when set.

---

## [1.5.1] — 2026-09-27



### Changed

- Removed hard-coded Qt / libtorrent / Boost / OpenSSL / zlib / CMake / C++ fallbacks.
- Build minima are **always** read from the target tag’s upstream `CMakeLists.txt` (+ `CommonConfig.cmake`). If GitHub is unreachable or fields are missing, the script aborts instead of guessing 5.2-era values.

---

## [1.5.0] — 2026-09-27



### Changed

- `**--rollback**` no longer restores the local backup `.deb`. It now:
  1. Reads Swizzin's preferred qBittorrent series from GitHub (`sources/functions/qbittorrent`, per OS codename)
  2. Resolves the latest stable patch of that series
  3. Restores nginx from `qbittorrent.conf.orig` when present
  4. Runs `QBITTORRENT_VERSION=<ver> box upgrade qbittorrent` (skips the whiptail dialog)
- `--rollback --dry-run` prints the resolved version and planned command without changes.

---

## [1.4.0] — 2026-09-27



### Changed

- Running **without** `--version` / `--series` now installs the **latest stable** qBittorrent release from GitHub (not limited to series 5.2 by default).
- `--version X.Y.Z` still installs **exactly** that release.
- `--series X.Y` still selects the latest stable within that series only.
- Dry-run / planning output lists upstream minima for Qt, libtorrent, Boost, OpenSSL, and zlib for the chosen target.

---

## [1.3.2] — 2026-09-27



### Added

- Project licensed under **GNU GPL v3.0 or later** (`LICENSE`).
- GPL notice and `SPDX-License-Identifier` in `qbittorrent-auto-upgrade.sh`.
- License section in `README.md`.

---

## [1.3.1] — 2026-09-27



### Changed

- Translated all user-facing messages, help text, comments, dry-run output, and nginx snippet comments in `qbittorrent-auto-upgrade.sh` to professional English.
- Behaviour and CLI flags are unchanged.

---

## [1.3.0] — 2026-09-27



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

When cutting a release, update `SCRIPT_VERSION` in `qbittorrent-auto-upgrade.sh` and add a matching section at the top of this changelog.