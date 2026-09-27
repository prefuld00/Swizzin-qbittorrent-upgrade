# qBittorrent Upgrade Tool for Swizzin (Debian 12)

Controlled, reproducible upgrade of **qbittorrent-nox** on an existing [Swizzin](https://swizzin.ltd/) host running **Debian 12 (Bookworm)**.

The tool mirrors Swizzin’s compile-and-package workflow (see [swizzin/swizzin#1300](https://github.com/swizzin/swizzin/pull/1300)) **without** modifying `/etc/swizzin` sources or switching Swizzin git branches. It preserves production configuration, supports multi-user instances, and provides dry-run and rollback paths.

**Current script version:** [`1.3.2`](CHANGELOG.md#132--2026-09-27) — full history in [CHANGELOG.md](CHANGELOG.md).

> The script does **not** run an upgrade automatically. You must invoke it explicitly on the target server.

---

## Supported versions

| Component | Supported | Notes |
| --- | --- | --- |
| **This tool** | [`1.3.2`](CHANGELOG.md#132--2026-09-27) | See [CHANGELOG.md](CHANGELOG.md) for older tool releases |
| **Host OS** | Debian **12** (Bookworm) | Other releases are untested |
| **Panel stack** | [Swizzin](https://swizzin.ltd/) with multi-user `qbittorrent@*` | `/etc/swizzin` is not modified |
| **Upgrade from** | qBittorrent **5.1.x** (e.g. 5.1.4) | Other starting versions may work; verify first |
| **Upgrade to** | qBittorrent **5.2.x** (stable) | Tested target series; latest stable is often [`5.2.3`](https://github.com/qbittorrent/qBittorrent/releases/tag/release-5.2.3) |
| **Pre-releases** | Not supported | Do not use beta/RC/nightly (e.g. 5.3.0beta1) in production |

Pin a target with `--version 5.2.3`, or take the newest stable in the series with `--series 5.2`. Build minima are read from the chosen upstream tag; nginx handling in this release is tailored to **5.2.x**.

When you publish on GitHub, also tag tool releases (e.g. `v1.3.2`) and point this table at [Releases](../../releases) if desired.

---

## License

This project is licensed under the **GNU General Public License v3.0 or later**.

See [`LICENSE`](LICENSE) for the full terms, or <https://www.gnu.org/licenses/gpl-3.0.html>.

---

## Features

- Detects OS, architecture, installed qBittorrent / libtorrent / Qt / CMake / Ninja, systemd units, config paths, disk space, and GitHub connectivity
- Resolves a target release via `--version X.Y.Z` or `--series X.Y` (default series: `5.2`)
- Reads **build requirements from upstream** (`CMakeLists.txt`, `CommonConfig.cmake`) for the selected tag
- Builds headless **qbittorrent-nox** (`GUI=OFF`) with CMake + Ninja
- Packages with `fpm` and installs via `dpkg -i` (no blind `apt remove` / `purge`)
- Reuses a compatible static libtorrent when possible; rebuilds only when required
- Installs Swizzin cross-build Qt (`qt6-swizzin`) when distro Qt is too old — **no** full Qt source compile by default
- Backs up nginx and per-user `qBittorrent.conf` to `.orig` files
- Applies a qBittorrent **5.2.x-compatible** nginx reverse-proxy snippet for Swizzin multi-user setups
- Restarts only services that were active before the upgrade
- Supports `--dry-run`, `--yes`, and `--rollback`

---

## Requirements

| Requirement | Notes |
| --- | --- |
| Debian 12 Bookworm | Verified target platform |
| Existing Swizzin + qbittorrent-nox | Typically 5.1.x today |
| Root privileges | Required for packages, services, nginx |
| Free disk space | Script checks for ≥ 4 GiB under `/var/tmp` |
| Network access to GitHub | Source tags, optional Swizzin cross-build DEBs |
| Independent server backup | Strongly recommended before production use |

---

## Quick start

```bash
# Plan only (no changes)
sudo ./upgrade-qbittorrent-5.2.sh --version 5.2.3 --dry-run

# Perform upgrade
sudo ./upgrade-qbittorrent-5.2.sh --version 5.2.3 --yes

# Roll back to the previous package / nginx config
sudo ./upgrade-qbittorrent-5.2.sh --rollback
```

### Command-line options

| Option | Description |
| --- | --- |
| `--dry-run` | Analyse and print the plan; change nothing |
| `--yes` | Skip interactive confirmation |
| `--version X.Y.Z` | Exact stable release (e.g. `5.2.3`) |
| `--series X.Y` | Latest stable within a series (default: `5.2`) |
| `--libtorrent RC_1_2\|RC_2_0` | libtorrent branch (default: `RC_1_2`) |
| `--rollback` | Restore previous qBittorrent package and nginx app config |
| `--help` | Show usage |

### Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `QBT_UPGRADE_LOG` | `/var/log/qbittorrent-5.2-upgrade.log` | Log file |
| `QBT_UPGRADE_WORK` | `/var/tmp/qbittorrent-5.2-upgrade` | Build work directory |
| `QBT_UPGRADE_DIST` | `/root/dist` | Output directory for `.deb` packages |

---

## How it works

1. **Discover** the host environment (no hard-coded usernames, ports, or service names).
2. **Resolve** the target qBittorrent version.
3. **Fetch** upstream build minima for that tag (Qt, libtorrent, CMake, C++, Boost, OpenSSL, zlib).
4. **Plan** packages and rebuilds (dry-run stops here if requested).
5. **Backup** packages, systemd state, configs, nginx, and per-user `qBittorrent.conf`.
6. **Stop** previously active `qbittorrent@*` units only.
7. **Build** dependencies as needed (Boost, libtorrent, qt6-swizzin, …).
8. **Build & package** qbittorrent-nox; install with `dpkg -i`; `apt-mark hold`.
9. **Update** `/etc/nginx/apps/qbittorrent.conf` for 5.2.x reverse-proxy behaviour.
10. **Start** only units that were active before; verify version and local WebUI reachability.

---

## Dynamic requirements

After the target version is known, the script reads:

- `https://raw.githubusercontent.com/qbittorrent/qBittorrent/release-<version>/CMakeLists.txt`
- `…/cmake/Modules/CommonConfig.cmake`

Parsed fields include `minQt6Version`, `minLibtorrent1Version`, `minLibtorrentVersion`, `minBoostVersion`, `minOpenSSLVersion`, `minZlibVersion`, `cmake_minimum_required`, and the C++ standard (`cxx_std_*`).

These values drive planning. Hard-coded floors apply **only** as emergency fallbacks if GitHub is unreachable.

Within a tested minor series (e.g. all stable **5.2.x**), selecting a newer patch via `--version` is intentional. For a new minor/major (e.g. 5.3), validate nginx and packaging behaviour and publish a dedicated release of this tool.

---

## Build outline

Aligned with Swizzin’s CMake path and upstream `INSTALL` for headless builds:

```text
cmake -G Ninja -B build \
  -D CMAKE_BUILD_TYPE=Release \
  -D CMAKE_CXX_STANDARD=<from upstream> \
  -D Boost_NO_BOOST_CMAKE=TRUE \
  -D GUI=OFF \
  -D CMAKE_INSTALL_PREFIX=<stage>/usr
cmake --build build
cmake --install build
fpm … -n qbittorrent-nox --version <version>
dpkg -i qbittorrent-nox_<version>_*.deb
apt-mark hold qbittorrent-nox
```

Notes:

- `-D QT6=…` is passed only if that CMake option exists in the downloaded tree (5.2.x is Qt6-only).
- Compatible static libtorrent under `/usr/local` is reused when possible.
- Install prefix matches Swizzin: **`/usr`** via Debian package (not a raw `/usr/local` install).
- On Bookworm, distro Qt is often &lt; upstream minimum → **qt6-swizzin** (+ zlib-ng) may be installed; this is announced explicitly.

---

## Backup

Created before destructive steps (skipped in dry-run):

| Location | Contents |
| --- | --- |
| `/root/qbittorrent-upgrade-backup-YYYY-MM-DD-HHMMSS/` | Versions, `dpkg` lists, systemd status, config trees, optional `dpkg-repack`, previous binary |
| `/root/qbittorrent-upgrade-backup-latest` | Symlink to the latest backup |
| `/etc/nginx/apps/qbittorrent.conf.orig` | First-run copy of the Swizzin nginx app config |
| `/home/<user>/.config/qBittorrent/qBittorrent.conf.orig` | Per-user config copy taken **before** the qBittorrent build |

Existing `.orig` files are never overwritten; an extra `.bak.<timestamp>` copy is created instead.

---

## Rollback

```bash
sudo ./upgrade-qbittorrent-5.2.sh --rollback
```

Rollback restores:

- The previous `qbittorrent-nox` `.deb` from the backup (or the saved binary as a last resort)
- nginx config from `qbittorrent.conf.orig` (or the backup copy)
- Previously active systemd units

Live per-user WebUI passwords and settings are **not** overwritten by rollback. Manual restore from `.orig` / the backup tree remains available if needed.

---

## nginx / WebUI (5.2.x)

qBittorrent 5.2.x validates HTTP Basic Auth forwarded by reverse proxies. Swizzin’s stock `/qbittorrent/` location can therefore return **Unauthorized** when panel credentials differ from WebUI credentials.

This tool:

1. Backs up `/etc/nginx/apps/qbittorrent.conf` → `.orig`
2. Installs a multi-user-compatible location (forwarded headers + `proxy_set_header Authorization ""`)
3. Reloads nginx after `nginx -t`

Recommended **manual** setting per user (not written by the script):

```ini
WebUI\TrustedReverseProxiesList=127.0.0.1
```

in `~/.config/qBittorrent/qBittorrent.conf`.

---

## Sources and references

| Source | Role |
| --- | --- |
| [swizzin/swizzin#1300](https://github.com/swizzin/swizzin/pull/1300) | 5.2.x support notes and build expectations |
| Commit [`86102c6`](https://github.com/swizzin/swizzin/commit/86102c65ace2e989863e5e54878cfc0b24c07e46) | Reference implementation in `sources/functions/qbittorrent` (read-only) |
| [qbittorrent/qBittorrent](https://github.com/qbittorrent/qBittorrent) | Official release tags and source |
| [arvidn/libtorrent](https://github.com/arvidn/libtorrent) | Optional static libtorrent build |
| [swizzin/qt6_crossbuild](https://github.com/swizzin/qt6_crossbuild) | qt6-swizzin when repo Qt is insufficient |
| [swizzin/zlib-ng-crossbuild](https://github.com/swizzin/zlib-ng-crossbuild) | Companion package for qt6-swizzin |
| [swizzin/cmake_crossbuild](https://github.com/swizzin/cmake_crossbuild) | cmake-swizzin if system CMake is too old |

---

## Risks and limitations

- Compiling libtorrent and qBittorrent is CPU- and I/O-intensive; ensure adequate RAM/swap.
- Installing `qt6-swizzin` adds Swizzin cross-build packages to the system.
- Rebuilding `libtorrent-rasterbar` may affect other clients sharing that package (e.g. Deluge).
- `apt-mark hold qbittorrent-nox` blocks unattended APT upgrades of that package (`apt-mark unhold` to clear).
- Binaries are typically built with `-march=native` and are not portable across CPU generations.
- After major/minor jumps, verify WebUI, reverse proxy, and third-party API clients.
- This tool is not a substitute for a full host backup (torrent data, home directories, etc.).

### Explicitly out of scope

- Blind `apt remove` / `purge` of qBittorrent before upgrade
- Permanent edits under `/etc/swizzin` (except using nginx under `/etc/nginx/apps/`)
- Automatic Swizzin git branch switches
- Overwriting WebUI usernames, passwords, or `TrustedReverseProxiesList` in user configs
- Starting units that were inactive before the upgrade
- Building the desktop GUI

---

## Removing the tool files

```bash
rm -f ./upgrade-qbittorrent-5.2.sh ./README.md ./CHANGELOG.md ./LICENSE
# Optional:
# rm -f /var/log/qbittorrent-5.2-upgrade.log
# rm -rf /root/qbittorrent-upgrade-backup-*
# rm -rf /var/tmp/qbittorrent-5.2-upgrade
```

Installed `qbittorrent-nox` remains installed. Use `--rollback` while backups still exist if you need the previous package.

---

## Development checks

```bash
bash -n upgrade-qbittorrent-5.2.sh
command -v shellcheck >/dev/null && shellcheck -x upgrade-qbittorrent-5.2.sh
```

When releasing, bump `SCRIPT_VERSION` in the script and add a matching entry in [CHANGELOG.md](CHANGELOG.md).
