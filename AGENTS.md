# AGENTS.md

Instructions for AI coding assistants working on this repository.

## Repository Overview

Proxmox VE helper scripts for LXC container management with Telegram/Gotify notifications. `dashboard-discover.sh` feeds a self-hosted monitoring stack (Gatus + Homepage) running as LXCs on the same Proxmox host. All scripts run on the Proxmox host as root.

## Scripts

| Script | Purpose |
|--------|---------|
| `dashboard-discover.sh` | Auto-detect LXC web services, generate Gatus + Homepage config |
| `install-avahi-all-lxcs.sh` | Install avahi-daemon in all running LXCs |

## dashboard-discover.sh

### Architecture

- Runs on Proxmox host, uses `pct` to inspect LXCs
- Does **not** use a database — it writes YAML config files that Gatus and Homepage hot-reload
- Auto-detects the Gatus and Homepage LXC by container name (falls back to port scan: Gatus `8080`, Homepage `3000`)
- Pushes generated config files into the target LXC via `pct push`
- No auth tokens needed (both apps reload config from disk)

### Stack

- **Gatus** (LXC, `ct/gatus.sh` install): prober. Config at `/opt/gatus/config`, port `8080`, watch-logic: re-reads config every ~30s, hot-reloads, builds a Go binary and `setcap CAP_NET_RAW+ep` (ICMP/ping checks work).
- **Homepage** (LXC, `ct/homepage.sh` install): start page. Config at `/opt/homepage/config`, port `3000`, hot-reloads on YAML file change (no restart for `services.yaml`). Requires `HOMEPAGE_ALLOWED_HOSTS` in `/etc/systemd/system/homepage.service` (or `/opt/homepage/.env` if the unit uses `EnvironmentFile`) or Homepage v1.0+ refuses connections with "Host validation failed". Documented in README.

### Port Resolution Order

1. Manual overrides (`PORT_OVERRIDES` in config)
2. Hardcoded `SERVICE_MAP` associative array (~80 services)
3. Port scanning via `nc -zw2` on common ports

(Note: the older Flame script queried community-scripts GitHub on demand for ports; that port lookup was dropped when Flame support was removed. An on-demand community-scripts **icon** lookup was reintroduced for logos — `fetch_icon_from_community_scripts()`.)

### Icon Resolution Order

- `get_icon_url()` returns full selfhst CDN URLs (used where a raw URL is needed)
- `homepage_icon()` returns a Homepage icon value: `sh-<name>` shorthand for known services (selfhst CDN slug, dashes/underscores preserved), a full CDN URL for custom apps, an on-demand community-scripts logo, or the selfhst `server.svg` CDN fallback
- `CUSTOM_ICON_DEFAULTS` (assoc array) provides CDN fallback icons for known custom apps (omnitools, yuvomi, convertx, proxmox-hive, proxmox) that have no SERVICE_MAP entry / selfhst slug — checked after overrides
- `fetch_icon_from_community_scripts()` — on-demand official-logo lookup: fetches `https://community-scripts.org/scripts/<app>`, extracts its `rel="icon"` jsDelivr CDN URL, caches 7 days in `/tmp` (mirrors the old flame community-scripts port lookup)
- **Icons never use `.local` or favicon endpoints** — all icons come from a CDN; the community-scripts source is the site's own jsDelivr logo link
- Manual `ICON_OVERRIDES` (full URLs) take precedence over all of the above

### Grouping

- `CATEGORY_MAP` is a `|`-separated list of `group:member,member,...`; groups mirror the `SERVICE_MAP` section headers
- `get_service_group()` (in `get_service_group`) maps a hostname to a group for Gatus `group:` and Homepage sections; unmatched → `default`/`other`
- `SERVICE_MAP` and `CATEGORY_MAP` must be kept in sync

### Key Functions

- `get_lxc_ip()` — resolve an LXC IP from static config, mDNS, or /etc/hosts
- `scan_web_port()` — `nc -zw2` probe across `SCAN_PORTS`
- `gatus_config_header()` — metrics + sqlite storage + auto `alerting:` block from Telegram/Gotify creds + `interval` + an `endpoints:` placeholder
- `gatus_endpoint_yaml()` — one HTTP/TCP check (name, group, url, quoted `[CONNECTED]` condition, alerts). The monitor `url` always uses the raw IP (see below). HTTPS endpoints get `skipTLSVerify: true` so self-signed certs (e.g. Portainer on 9443) don't fail the probe. The condition value is **quoted** (`- "[CONNECTED] == true"`) because a leading `[` is otherwise parsed as a YAML flow sequence and Gatus exits on config parse error. `alerts:` lists only providers actually configured (telegram only if `TOKEN`+`CHAT_ID`, gotify only if `GOTIFY_SERVER`+`GOTIFY_TOKEN`), since Gatus fails if an endpoint references an undeclared alerting provider.
- `link_host()` — returns the `name.local` mDNS hostname when `USE_LOCAL_DOMAINS=yes`, else the raw IP; used for browser-facing Homepage `href` links only
- Gatus monitor `url` targets always use the raw IP (Gatus is a Go binary whose resolver doesn't do mDNS, so `*.local` probes fail); `USE_LOCAL_DOMAINS` does **not** affect Gatus endpoints
- `homepage_service_yaml()` — one service entry (href, icon). The Gatus widget is attached **only to the `gatus` service card**, since the widget shows Gatus-wide aggregate stats; repeating it on every card duplicates identical numbers.
- `homepage_icon()` — Homepage icon (`sh-` for known services, full CDN URL for custom apps/fallback); never `.local`
- `send_telegram()` / `send_gotify()` / `send_notification()` — post over the configured channel(s); `send_notification` is called at the end of discovery with a status report **only when a service was added or a push failed** (idle runs notify nothing, like Flame). "Added" is derived from `new_service_names()` / `new_endpoint_names()` (names in the generated config not yet in the deployed file); the summary also logs downstream services skipped as already known.
- `new_service_names()` / `new_endpoint_names()` — `comm`-based diff of generated-vs-deployed names, used to decide what was actually added this run (drive the notification + summary counters).
- Manual-preservation merge: both Gatus and Homepage config are merged with the live file before pushing, so anything already deployed is left **untouched** and only services/endpoints this run discovered but that aren't in the live file yet are added ("only add new", like Flame). This is purely name-driven (`extract_service_names()` / `extract_endpoint_names()` build the set of names already deployed). `merge_homepage_yaml()` keeps the deployed file verbatim then appends new blocks under a repeated `- Group:` header (Homepage merges same-named groups); `merge_gatus_yaml()` keeps the deployed config verbatim and splices new endpoint blocks under the `endpoints:` line. Because existing entries are never rewritten, a manual edit (e.g. changing proxmox's href) is automatically preserved, and unchanged files don't churn Homepage/Gatus reloads.
- `pct_push()` — `pct exec mkdir -p` + `pct push` + `chmod` into an LXC
- `find_lxc_by_name()` — locate a running LXC by name substring or open port
- Proxmox host service: the PVE host isn't an LXC, so discovery skips it; `homepage` config adds it as a managed service (https on `PVE_HOST_PORT`) when `PVE_HOST_IP` is set (auto-detected from the host's primary interface if blank)

