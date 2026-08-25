# Proxmox LXC Scripts

Helper scripts for managing Proxmox VE LXC containers with **Telegram** and **Gotify** notifications.

## Scripts

| Script | Description |
|--------|-------------|
| `install-avahi-all-lxcs.sh` | Check all running LXCs for `avahi-daemon` and install it if missing |

## Notification Setup

Both **Telegram** and **Gotify** are supported. If both config files exist, notifications are sent to both channels. If only one exists, only that one receives notifications.

### Telegram

1. Talk to [@BotFather](https://t.me/BotFather) on Telegram and create a bot to get your **Bot Token**.
2. Send any message to your bot, then visit:
   ```
   https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
   ```
   to find your **Chat ID**.
3. Copy the example config and fill in your values:
   ```bash
   cp telegram.conf.example telegram.conf
   chmod 600 telegram.conf
   ```

### Gotify

1. Install Gotify (via [community-scripts](https://community-scripts.org/scripts/gotify) or Docker).
2. Create an **Application** in the Gotify web UI and copy the token.
3. Copy the example config and fill in your values:
   ```bash
   cp gotify.conf.example gotify.conf
   chmod 600 gotify.conf
   ```

Config is loaded from the script's directory first, then from `/etc/pve-telegram.conf` / `/etc/pve-gotify.conf`.

## Usage

### install-avahi-all-lxcs.sh

Run on the **Proxmox host** (not inside an LXC):

```bash
wget https://raw.githubusercontent.com/vojacekj/proxmox-lxc-scripts/main/install-avahi-all-lxcs.sh
chmod +x install-avahi-all-lxcs.sh
./install-avahi-all-lxcs.sh
```

**What it does:**
- Iterates all LXC containers on the host
- Skips stopped containers (reports them)
- Checks if `avahi-daemon` is installed in each running LXC
- Installs and enables the service if missing
- Sends a summary notification via Telegram and/or Gotify

**Example output:**
```
[100] webserver           already installed
[101] database            installing avahi-daemon... done
[102] old-test            SKIP (stopped)

==========================================
 Summary
==========================================
 Installed:         1
 Already present:   1
 Skipped (stopped): 1
 Failed:            0
==========================================
```

## Security

- Config files with secrets (`telegram.conf`, `gotify.conf`) are **gitignored**
- Config files must have `600` permissions to be loaded — the script warns and skips insecure files
- No secrets are ever printed to the terminal or included in notifications

## License

MIT
