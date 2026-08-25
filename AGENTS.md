# AGENTS.md

Instructions for AI coding assistants working on this repository.

## Repository Overview

Proxmox VE helper scripts for LXC container management with Telegram/Gotify notifications. All scripts run on the Proxmox host as root.

## Scripts

| Script | Purpose |
|--------|---------|
| `flame-auto-discover.sh` | Auto-detect LXC services, add to Flame dashboard |
| `install-avahi-all-lxcs.sh` | Install avahi-daemon in all running LXCs |

## flame-auto-discover.sh

### Architecture

- Runs on Proxmox host, uses `pct exec` to interact with LXC containers
- Directly modifies Flame's SQLite database via `pct exec $LXC_ID -- sqlite3`
- No Flame authentication needed (direct DB access)
- Auto-detects Flame LXC by container name "flame" or port 5005 scan
- Saves `FLAME_LXC_ID` to config file after first successful detection

### Port Resolution Order

1. Manual overrides (`PORT_OVERRIDES` in config)
2. Hardcoded `SERVICE_MAP` associative array (~80 services)
3. On-demand query to community-scripts GitHub API (cached 7 days in `/tmp`)
4. Port scanning via `nc -zw2` on common ports

### Icon Resolution Order

1. Manual overrides (`ICON_OVERRIDES` in config)
2. `selfhst/icons` CDN via service map lookup
3. Generic `server.svg` fallback (no favicon — Flame can't reach local network)

### Key Functions

- `detect_flame_lxc()` — Find Flame container, validate DB, prompt user
- `validate_flame_db()` — Check DB exists, install sqlite3 if missing, verify `apps` table
- `flame_insert_app()` — INSERT INTO apps with isPinned=1, isPublic=1
- `fetch_port_from_community_scripts()` — Query GitHub raw URL, parse port from script output
- `normalize_url()` — Strip trailing slashes and default ports for dedup
- `flame_url_exists()` / `flame_name_exists()` — Case-insensitive dedup

### Skip Behavior

- `SKIP_APPS` config variable controls which containers are excluded
- Format: comma-separated container names, case-insensitive (e.g., `"pve,monitoring"`)
- Checked after name normalization: `[[ ",${SKIP_APPS}," == *",${name_lower},"* ]]`
- All LXCs processed by default (no built-in skip list)
- Flame itself is included in the list — not skipped

### Config File

`flame-auto-discover.conf` (permissions: 600, root:root required)

```
FLAME_LXC_ID="108"
SCAN_PORTS="80,443,8080,..."
PORT_OVERRIDES="myapp:8080 custom:3000"
ICON_OVERRIDES="myapp:https://cdn.jsdelivr.net/gh/selfhst/icons@main/svg/docker.svg"
SKIP_APPS="pve,monitoring"
```

- `SKIP_APPS`: Comma-separated container names to exclude from auto-discovery
- All LXCs are now processed by default (including Flame itself)

### Notification Format

Notifications include counts and service names:
```
*Flame Auto-Discover: pve01.local*

Added: 3
jellyfin, pihole, nexterm
Already existed: 2
portainer, gotify
No web service: 1
Failed: 0
```

### Dependencies

- Host: `curl`, `jq`, `nc` (netcat-openbsd), `pct`, `sqlite3`
- Flame LXC: `sqlite3` (auto-installed if missing)

### Testing

- `bash -n flame-auto-discover.sh` — syntax check
- `./flame-auto-discover.sh --dry-run` — preview without changes
- `./flame-auto-discover.sh --detect` — re-detect Flame LXC

## Code Conventions

- All scripts use `#!/bin/bash` with `set -e` equivalent via `catch_errors`
- Logging via `log LEVEL message` function (writes to stderr and syslog)
- Config loaded from script dir first, then `/etc/pve-*.conf`
- Config files must be 600 root:root — script refuses to load insecure files
- Notifications sent to both Telegram and Gotify if both configured
- No secrets printed to terminal or included in notifications
- SQL strings escaped with single quote doubling: `'` → `''`

## Git Conventions

- Commit messages: imperative mood, lowercase, no period
- Config files (`*.conf`) are gitignored, only `*.conf.example` committed
- Run `bash -n` syntax check before committing shell scripts
- **Always update README.md and AGENTS.md** when making changes to script behavior, config options, or functions
