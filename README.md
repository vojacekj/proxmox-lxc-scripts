# Proxmox LXC Scripts

Helper scripts for managing Proxmox VE LXC containers with **Telegram** and **Gotify** notifications.

## Scripts

| Script | Description |
|--------|-------------|
| `flame-auto-discover.sh` | Auto-detect running LXC services and add them to a Flame dashboard |
| `install-avahi-all-lxcs.sh` | Check all running LXCs for `avahi-daemon` and install it if missing |
| `netdata-postinstall.sh` | Configure Netdata on PVE host to monitor LXC containers via cgroups v2 |

## Table of Contents

- [Installation](#installation)
- [Notification Setup](#notification-setup)
- [flame-auto-discover.sh](#flame-auto-discoversh)
- [install-avahi-all-lxcs.sh](#install-avahi-all-lxcsh)
- [netdata-postinstall.sh](#netdata-postinstallsh)
- [Security](#security)
- [License](#license)

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

## flame-auto-discover.sh

Auto-detect running LXC containers and add them to your [Flame](https://github.com/pawelmalak/flame) dashboard with `.local` domains and official icons from [selfhst/icons](https://github.com/selfhst/icons).

**Download:**

```bash
cd /root/scripts
wget -O flame-auto-discover.sh \
  https://raw.githubusercontent.com/vojacekj/proxmox-lxc-scripts/main/flame-auto-discover.sh
wget -O flame-auto-discover.conf.example \
  https://raw.githubusercontent.com/vojacekj/proxmox-lxc-scripts/main/flame-auto-discover.conf.example
chmod +x flame-auto-discover.sh
```

**Setup:**

```bash
cp flame-auto-discover.conf.example flame-auto-discover.conf
chmod 600 flame-auto-discover.conf
```

**Run:**

```bash
/root/scripts/flame-auto-discover.sh
```

**What it does:**
- Auto-detects your Flame LXC container (by name or port 5005)
- Scans all running LXC containers for web services
- Matches services against a built-in map of 80+ common homelab apps
- Queries [community-scripts](https://github.com/community-scripts/ProxmoxVE) GitHub for unrecognized services (cached 7 days)
- Falls back to port scanning if still unknown
- Fetches icons from [selfhst/icons](https://github.com/selfhst/icons) CDN
- Adds services to Flame as `{name}.local:{port}` (pinned, public)
- Directly modifies Flame's SQLite database via `pct exec` (no auth needed)
- Auto-installs `sqlite3` in Flame LXC if missing
- Sends notification summary with service names via Telegram/Gotify

**Options:**

| Flag | Description |
|------|-------------|
| `--dry-run` | Show what would be added without making changes |
| `--restart` | Restart Flame service after adding new apps |
| `--detect` | Re-detect Flame LXC container |
| `--help` | Show help message |

**First run:**

```bash
# Auto-detects Flame and saves LXC ID to config
/root/scripts/flame-auto-discover.sh

# You'll be prompted to confirm the detected container
# Found Flame at LXC 103 (flame)
# Use this Flame container? [Y/n]
```

**Configuration:**

| Option | Description |
|--------|-------------|
| `FLAME_LXC_ID` | Auto-detected on first run, or set manually |
| `SCAN_PORTS` | Comma-separated ports to probe for unknown services |
| `PORT_OVERRIDES` | `"hostname:port"` pairs for non-standard ports |
| `ICON_OVERRIDES` | `"hostname:url"` pairs for custom icons |

**Cron (every 5 minutes):**

```bash
crontab -e
# Add:
*/5 * * * * /root/scripts/flame-auto-discover.sh >> /var/log/flame-discover.log 2>&1
```

**Built-in services:** jellyfin, plex, sonarr, radarr, prowlarr, qbittorrent, portainer, grafana, prometheus, pihole, adguard, nextcloud, vaultwarden, paperless, immich, and 60+ more.

**Example output:**

```
2026-08-25 14:30:01 [INFO] Starting Flame Auto-Discover v2.1.0 on pve01...
2026-08-25 14:30:01 [INFO] Using Flame LXC: 103
2026-08-25 14:30:01 [INFO] Scanning for running LXC containers...
2026-08-25 14:30:01 [INFO] Found 8 running LXC containers.
2026-08-25 14:30:01 [INFO] Processing LXC 101 (jellyfin)...
2026-08-25 14:30:01 [INFO]   IP: 10.10.10.101
2026-08-25 14:30:01 [INFO]   Detected port: 8096
2026-08-25 14:30:02 [INFO]   Added 'jellyfin' to Flame.
2026-08-25 14:30:02 [INFO] Processing LXC 102 (pihole)...
2026-08-25 14:30:02 [INFO]   Added 'pihole' to Flame.
2026-08-25 14:30:02 [INFO] Processing LXC 105 (nexterm)...
2026-08-25 14:30:02 [INFO]   Not in built-in map, checking community-scripts...
2026-08-25 14:30:03 [INFO]   Found in community-scripts: port 6989
2026-08-25 14:30:03 [INFO]   Added 'nexterm' to Flame.
2026-08-25 14:30:03 [INFO] Processing LXC 104 (database)...
2026-08-25 14:30:03 [INFO]   No web service detected on database — skipping.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Summary
   Added:           3
   Already existed: 0
   No web service:  1
   Skipped (Flame): 1
   Failed:          0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## install-avahi-all-lxcs.sh

Check all running LXC containers for `avahi-daemon` and install it if missing. Enables `.local` mDNS resolution for service discovery (used by flame-auto-discover).

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

## netdata-postinstall.sh

Configure Netdata on the PVE host to monitor LXC containers via cgroups v2.

**Download:**

```bash
cd /root/scripts
wget -O netdata-postinstall.sh \
  https://raw.githubusercontent.com/vojacekj/proxmox-lxc-scripts/main/netdata-postinstall.sh
chmod +x netdata-postinstall.sh
```

**Run:**

```bash
/root/scripts/netdata-postinstall.sh
```

**What it does:**
- Detects cgroups v2 (unified hierarchy) on the Proxmox host
- Adds `netdata` user to `www-data` group for `/etc/pve` access
- Creates drop-in config at `/etc/netdata/netdata.conf.d/proxmox-cgroups-v2.conf`
- Overrides Netdata's default cgroup exclusion patterns to enable `/lxc/<vmid>/` paths
- Configures cgroup-name helper for VMID-to-name resolution
- Restarts Netdata and verifies container discovery

**Why is this needed?**

Proxmox 8+ uses cgroups v2 with containers at `/sys/fs/cgroup/lxc/<vmid>/`. Netdata's default config excludes `/lxc` entirely, so LXC containers don't appear in the dashboard. This script fixes that.

**Example output:**

```
2026-08-25 19:10:01 [INFO] Detected cgroups version: v2
2026-08-25 19:10:01 [INFO] Added netdata user to www-data group
2026-08-25 19:10:01 [INFO] Found 11 LXC container configurations in /etc/pve/lxc/
2026-08-25 19:10:01 [INFO] Created drop-in configuration: /etc/netdata/netdata.conf.d/proxmox-cgroups-v2.conf
2026-08-25 19:10:02 [INFO] Restarting Netdata...
2026-08-25 19:10:02 [INFO] Netdata restarted successfully
2026-08-25 19:10:32 [INFO] === Post-Install Complete ===
2026-08-25 19:10:32 [INFO] Access Netdata at: http://192.168.1.238:19999
```

---

## Security

- Config files with secrets (`telegram.conf`, `gotify.conf`, `flame-auto-discover.conf`) are **gitignored**
- Config files must have `600` ownership `root:root` permissions to be loaded — the script refuses to load insecure files
- No secrets are ever printed to the terminal or included in notifications

## License

MIT
