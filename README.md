# qBittorrent Auto-Upgrade for Swizzin (Debian 12)

**[`qbittorrent-auto-upgrade.sh`](qbittorrent-auto-upgrade.sh)** — controlled, reproducible upgrade of **qbittorrent-nox** on an existing [Swizzin](https://swizzin.ltd/) host running **Debian 12 (Bookworm)**.

On each default run the script:

1. Resolves the **newest stable** `release-*` tag from GitHub  
2. Reads **dependency floors** for that exact tag (Qt, libtorrent, Boost, OpenSSL, zlib, CMake, C++)  
3. Builds and installs **qbittorrent-nox** with those requirements  

No qBittorrent series and no dependency minima are hard-coded in the script name or logic.

The workflow mirrors Swizzin’s compile-and-package approach (see [swizzin/swizzin#1300](https://github.com/swizzin/swizzin/pull/1300)) **without** modifying `/etc/swizzin` sources or switching Swizzin git branches. Production configs, multi-user instances, dry-run, and rollback are preserved.

**Current script version:** [`1.7.4`](CHANGELOG.md#174--2026-10-24) — full history in [CHANGELOG.md](CHANGELOG.md).

> The script does **not** start itself (no cron/daemon). You must invoke it. Once started, it auto-selects and installs the current GitHub stable unless you pass `--version` or `--beta`.

### Migration from older releases

| Before | Now |
| --- | --- |
| `upgrade-qbittorrent-5.2.sh` | [`qbittorrent-auto-upgrade.sh`](qbittorrent-auto-upgrade.sh) |
| Default / `--series 5.2` | Default = **latest GitHub stable** (any series) |
| Stable pins only | Optional `--version X.Y.Z` or `--beta` |

Commands and flags otherwise stay the same (`--dry-run`, `--yes`, `--rollback`, …).

---

## Supported versions

| Component | Supported | Notes |
| --- | --- | --- |
| **This tool** | [`1.7.4`](CHANGELOG.md#174--2026-10-24) | See [CHANGELOG.md](CHANGELOG.md) for older tool releases |
| **Host OS** | Debian **12** (Bookworm) | Other releases are untested |
| **Panel stack** | [Swizzin](https://swizzin.ltd/) with multi-user `qbittorrent@*` | `/etc/swizzin` is not modified |
| **Upgrade from** | qBittorrent **5.1.x** / **5.2.x** / **5.3.x** | Other starting versions may work; verify first |
| **Upgrade to** | **Current GitHub stable** (default), optional `--version`, or `--beta` | Deps always from the resolved tag; nginx 5.2+ snippet when target series ≥ 5.2 |
| **Pre-releases** | Via `--beta` only | Not for production |

| Invocation | Target |
| --- | --- |
| *(no version flags)* or `--stable` | **Newest stable** on GitHub + that release’s dependency floors |
| `--version X.Y.Z` | Exact stable pin + that release’s dependency floors |
| `--beta` | Newest upstream **beta/RC/pre-release** + that tag’s floors |

### Example floors (qBittorrent 5.3.0)

Illustrative only — each run re-reads upstream for the chosen tag:

| Dependency | Minimum |
| --- | --- |
| CMake | 3.16 |
| C++ | 20 |
| Qt | 6.6.0 |
| Boost | 1.76 |
| OpenSSL | 3.0.2 |
| zlib | 1.2.11 |
| libtorrent-rasterbar | **1.2.19+** (default `RC_1_2`) or **2.0.10+** (`RC_2_0`) |

On Bookworm, distro Qt is often below the upstream Qt floor → **qt6-swizzin** (+ zlib-ng) may be installed. Lua for 5.3+ `PLUGINS` is **bundled** in the qBittorrent source (no system `liblua`).

When publishing on GitHub, tag tool releases (e.g. `v1.7.4`) and optionally point this table at [Releases](../../releases).

---

## License

This project is licensed under the **GNU General Public License v3.0 or later**.

See [`LICENSE`](LICENSE) for the full terms, or <https://www.gnu.org/licenses/gpl-3.0.html>.

---

## Features

- Detects OS, architecture, installed qBittorrent / libtorrent / Qt / CMake / Ninja, systemd units, config paths, disk space, and GitHub connectivity
- Resolves a target release: **latest stable by default** (or `--stable`), or `--version` / `--beta`
- Reads **build requirements from upstream** for that tag (Qt, libtorrent, Boost, OpenSSL, zlib, CMake, C++)
- Builds headless **qbittorrent-nox** (`GUI=OFF`, `WEBUI=ON`) with CMake + Ninja
- Packages with `fpm` and installs via `dpkg -i` (no blind `apt remove` / `purge`)
- Reuses a compatible static libtorrent when possible; rebuilds only when required
- Installs Swizzin cross-build Qt (`qt6-swizzin`) when distro Qt is too old — **no** full Qt source compile by default
- Backs up nginx and per-user `qBittorrent.conf` to `.orig` files
- Applies a qBittorrent **5.2+-compatible** nginx reverse-proxy snippet when the target series is ≥ 5.2 (Swizzin multi-user)
- Restarts only services that were active before the upgrade
- Supports `--dry-run`, `--yes`, and `--rollback` (Swizzin stable via `box upgrade`)

---

## Requirements

| Requirement | Notes |
| --- | --- |
| Debian 12 Bookworm | Verified target platform |
| Existing Swizzin + qbittorrent-nox | Typically 5.1.x–5.3.x today |
| Root privileges | Required for packages, services, nginx |
| Free disk space | Script checks for ≥ 4 GiB on the filesystem backing the work directory (`WORK_ROOT`, default under `/var/tmp`) |
| Network access to GitHub | Source tags, optional Swizzin cross-build DEBs |
| Independent server backup | Strongly recommended before production use |

---

## Quick start

```bash
# Plan only — newest GitHub stable + that tag's dependency floors
sudo ./qbittorrent-auto-upgrade.sh --dry-run

# Build & install current stable + its prescribed deps (default)
sudo ./qbittorrent-auto-upgrade.sh --yes

# Same as default
sudo ./qbittorrent-auto-upgrade.sh --stable --yes

# Optional: pin an exact stable (deps still from that tag)
sudo ./qbittorrent-auto-upgrade.sh --version 5.3.0 --yes

# Latest upstream beta/RC (not for production)
sudo ./qbittorrent-auto-upgrade.sh --beta --yes

# Roll back to Swizzin's current stable (via box upgrade)
sudo ./qbittorrent-auto-upgrade.sh --rollback
```

### Command-line options

| Option | Description |
| --- | --- |
| `--dry-run` | Analyse and print the plan; change nothing |
| `--yes` | Skip interactive confirmation |
| `--stable` | Latest **stable** from GitHub (same as no version flags) |
| `--version X.Y.Z` | Install **exactly** this stable release |
| `--beta` | Latest upstream **beta/RC/pre-release** (not for production) |
| `--libtorrent RC_1_2\|RC_2_0` | libtorrent branch (default: `RC_1_2`) |
| `--rollback` | Return to Swizzin's current stable via `QBITTORRENT_VERSION=<ver> box upgrade qbittorrent` |
| `--help` | Show usage |

Without `--version` / `--beta`, the script installs the **latest stable** qBittorrent release from GitHub (`--stable` is optional and equivalent).

### Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `QBT_UPGRADE_LOG` | `/var/log/qbittorrent-<version>-upgrade.log` | Log file (version = target release) |
| `QBT_UPGRADE_WORK` | `/var/tmp/qbittorrent-<version>-upgrade` | Build work directory (version = target release) |
| `QBT_UPGRADE_DIST` | `/root/dist` | Output directory for `.deb` packages |

---

## How it works

1. **Discover** the host environment (no hard-coded usernames, ports, or service names).
2. **Resolve** the target qBittorrent version (latest stable by default).
3. **Fetch** upstream build minima for that tag (Qt, libtorrent, CMake, C++, Boost, OpenSSL, zlib).
4. **Plan** packages and rebuilds (dry-run stops here if requested).
5. **Backup** packages, systemd state, configs, nginx, and per-user `qBittorrent.conf`.
6. **Stop** previously active `qbittorrent@*` units only.
7. **Build** dependencies as needed (Boost, libtorrent, qt6-swizzin, …).
8. **Update** `/etc/nginx/apps/qbittorrent.conf` for 5.2+ reverse-proxy behaviour (when target series ≥ 5.2; **before** installing the new package; `nginx -t` or reload failure restores the previous file and leaves the old binary intact).
9. **Build & package** qbittorrent-nox; install with `dpkg -i` (pre-releases use Debian `~` versioning); `apt-mark hold`.
10. **Start** only units that were active before; verify version and local WebUI reachability.

Preflight (also in `--dry-run`): when qt6-swizzin / cmake-swizzin / zlib-ng are planned, the script HEAD-checks the corresponding GitHub release assets **before** stopping services.

---

## Dynamic requirements

After the target version is known, the script reads:

- `https://raw.githubusercontent.com/qbittorrent/qBittorrent/release-<version>/CMakeLists.txt`
- `…/cmake/Modules/CommonConfig.cmake`

Parsed fields include `minQt6Version`, `minLibtorrent1Version`, `minLibtorrentVersion`, `minBoostVersion`, `minOpenSSLVersion`, `minZlibVersion`, `cmake_minimum_required`, and the C++ standard (`cxx_std_*`).

These values drive planning. If upstream metadata cannot be fetched or parsed, the script **aborts** — it does not invent version floors.

Within a tested minor series (e.g. all stable **5.3.x**), selecting a newer patch via `--version` is intentional. For a new minor/major beyond the verified series, validate nginx and packaging behaviour and publish a dedicated release of this tool.

---

## Build outline

Aligned with Swizzin’s CMake path and upstream `INSTALL` for headless builds:

```text
cmake -G Ninja -B build \
  -D CMAKE_BUILD_TYPE=Release \
  -D CMAKE_CXX_STANDARD=<from upstream> \
  -D Boost_NO_BOOST_CMAKE=TRUE \
  -D GUI=OFF \
  -D WEBUI=ON \
  -D CMAKE_INSTALL_PREFIX=<stage>/usr
cmake --build build
cmake --install build
fpm … -n qbittorrent-nox --version <version>
dpkg -i qbittorrent-nox_<version>_*.deb
apt-mark hold qbittorrent-nox
```

Notes:

- `-D QT6=…` is passed only if that CMake option exists in the downloaded tree (5.2+/5.3.x is Qt6-only).
- `PLUGINS` (5.3+) is left at the upstream default (`ON`); Lua/LuaBridge are vendored in the source tree.
- Compatible static libtorrent under `/usr/local` is reused when possible; otherwise the newest `v1.2.*` tag is built (`RC_1_2`).
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
sudo ./qbittorrent-auto-upgrade.sh --rollback
# optional plan only:
sudo ./qbittorrent-auto-upgrade.sh --rollback --dry-run
```

Rollback does **not** reinstall the local backup `.deb`. It returns the host to **Swizzin's current stable** qBittorrent:

1. Prefer the local Swizzin function `/etc/swizzin/sources/functions/qbittorrent` (fallback: same file from Swizzin GitHub master)
2. Read the preferred series for this OS (first non-`Repo` entry in Swizzin's whiptail menu, e.g. **5.1** on Debian 12)
3. Resolve the latest stable patch of that series from qBittorrent tags (e.g. `5.1.4`)
4. `apt-mark unhold qbittorrent-nox`, then run (no version dialog):

```bash
QBITTORRENT_VERSION=<resolved> box upgrade qbittorrent
```

5. After a successful `box upgrade`, restore `/etc/nginx/apps/qbittorrent.conf` from `.orig` **only if** the resolved Swizzin target series is &lt; 5.2 (for ≥ 5.2, keep the 5.2+ proxy snippet)

Live per-user WebUI passwords and settings are left to Swizzin's upgrade path. Timestamped backups under `/root/qbittorrent-upgrade-backup-*` remain available for manual recovery if needed.

---

## nginx / WebUI (5.2+)

qBittorrent 5.2+ validates HTTP Basic Auth forwarded by reverse proxies. Swizzin’s stock `/qbittorrent/` location can therefore return **Unauthorized** when panel credentials differ from WebUI credentials.

This tool (when the target series is ≥ 5.2):

1. Backs up `/etc/nginx/apps/qbittorrent.conf` → `.orig`
2. Installs a multi-user-compatible location (forwarded headers + `proxy_set_header Authorization ""`)
3. Runs `nginx -t` and `systemctl reload`; restores the previous file if either fails (before the new qbittorrent package is installed)

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
rm -f ./qbittorrent-auto-upgrade.sh ./README.md ./CHANGELOG.md ./LICENSE
# Optional:
# rm -f /var/log/qbittorrent-*-upgrade.log
# rm -rf /root/qbittorrent-upgrade-backup-*
# rm -rf /var/tmp/qbittorrent-*-upgrade
```

Installed `qbittorrent-nox` remains installed. Use `--rollback` to return to Swizzin's current stable via `box upgrade`, or reinstall manually from a backup under `/root/qbittorrent-upgrade-backup-*` if needed.

---

## Development checks

```bash
bash -n qbittorrent-auto-upgrade.sh
command -v shellcheck >/dev/null && shellcheck -x qbittorrent-auto-upgrade.sh
```

When releasing, bump `SCRIPT_VERSION` in the script and add a matching entry in [CHANGELOG.md](CHANGELOG.md).