### Skip Behavior

- `SKIP_APPS` controls excluded containers; comma-separated, case-insensitive
- Checked after name normalization: `[[ ",${SKIP_APPS}," == *",${name_lower},"* ]]`

### Config File

`dashboard-discover.conf` (permissions: 600, root:root required)

```
GATUS_ENABLED="yes"
GATUS_LXC_ID="101"
GATUS_CONFIG_DIR="/opt/gatus/config"
GATUS_SCAN_INTERVAL="60"
GATUS_ALERTING="yes"
GATUS_RESTART_SERVICE="no"
GATUS_PORT="8080"
HOMEPAGE_ENABLED="yes"
HOMEPAGE_LXC_ID="102"
HOMEPAGE_CONFIG_DIR="/opt/homepage/config"
HOMEPAGE_SERVICES_FILE="services.yaml"
HOMEPAGE_GATUS_URL=""
USE_LOCAL_DOMAINS="yes"
PVE_HOST_IP="192.168.1.10"
SCAN_PORTS="80,443,8080,..."
PORT_OVERRIDES="myapp:8080 custom:3000"
ICON_OVERRIDES="myapp:https://cdn.jsdelivr.net/gh/selfhst/icons@main/svg/docker.svg"
SKIP_APPS="pve,monitoring"
```

### Dependencies

- Host: `curl`, `pct`, `nc` (netcat-openbsd)
- Gatus LXC: nothing extra (binary + systemd from ct/gatus.sh)
- Homepage LXC: nothing extra (from ct/homepage.sh)

### Testing

Automated checks (shellcheck + bats) run in CI on every push/PR via `.github/workflows/ci.yml`. Run them locally with:

- `make lint` — run ShellCheck on both scripts (`shellcheck --severity=warning`)
- `make test` — run bats unit tests (`BASH=<bash5> bats tests/`)
- `make check` — syntax check + lint + tests (same as CI)

Manual checks (require a live Proxmox host):
- `./dashboard-discover.sh --dry-run` — preview without pushing files
- `./dashboard-discover.sh --detect` — re-detect Gatus/Homepage LXC

#### Test architecture

- `tests/` uses [bats-core](https://github.com/bats-core/bats-core), one file per module
- `tests/test_helper.bash` generates a "testable extract" of `dashboard-discover.sh`: it pulls in the global defaults, the `SERVICE_MAP` array, `CATEGORY_MAP`, and the pure functions (`normalize_url`, `lookup_service`, `get_icon_url`, `get_port_override`, `get_service_group`, `homepage_icon`, `gatus_config_header`, `gatus_endpoint_yaml`, `homepage_service_yaml`, `parse_args`)
- **`declare -A` associative arrays don't propagate into the subshells bats `run` uses** — the helper rewrites the map with `declare -gxA` (bash 5.1+) so it's exported and visible
- bash 3.2 (macOS default) can't run the tests; use Homebrew bash (`brew install bash`, then `make test` auto-detects it). CI (Ubuntu) has bash 5.x
- Tests run without Proxmox or any LXC — all functions tested are pure logic

## Code Conventions

- All scripts use `#!/bin/bash`
- Logging via `log LEVEL message` function (writes to stderr and syslog)
- Config loaded from script dir first, then `/etc/pve-*.conf`
- Config files must be 600 root:root — script refuses to load insecure files
- Notifications sent to both Telegram and Gotify if both configured
- No secrets printed to terminal or included in notifications
- Generated YAML must use correct indentation for the target app (Homepage: groups col 0, services 4, props 8; Gatus: endpoints under `endpoints:`)

## Git Conventions

- Commit messages: imperative mood, lowercase, no period
- Config files (`*.conf`) are gitignored, only `*.conf.example` committed
- Run `make check` (or at least `bash -n` + `shellcheck`) before committing shell scripts
- **Always update README.md and AGENTS.md** when making changes to script behavior, config options, or functions
- When adding/removing services, `SERVICE_MAP`/`CATEGORY_MAP` entries or helper functions, keep `tests/` in sync