# Proxmox LXC Scripts

Helper scripts for managing Proxmox VE LXC containers with **Telegram** and **Gotify** notifications.

## Scripts

| Script | Description |
|--------|-------------|
| `install-avahi-all-lxcs.sh` | Check all running LXCs for `avahi-daemon` and install it if missing |
| `netdata-postinstall.sh` | Configure Netdata on PVE host to monitor LXC containers via cgroups v2 |

## Installation

Clone the repo to `/root/scripts` on your Proxmox host:

```bash
mkdir -p /root/scripts
cd /root/scripts
git clone https://github.com/vojacekj/proxmox-lxc-scripts.git .
```

Or download scripts and configs individually:

```bash
mkdir -p /root/scripts
wget -O /root/scripts/install-avahi-all-lxcs.sh \
  https://raw.githubusercontent.com/vojacekj/proxmox-lxc-scripts/main/install-avahi-all-lxcs.sh
wget -O /root/scripts/netdata-postinstall.sh \
  https://raw.githubusercontent.com/vojacekj/proxmox-lxc-scripts/main/netdata-postinstall.sh
wget -O /root/scripts/telegram.conf.example \
  https://raw.githubusercontent.com/vojacekj/proxmox-lxc-scripts/main/telegram.conf.example
wget -O /root/scripts/gotify.conf.example \
  https://raw.githubusercontent.com/vojacekj/proxmox-lxc-scripts/main/gotify.conf.example
chmod +x /root/scripts/install-avahi-all-lxcs.sh
chmod +x /root/scripts/netdata-postinstall.sh
```

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

## Usage

### install-avahi-all-lxcs.sh

Run on the **Proxmox host** (not inside an LXC):

```bash
/root/scripts/install-avahi-all-lxcs.sh
```

### netdata-postinstall.sh

Run on the **Proxmox host** after installing Netdata (e.g. via community-scripts):

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

**Why is this needed?**
Proxmox 8+ uses cgroups v2 with containers at `/sys/fs/cgroup/lxc/<vmid>/`. Netdata's default config excludes `/lxc` entirely, so LXC containers don't appear in the dashboard. This script fixes that.

### Weekly crontab

Add a crontab entry to check all LXCs every Sunday at 3 AM:

```bash
crontab -e
# Add this line:
0 3 * * 0 /root/scripts/install-avahi-all-lxcs.sh >> /var/log/avahi-install.log 2>&1
```

**What it does:**
- Iterates all LXC containers on the host
- Skips stopped containers and containers without apt-get
- Checks if `avahi-daemon` is installed in each running LXC
- Installs and enables the service if missing
- Sends a summary notification via Telegram and/or Gotify

**Example output:**
```
2026-08-25 14:30:01 [INFO] ℹ️ Starting avahi-daemon check on pve01...
2026-08-25 14:30:01 [INFO] ℹ️ Checking LXC 101 (authentik)...
2026-08-25 14:30:03 [INFO] ✅ ID 101 (authentik): avahi-daemon already installed
2026-08-25 14:30:03 [INFO] ℹ️ Checking LXC 102 (database)...
2026-08-25 14:30:05 [INFO] ✅ ID 102 (database): avahi-daemon installed and started
2026-08-25 14:30:05 [INFO] ⏭️ ID 103 (alpine-box): No apt-get found
2026-08-25 14:30:05 [INFO] ⏭️ ID 104 (old-test): Stopped — skipping
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 Summary
   Installed:         1
   Already present:   1
   Skipped (stopped): 1
   Skipped (no apt):  1
   Failed:            0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Security

- Config files with secrets (`telegram.conf`, `gotify.conf`) are **gitignored**
- Config files must have `600` ownership `root:root` permissions to be loaded — the script refuses to load insecure files
- No secrets are ever printed to the terminal or included in notifications

## License

MIT
