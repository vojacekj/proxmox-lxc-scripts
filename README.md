# Proxmox LXC Scripts

Helper scripts for managing Proxmox VE LXC containers with **Telegram** and **Gotify** notifications.

## Table of Contents

- [Installation](#installation)
- [Notification Setup](#notification-setup)
  - [Telegram](#telegram)
  - [Gotify](#gotify)
- [Architecture](#architecture)
- [Scripts](#scripts)
  - [dashboard-discover.sh](#dashboard-discoversh)
  - [install-avahi-all-lxcs.sh](#install-avahi-all-lxcsh)
- [Development](#development)
- [Security](#security)
- [License](#license)

## Scripts

| Script | Description |
|--------|-------------|
| [`dashboard-discover.sh`](#dashboard-discoversh) | Auto-detect running LXC web services and render Gatus + Homepage config |
| [`install-avahi-all-lxcs.sh`](#install-avahi-all-lxcsh) | Check all running LXCs for `avahi-daemon` and install it if missing |

## Installation

Clone the repo to `/root/scripts` on your Proxmox host:

```bash
mkdir -p /root/scripts
cd /root/scripts
git clone https://github.com/vojacekj/proxmox-lxc-scripts.git .
```

Or install individual scripts — see each script's section below for download commands.

## Notification Setup

Both **Telegram** and **Gotify** are supported. If both config files exist, notifications are sent to both channels. If only one exists, only that one receives notifications. Config files must be in the same directory as the scripts (`/root/scripts/`).

During discovery, a status report (added services, already-known skip list, failures) is sent over the configured channel(s) **only when something changed or failed** — an idle cron run sends nothing, matching the old Flame behavior. `send_notification()` → `send_telegram()` / `send_gotify()`.

### Telegram

1. Talk to [@BotFather](https://t.me/BotFather) on Telegram and create a bot to get your **Bot Token**.
2. Send any message to your bot, then visit:
   ```
   https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
   ```
   to find your **Chat ID**.
3. Copy the example config and fill in your values:
   ```bash
   cd /root/scripts
   cp telegram.conf.example telegram.conf
   chmod 600 telegram.conf
   ```
4. Edit `telegram.conf` and set `TOKEN` and `CHAT_ID`.

### Gotify

1. Install Gotify (via [community-scripts](https://community-scripts.org/scripts/gotify) or Docker).
2. Create an **Application** in the Gotify web UI and copy the token.
3. Copy the example config and fill in your values:
   ```bash
   cd /root/scripts
   cp gotify.conf.example gotify.conf
   chmod 600 gotify.conf
   ```
4. Edit `gotify.conf` and set `GOTIFY_SERVER` and `GOTIFY_TOKEN`.

Config is loaded from `/root/scripts/` (the script's directory) first, then from `/etc/pve-telegram.conf` / `/etc/pve-gotify.conf`.

---

## Architecture

`dashboard-discover.sh` feeds a self-hosted monitoring + dashboard stack made of two LXCs (both installable via [community-scripts](https://community-scripts.org)):

| App | LXC install script | Role | Config path | Port |
|-----|--------------------|------|-------------|------|
| [Gatus](https://github.com/TwiN/gatus) | `ct/gatus.sh` | Probes services (HTTP/TCP), uptime history, alerting | `/opt/gatus/config` | 8080 |
| [Homepage](https://gethomepage.dev) | `ct/homepage.sh` | Start page: icons + links + a `siteMonitor` status widget on every service card | `/opt/homepage/config` | 3000 |

Flow:

1. `dashboard-discover.sh` scans running LXCs, detects web services and ports (built-in map → community-scripts GitHub → port scan).
2. It renders **Gatus endpoint config** (one service = one HTTP/TCP check, grouped, with alerting) and a **Homepage `services.yaml`** (icons + links + a `siteMonitor` on every card). The container the script runs in also keeps the Gatus LXC `/etc/hosts` in sync so `*.local` resolves for Gatus.
3. Files are pushed into each LXC via `pct push`. Before overwriting, the script **merges** each generated file with the currently deployed one: anything already in the live file is left completely untouched (including manual edits like a custom proxmox href) and only services/endpoints this run discovered but that aren't deployed yet are added — "only add new", like the old Flame tool. The one field that is refreshed for already-deployed endpoints is Gatus's volatile `url:` (kept current to the fresh scan). Unchanged files stay byte-identical, so Homepage/Gatus don't reload on every cron run.
4. **Both apps hot-reload**: Gatus re-reads its config every ~30s; Homepage watches `services.yaml` and updates immediately. No restarts needed.

Using two file-driven apps means everything is fully scriptable — no manual monitor creation.

---

## dashboard-discover.sh

Auto-detect running LXC containers and generate config for **Gatus** (health checks) and **Homepage** (dashboard) with `.local`/IP links and icons from [selfhst/icons](https://github.com/selfhst/icons) / dashboard-icons / each app's repo, with an on-demand [community-scripts](https://community-scripts.org) logo fallback.

**Download:**

```bash
cd /root/scripts
wget -O dashboard-discover.sh \
  https://raw.githubusercontent.com/vojacekj/proxmox-lxc-scripts/main/dashboard-discover.sh
wget -O dashboard-discover.conf.example \
  https://raw.githubusercontent.com/vojacekj/proxmox-lxc-scripts/main/dashboard-discover.conf.example
chmod +x dashboard-discover.sh
```

**Setup:**

```bash
cp dashboard-discover.conf.example dashboard-discover.conf
chmod 600 dashboard-discover.conf
```

**Run:**

```bash
/root/scripts/dashboard-discover.sh
```

**What it does:**
- Auto-detects your Gatus and Homepage LXCs (by name, or by port scan)
- Scans all running LXC containers for web services
- Matches services against a built-in map of 80+ common homelab apps
- Falls back to port scanning if the service isn't in the map
- Renders Gatus endpoints (HTTP/TCP checks, grouped by category, with alerting)
- Renders Homepage `services.yaml` (icons, links, and a `siteMonitor` status widget on **every** service card)
- Keeps Gatus raw-IP `url:` current on every run, and (with `USE_LOCAL_DOMAINS=yes`) rewrites the Gatus LXC `/etc/hosts` so `*.local` resolves inside Gatus
- Optionally mirrors discovered services into Uptime Kuma as monitors by editing its SQLite DB directly (`KUMA_ENABLED=yes`)
- Pushes config into each LXC via `pct push`
- Sends a notification summary via Telegram/Gotify

Both Gatus and Homepage reload config automatically — no service restarts required.

**Options:**

| Flag | Description |
|------|-------------|
| `--dry-run` | Show what would be written without pushing files |
| `--detect` | Re-detect the Gatus/Homepage LXC containers |
| `--help` | Show help message |

**Configuration:**

| Option | Description |
|--------|-------------|
| `GATUS_ENABLED` | Set to `no` to skip Gatus config generation |
| `GATUS_LXC_ID` | Auto-detected on first run, or set manually |
| `GATUS_CONFIG_DIR` | Config dir inside Gatus LXC (default `/opt/gatus/config`) |
| `GATUS_SCAN_INTERVAL` | Seconds between checks per service (default `60`) |
| `GATUS_ALERTING` | `yes` to emit alerting blocks from `telegram.conf`/`gotify.conf` |
| `GATUS_RESTART_SERVICE` | `yes` to restart Gatus after pushing (default `no` — avoids restart churn) |
| `GATUS_PORT` | Gatus listen port (default `8080`), appended to the Homepage widget URL |
| `KUMA_ENABLED` | Set to `yes` to mirror discovered services into Uptime Kuma (default `no`) |
| `KUMA_LXC_ID` | Auto-detected by name `kuma` on first run, or set manually |
| `KUMA_DB_PATH` | Kuma SQLite DB path inside its LXC (default `/opt/uptime-kuma/data/kuma.db`) |
| `KUMA_PORT` | Kuma web port for LXC auto-detect fallback (default `3001`) |
| `KUMA_INTERVAL` | Monitor check interval in seconds (default `60`) |
| `KUMA_RESTART_SERVICE` | `yes` to restart `uptime-kuma` after writing the DB (default `yes` — needed to reload monitors) |
| `HOMEPAGE_ENABLED` | Set to `no` to skip Homepage config generation |
| `HOMEPAGE_LXC_ID` | Auto-detected on first run, or set manually |
| `HOMEPAGE_CONFIG_DIR` | Config dir inside Homepage LXC (default `/opt/homepage/config`) |
| `HOMEPAGE_SERVICES_FILE` | Filename to write (default `services.yaml`) |
| `HOMEPAGE_GATUS_URL` | Base URL Homepage uses for the Gatus widget (auto-derived as `<gatus>:<GATUS_PORT>`; override to use a custom hostname/path) |
| `USE_LOCAL_DOMAINS` | `yes` to link Homepage services as `<name>.local` mDNS hostnames (default, matches old Flame behavior); `no` to use raw IPs |
| `PVE_HOST_IP` | LAN IP of the Proxmox host; when set, the host is added as a managed service (PVE web UI, `https:<PVE_HOST_PORT>`) since it isn't an LXC. Auto-detected from the host's primary interface if empty |
| `PVE_HOST_NAME` | Display name for the host service (default `proxmox`) |
| `PVE_HOST_PORT` | Port for the host service (default `8006`) |
| `SCAN_PORTS` | Comma-separated ports to probe for unknown services |
| `PORT_OVERRIDES` | `"hostname:port"` pairs for non-standard ports |
| `ICON_OVERRIDES` | `"hostname:url"` pairs for custom icons (takes precedence over built-in defaults) |
| `SKIP_APPS` | Comma-separated container names to skip (e.g., `"pve,monitoring"`) |

> **Built-in custom-app icons:** `homepage_icon()` ships fallback icons as full CDN URLs — `omnitools`, `yuvomi`, `convertx` (from community-scripts.org, or their GitHub assets), `proxmox-hive` (its GitHub `hive.svg`), and `proxmox` (selfhst `proxmox.svg`). For any other unrecognized app it performs an on-demand [community-scripts](https://community-scripts.org) logo lookup (cached 7 days), falling back to `server.svg`. Icons never use `.local` or favicon endpoints (CDN only). Override any of these with `ICON_OVERRIDES`.

**Cron (every 15 minutes):**

```bash
crontab -e
# Add:
*/15 * * * * /root/scripts/dashboard-discover.sh >> /var/log/dashboard-discover.log 2>&1
```

**Gatus monitoring LXC (one-time):**

```bash
# On the Proxmox host, via community-scripts:
var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/gatus.sh)"
```

**Homepage LXC (one-time):**

```bash
var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/homepage.sh)"
```

**Homepage host validation (required once):**

Homepage v1.0+ blocks requests from any host not listed in `HOMEPAGE_ALLOWED_HOSTS` (you'll see "Host validation failed" at `http://homepage.local:3000`). Set it and restart the service. List the hostname(s)/IP(s) you actually use to reach it (dynamic-IP setups: use your hostname, not a fixed IP — e.g. `homepage.local`, a `.local` name, or your reverse-proxy domain):

```bash
VMID=105                                   # your Homepage LXC id
pct exec $VMID -- bash -c "
  sed -i '/^\[Service\]/a Environment=HOMEPAGE_ALLOWED_HOSTS=homepage.local:3000' /etc/systemd/system/homepage.service
  systemctl daemon-reload
  systemctl restart homepage
"
```

If the systemd unit already loads `/opt/homepage/.env` via `EnvironmentFile`, append the same value there instead of using `sed`. `localhost:3000` and `127.0.0.1:3000` are always allowed by default.

**Built-in services:** jellyfin, plex, sonarr, radarr, prowlarr, qbittorrent, portainer, grafana, prometheus, pihole, adguard, nextcloud, vaultwarden, paperless, immich, and 60+ more.

**Homepage `siteMonitor` status widgets:** every rendered service card gets a `siteMonitor:` targeting the same `protocol://<link_host>[:port]` as its link. Homepage then attaches a status widget to each card. `siteMonitor` is probed server-side from the Homepage LXC, so it only works with `.local` if that LXC has mDNS. Pick the widget style per service (in `services.yaml`) or globally (in `settings.yaml`): unset = response ms + status, `"dot"` or `"basic"` for a minimal UP/DOWN indicator. (`statusStyle` is a Homepage-side setting you choose; the script does not emit it.)

**Uptime Kuma mirror (trial):** Uptime Kuma has no REST API to create monitors (only a private Socket.IO interface), so this script writes `monitor` rows straight into Kuma's SQLite DB from inside the Kuma LXC:
- Set `KUMA_ENABLED=yes`, ensure `sqlite3` is installed in the Kuma LXC, and point `KUMA_DB_PATH` at the actual DB location for your install.
- It backs the DB up (`-backup.db`) before writing, only touches the `monitor` table, and is idempotent: existing monitor names are refreshed (url + `ignore_tls=1` for HTTPS), new ones are inserted, everything else untouched.
- Kuma loads monitors into memory at startup, so it must be restarted after the write (`KUMA_RESTART_SERVICE=yes`, default) to pick up changes.
- This is upstream "not recommended" and depends on the exact Kuma DB schema, which can drift between versions. Any sqlite3 failure is logged and skipped — Gatus continues to work regardless.

**Example Gatus output:**

```yaml
metrics: true
storage:
  type: sqlite
  path: /opt/gatus/data.db
alerting:
  telegram:
    token: 123:ABC
    id: chat-1
  gotify:
    server: https://gotify.local
    token: gotify-token
interval: 60
endpoints:
  - name: jellyfin
    group: media
    url: http://10.10.10.101:8096
    interval: 60s
    conditions:
      - "[CONNECTED] == true"
    alerts:
      - type: gotify
```

---

## install-avahi-all-lxcs.sh

Check all running LXC containers for `avahi-daemon` and install it if missing. Enables `.local` mDNS resolution for service discovery (used by dashboard-discover).

**Download:**

```bash
cd /root/scripts
wget -O install-avahi-all-lxcs.sh \
  https://raw.githubusercontent.com/vojacekj/proxmox-lxc-scripts/main/install-avahi-all-lxcs.sh
chmod +x install-avahi-all-lxcs.sh
```

**Run:**

```bash
/root/scripts/install-avahi-all-lxcs.sh
```

**What it does:**
- Iterates all LXC containers on the host
- Skips stopped containers and containers without apt-get
- Checks if `avahi-daemon` is installed in each running LXC
- Installs and enables the service if missing
- Sends a summary notification via Telegram and/or Gotify

**Cron (weekly):**

```bash
crontab -e
# Add:
0 3 * * 0 /root/scripts/install-avahi-all-lxcs.sh >> /var/log/avahi-install.log 2>&1
```

**Example output:**

```
2026-08-25 14:30:01 [INFO] Starting avahi-daemon check on pve01...
2026-08-25 14:30:01 [INFO] Checking LXC 101 (authentik)...
2026-08-25 14:30:03 [INFO] ID 101 (authentik): avahi-daemon already installed
2026-08-25 14:30:03 [INFO] Checking LXC 102 (database)...
2026-08-25 14:30:05 [INFO] ID 102 (database): avahi-daemon installed and started
2026-08-25 14:30:05 [INFO] ID 103 (alpine-box): No apt-get found
2026-08-25 14:30:05 [INFO] ID 104 (old-test): Stopped — skipping
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Summary
   Installed:         1
   Already present:   1
   Skipped (stopped): 1
   Skipped (no apt):  1
   Failed:            0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Development

Automated checks (ShellCheck + bats tests) run in GitHub Actions on every push/PR.

**Local checks:**

| Command | What it does |
|---------|--------------|
| `make lint` | ShellCheck on both scripts |
| `make test` | Runs bats unit tests |
| `make check` | Syntax check + lint + tests (same as CI) |

**Tests** (`tests/`) use [bats-core](https://github.com/bats-core/bats-core) and cover the pure-logic functions of `dashboard-discover.sh`: URL normalization, service lookup, grouping/icon helpers, Gatus/Homepage YAML builders, argument parsing, and the `SKIP_APPS` logic. They mock nothing external and require no Proxmox host.

Requirements:

- [bats-core](https://github.com/bats-core/bats-core) on `PATH` (`brew install bats-core` on macOS)
- [ShellCheck](https://github.com/koalaman/shellcheck) (`brew install shellcheck` on macOS, `apt install shellcheck` on Debian)
- **bash 4+** — the scripts use associative arrays. macOS ships bash 3.2; install with `brew install bash`. `make test` auto-detects Homebrew bash.

---

## Security

- Config files with secrets (`telegram.conf`, `gotify.conf`, `dashboard-discover.conf`) are **gitignored**
- Config files must have `600` ownership `root:root` permissions to be loaded — the script refuses to load insecure files
- No secrets are ever printed to the terminal or included in notifications

## License

MIT
