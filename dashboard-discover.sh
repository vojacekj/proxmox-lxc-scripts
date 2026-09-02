#!/bin/bash
#
# Dashboard Auto-Discover for Proxmox LXC
#
# Automatically detects running LXC containers on the Proxmox host,
# determines which ones are web services, and generates:
#   1. Gatus check configuration (port-aware health checks + alerting)
#   2. Homepage dashboard services.yaml (icons + links + status widgets)
#
# Both Gatus and Homepage reload their configuration on file change,
# so no service restarts are needed. Gatus and Homepage run as LXCs;
# files are pushed in via `pct push`.
#
# Icons use the shorthand from selfhst/icons (https://github.com/selfhst/icons)
# Default ports sourced from community-scripts/ProxmoxVE
#
# Use this script at your own risk.

SCRIPT_VERSION="v1.0.0"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- LOGGING ---
LOG_STDOUT="${LOG_STDOUT:-yes}"

log() {
  local level="${1:-INFO}"
  shift
  local timestamp
  printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1
  local message
  message="${timestamp} [${level}] $*"

  if [[ "${LOG_STDOUT}" == "yes" ]]; then
    echo "${message}" >&2
  fi

  if command -v logger &>/dev/null; then
    logger -t "dashboard-discover" -p "user.${level,,}" -- "$*" 2>/dev/null || true
  fi
}

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
CONF_FILE="${SCRIPT_DIR}/dashboard-discover.conf"

secure_source() {
  local conf_file="$1"
  if [[ ! -f "$conf_file" ]]; then return 0; fi
  if [[ -h "$conf_file" ]]; then
    log ERROR "SECURITY CRITICAL: $conf_file is a symlink. Refusing to load."
    return 1
  fi

  local stat_out perms owner
  stat_out=$(stat -c "%a %U" "$conf_file" 2>/dev/null || echo "777 root")
  perms="${stat_out%% *}"
  owner="${stat_out#* }"

  if [[ "$perms" != "600" ]] || [[ "$owner" != "root" ]]; then
    log ERROR "SECURITY CRITICAL: Config file $conf_file has insecure permissions/ownership ($perms $owner). Refusing to load."
    return 1
  fi
  source "$conf_file"
}

# Load config
SCAN_PORTS="80,443,8080,8443,3000,5000,8096,8920,9090,8123,7878,8888,9000,9696,5678"
PORT_OVERRIDES=""
ICON_OVERRIDES=""
SKIP_APPS=""

# Gatus
GATUS_ENABLED="yes"
GATUS_LXC_ID=""
GATUS_CONFIG_DIR="/opt/gatus/config"
GATUS_CONFIG_MODE="single"
GATUS_SCAN_INTERVAL="60"
GATUS_ALERTING="yes"
GATUS_RESTART_SERVICE="no"
GATUS_PORT="8080"

# Uptime Kuma (trial/side-by-side backend). Auto-managed by writing monitor rows
# directly into Kuma's SQLite DB (see write_kuma_monitors). This is opt-in and
# separate from Gatus: set KUMA_ENABLED=yes to also mirror discovered services
# into Kuma for evaluation.
KUMA_ENABLED="no"
KUMA_LXC_ID=""
KUMA_DB_PATH="/opt/uptime-kuma/data/kuma.db"
KUMA_PORT="3001"
KUMA_INTERVAL="60"
KUMA_RESTART_SERVICE="yes"
# Status page (slug in status_page) whose default group receives the discovered
# monitors so they show up on it. Leave empty to skip linking to a status page.
KUMA_STATUS_PAGE_SLUG=""

# Homepage
HOMEPAGE_ENABLED="yes"
HOMEPAGE_LXC_ID=""
HOMEPAGE_CONFIG_DIR="/opt/homepage/config"
HOMEPAGE_SERVICES_FILE="services.yaml"
# Base URL Homepage uses to reach the Gatus widget (defaults to the hostname
# used during discovery; override with the IP if mDNS is not set up).
HOMEPAGE_GATUS_URL=""
# Link each service by its mDNS hostname (<name>.local) instead of its raw IP.
# Gatus still probes the real IP; only the Homepage links switch to hostnames.
USE_LOCAL_DOMAINS="yes"

# Proxmox host (PVE) as a managed service. The host is NOT an LXC, so it isn't
# auto-discovered; set PVE_HOST_IP to include it (PVE web UI on https:8006).
# PVE_HOST_IP is auto-detected from the host's primary interface if unset.
PVE_HOST_IP=""
PVE_HOST_NAME="proxmox"
PVE_HOST_PORT="8006"

if [[ -f "$CONF_FILE" ]]; then
  secure_source "$CONF_FILE"
elif [[ -f "/etc/pve-dashboard-discover.conf" ]]; then
  secure_source "/etc/pve-dashboard-discover.conf"
  CONF_FILE="/etc/pve-dashboard-discover.conf"
fi

# Load Telegram config
TOKEN=""
CHAT_ID=""
if [[ -f "${SCRIPT_DIR}/telegram.conf" ]]; then
  secure_source "${SCRIPT_DIR}/telegram.conf"
elif [[ -f "/etc/pve-telegram.conf" ]]; then
  secure_source "/etc/pve-telegram.conf"
fi
TOKEN="${TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"

# Load Gotify config
GOTIFY_SERVER=""
GOTIFY_TOKEN=""
if [[ -f "${SCRIPT_DIR}/gotify.conf" ]]; then
  secure_source "${SCRIPT_DIR}/gotify.conf"
elif [[ -f "/etc/pve-gotify.conf" ]]; then
  secure_source "/etc/pve-gotify.conf"
fi
GOTIFY_SERVER="${GOTIFY_SERVER:-}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"

# --- NOTIFICATION FUNCTIONS ---
send_telegram() {
  local message="$1"
  [[ -z "${TOKEN}" || -z "${CHAT_ID}" ]] && return 0

  local URL="https://api.telegram.org/bot${TOKEN}/sendMessage"

  local RESPONSE
  RESPONSE=$(curl --proto '=https' --tlsv1.2 -s --connect-timeout 10 --max-time 30 -X POST -K <(cat <<CURL_CONF
url = "$URL"
data-urlencode = "chat_id=$CHAT_ID"
data-urlencode = "parse_mode=Markdown"
CURL_CONF
) --data-urlencode "text@-" <<< "$message")

  if [[ $RESPONSE != *'"ok":true'* ]]; then
    log ERROR "Telegram Error: $RESPONSE"
  fi
}

send_gotify() {
  local message="$1"
  [[ -z "${GOTIFY_SERVER}" || -z "${GOTIFY_TOKEN}" ]] && return 0

  local url="${GOTIFY_SERVER}/message?token=${GOTIFY_TOKEN}"
  local curl_flags=(-s --connect-timeout 10 --max-time 30)

  if [[ "$GOTIFY_SERVER" == https://* ]]; then
    curl_flags+=(--proto '=https' --tlsv1.2)
  fi

  local plain_message
  plain_message="${message//\*/}"
  plain_message="${plain_message//\\/\\\\}"
  plain_message="${plain_message//\"/\\\"}"
  plain_message="${plain_message//$'\n'/\\n}"
  plain_message="${plain_message//$'\t'/\\t}"

  local RESPONSE
  RESPONSE=$(curl "${curl_flags[@]}" \
    -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"Dashboard Auto-Discover\", \"message\": \"${plain_message}\", \"priority\": 5}")

  if [[ $RESPONSE != *"id"* ]]; then
    log ERROR "Gotify Error: $RESPONSE"
  fi
}

send_notification() {
  local message="$1"
  send_telegram "$message"
  send_gotify "$message"
}

# --- SERVICE MAP ---
# Associative array: hostname_pattern -> "selfhst_ref:default_port"
declare -A SERVICE_MAP=(
  # Media
  ["jellyfin"]="jellyfin:8096"
  ["plex"]="plex:32400"
  ["tautulli"]="tautulli:8181"
  ["overseerr"]="overseerr:5055"
  ["jellyseerr"]="overseerr:5055"
  ["emby"]="emby:8096"
  ["audiobookshelf"]="audiobookshelf:13378"

  # Arr Stack
  ["sonarr"]="sonarr:8989"
  ["radarr"]="radarr:7878"
  ["prowlarr"]="prowlarr:9696"
  ["lidarr"]="lidarr:8686"
  ["readarr"]="readarr:8787"
  ["bazarr"]="bazarr:6767"
  ["autobrr"]="autobrr:7474"

  # Downloads
  ["qbittorrent"]="qbittorrent:8080"
  ["transmission"]="transmission:9091"
  ["deluge"]="deluge:8112"
  ["nzbget"]="nzbget:6789"
  ["sabnzbd"]="sabnzbd:8080"

  # Infrastructure
  ["portainer"]="portainer:9443"
  ["traefik"]="traefik:8080"
  ["nginxproxymanager"]="nginx-proxy-manager:81"
  ["npm"]="nginx-proxy-manager:81"
  ["caddy"]="caddy:2019"
  ["haproxy"]="haproxy:8404"
  ["dockge"]="dockge:5001"

  # DNS
  ["pihole"]="pi-hole:80"
  ["pi-hole"]="pi-hole:80"
  ["adguard"]="adguard-home:80"
  ["adguardhome"]="adguard-home:80"
  ["blocky"]="blocky:4000"

  # Monitoring
  ["grafana"]="grafana:3000"
  ["prometheus"]="prometheus:9090"
  ["netdata"]="netdata:19999"
  ["uptimekuma"]="uptime-kuma:3001"
  ["uptime-kuma"]="uptime-kuma:3001"
  ["gatus"]="gatus:8080"
  ["beszel"]="beszel:8090"

  # Automation
  ["n8n"]="n8n:5678"
  ["node-red"]="node-red:1880"
  ["nodered"]="node-red:1880"
  ["homeassistant"]="home-assistant:8123"
  ["home-assistant"]="home-assistant:8123"
  ["hass"]="home-assistant:8123"
  ["esphome"]="esphome:6052"
  ["zigbee2mqtt"]="zigbee2mqtt:8080"
  ["frigate"]="frigate:5000"
  ["mosquitto"]="mosquitto:1883"
  ["mqtt"]="mqtt:1883"

  # Cloud / Storage
  ["nextcloud"]="nextcloud:443"
  ["owncloud"]="owncloud:443"
  ["seafile"]="seafile:80"
  ["filebrowser"]="file-browser:8080"
  ["file-browser"]="file-browser:8080"
  ["minio"]="minio:9001"
  ["immich"]="immich:2283"
  ["paperless"]="paperless-ngx:8000"
  ["paperless-ngx"]="paperless-ngx:8000"

  # Git / Code
  ["gitea"]="gitea:3000"
  ["forgejo"]="forgejo:3000"
  ["gitlab"]="gitlab:443"
  ["code-server"]="code-server:8443"
  ["nexterm"]="nexterm:6989"

  # Auth
  ["vaultwarden"]="vaultwarden:8000"
  ["bitwarden"]="vaultwarden:8000"
  ["authentik"]="authentik:9000"
  ["authelia"]="authelia:9091"

  # Communication
  ["matrix"]="matrix:8008"
  ["gotify"]="gotify:80"
  ["ntfy"]="ntfy:80"
  ["gotosocial"]="gotosocial:8080"
  ["lemmy"]="lemmy:8536"
  ["friendica"]="friendica:80"
  ["discourse"]="discourse:80"
  ["ghost"]="ghost:2368"

  # Documents
  ["bookstack"]="bookstack:80"
  ["wikijs"]="wiki-js:3000"
  ["dokuwiki"]="dokuwiki:80"
  ["outline"]="outline:3000"
  ["mealie"]="mealie:9925"
  ["karakeep"]="karakeep:3000"
  ["hedgedoc"]="hedgedoc:3000"
  ["drawio"]="draw-io:8080"

  # Dashboards
  ["dashy"]="dashy:4000"
  ["heimdall"]="heimdall:80"
  ["homarr"]="homarr:7575"
  ["homepage"]="homepage:3000"

  # Analytics
  ["plausible"]="plausible:8000"
  ["matomo"]="matomo:80"
  ["umami"]="umami:3000"

  # Databases
  ["adminer"]="adminer:8080"
  ["phpmyadmin"]="phpmyadmin:80"
  ["cloudbeaver"]="cloudbeaver:8978"

  # Other
  ["changedetection"]="changedetection:5000"
  ["cdio"]="changedetection:5000"
  ["actualbudget"]="actual-budget:5006"
  ["actual"]="actual-budget:5006"
  ["duplicati"]="duplicati:8200"
  ["freshrss"]="freshrss:80"
  ["filerun"]="filerun:80"
  ["grocy"]="grocy:80"
  ["firefly"]="firefly-iii:8080"
  ["firefly-iii"]="firefly-iii:8080"
  ["librespeed"]="librespeed:80"
)

# --- CATEGORY MAP ---
# Group name -> comma-separated service hostname prefixes (lowercase)
# Used by both Gatus (endpoint groups) and Homepage (dashboard sections).
CATEGORY_MAP="media:jellyfin,plex,tautulli,overseerr,jellyseerr,emby,audiobookshelf\
|arr-stack:sonarr,radarr,prowlarr,lidarr,readarr,bazarr,autobrr\
|downloads:qbittorrent,transmission,deluge,nzbget,sabnzbd\
|infrastructure:portainer,traefik,nginxproxymanager,npm,caddy,haproxy,dockge\
|dns:pihole,pi-hole,adguard,adguardhome,blocky\
|monitoring:grafana,prometheus,netdata,uptimekuma,uptime-kuma,gatus,beszel\
|automation:n8n,node-red,nodered,homeassistant,home-assistant,hass,esphome,zigbee2mqtt,frigate,mosquitto,mqtt\
|cloud:nextcloud,owncloud,seafile,filebrowser,file-browser,minio,immich,paperless,paperless-ngx\
|code:gitea,forgejo,gitlab,code-server,nexterm\
|auth:vaultwarden,bitwarden,authentik,authelia\
|communication:matrix,gotify,ntfy,gotosocial,lemmy,friendica,discourse,ghost\
|documents:bookstack,wikijs,dokuwiki,outline,mealie,karakeep,hedgedoc,drawio\
|dashboards:dashy,heimdall,homarr,homepage\
|analytics:plausible,matomo,umami\
|databases:adminer,phpmyadmin,cloudbeaver\
|other:changedetection,cdio,actualbudget,actual,duplicati,freshrss,filerun,grocy,firefly,firefly-iii,librespeed"

# --- SERVICE LOOKUP ---
lookup_service() {
  local hostname_lower
  hostname_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

  [[ -z "$hostname_lower" ]] && return 1

  # Direct match
  if [[ -n "${SERVICE_MAP[$hostname_lower]+x}" ]]; then
    echo "${SERVICE_MAP[$hostname_lower]}"
    return 0
  fi

  # Partial match
  local key
  for key in "${!SERVICE_MAP[@]}"; do
    if [[ "$hostname_lower" == *"$key"* ]] || [[ "$key" == *"$hostname_lower"* ]]; then
      echo "${SERVICE_MAP[$key]}"
      return 0
    fi
  done

  return 1
}

# --- GROUP LOOKUP ---
# Returns the group name (from CATEGORY_MAP) for a hostname, or "" if unknown.
get_service_group() {
  local hostname_lower
  hostname_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  [[ -z "$hostname_lower" ]] && return 1

  local entry
  IFS='|' read -ra entries <<< "$CATEGORY_MAP"
  for entry in "${entries[@]}"; do
    local group="${entry%%:*}"
    local members="${entry#*:}"
    IFS=',' read -ra members_arr <<< "$members"
    local member
    for member in "${members_arr[@]}"; do
      if [[ "$hostname_lower" == "$member" || "$hostname_lower" == *"$member"* ]]; then
        echo "$group"
        return 0
      fi
    done
  done
  return 1
}

# --- IP RESOLUTION ---
get_lxc_ip() {
  local vmid="$1"

  # Try to get static IP from config
  local ip
  ip=$(pct config "$vmid" 2>/dev/null | grep -A1 "net0:" | grep "ip=" | grep -oP 'ip=\K[^,/]+' | head -1)

  if [[ -n "$ip" && "$ip" != "dhcp" ]]; then
    echo "$ip"
    return 0
  fi

  # For DHCP, try to get IP from /etc/hosts or arp
  local name
  name=$(pct config "$vmid" 2>/dev/null | grep "hostname:" | awk '{print $2}')

  if [[ -n "$name" ]]; then
    # Try mDNS
    ip=$(getent hosts "${name}.local" 2>/dev/null | awk '{print $1}' | head -1)
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi

    # Try /etc/hosts
    ip=$(grep -w "$name" /etc/hosts 2>/dev/null | awk '{print $1}' | head -1)
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
  fi

  return 1
}

# --- PORT SCANNING ---
scan_web_port() {
  local ip="$1"
  local ports_csv="${2:-$SCAN_PORTS}"

  IFS=',' read -ra ports <<< "$ports_csv"
  for port in "${ports[@]}"; do
    if nc -zw2 "$ip" "$port" 2>/dev/null; then
      echo "$port"
      return 0
    fi
  done
  return 1
}

# --- ICON LOOKUP ---
get_icon_url() {
  local hostname_lower
  hostname_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

  # Check manual overrides first
  if [[ -n "$ICON_OVERRIDES" ]]; then
    local override
    # shellcheck disable=SC2086
    for override in $ICON_OVERRIDES; do
      local o_name="${override%%:*}"
      local o_url="${override#*:}"
      if [[ "$hostname_lower" == "$o_name" ]]; then
        echo "$o_url"
        return 0
      fi
    done
  fi

  # Look up in service map
  local service_info
  if service_info=$(lookup_service "$hostname_lower"); then
    local selfhst_ref="${service_info%%:*}"
    echo "https://cdn.jsdelivr.net/gh/selfhst/icons@main/svg/${selfhst_ref}.svg"
    return 0
  fi

  # Fallback: use generic server icon from selfhst/icons CDN
  echo "https://cdn.jsdelivr.net/gh/selfhst/icons@main/svg/server.svg"
  return 0
}

get_port_override() {
  local hostname_lower
  hostname_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

  if [[ -n "$PORT_OVERRIDES" ]]; then
    local override
    # shellcheck disable=SC2086
    for override in $PORT_OVERRIDES; do
      local o_name="${override%%:*}"
      local o_port="${override#*:}"
      if [[ "$hostname_lower" == "$o_name" ]]; then
        echo "$o_port"
        return 0
      fi
    done
  fi
  return 1
}

# --- NORMALIZATION ---
normalize_url() {
  local url="$1"
  url="${url%%/}"          # remove trailing slash
  url="${url,,}"           # lowercase
  url="${url/%:80/}"       # remove :80 from http
  url="${url/%:443/}"      # remove :443 from https
  echo "$url"
}

# --- GATUS CONFIG GENERATION ---
# Build the top-level Gatus config (metrics + storage + alerting + endpoints header).
gatus_config_header() {
  local scan_interval="$1"

  cat <<EOF
metrics: true
storage:
  type: sqlite
  path: /opt/gatus/data.db
EOF

  if [[ "$GATUS_ALERTING" == "yes" ]]; then
    local alert_blocks=""
    if [[ -n "$TOKEN" && -n "$CHAT_ID" ]]; then
      alert_blocks+="  telegram:
    token: ${TOKEN}
    id: ${CHAT_ID}"
    fi
    if [[ -n "$GOTIFY_SERVER" && -n "$GOTIFY_TOKEN" ]]; then
      if [[ -n "$alert_blocks" ]]; then alert_blocks+=$'\n'; fi
      alert_blocks+="  gotify:
    server: ${GOTIFY_SERVER}
    token: ${GOTIFY_TOKEN}"
    fi
    if [[ -n "$alert_blocks" ]]; then
      printf 'alerting:\n%b\n' "$alert_blocks"
    fi
  fi

  echo "interval: ${scan_interval}"
  echo "endpoints: []"
}

# Build a single Gatus endpoint YAML block for one service.
# Global: output is the endpoint block (without surrounding indentation;
# caller indents it under `endpoints:`).
gatus_endpoint_yaml() {
  local name="$1"
  local protocol="$2"
  local ip="$3"
  local port="$4"
  local group="$5"

  # Gatus probes must use the raw IP, not the `.local` hostname: Gatus is a Go
  # binary whose resolver does not support mDNS/Bonjour, so it cannot resolve
  # `*.local` names and every probe would fail. `USE_LOCAL_DOMAINS` only affects
  # the browser-facing Homepage links below.
  local url="${protocol}://${ip}"
  [[ "$port" != "80" && "$port" != "443" ]] && url="${url}:${port}"

  local condition
  # Quote the condition: Gatus uses `[CONNECTED] == true` syntax, but the
  # leading `[` looks like a YAML flow sequence, so it must be quoted to
  # stay a valid YAML string for both HTTPS and HTTP checks.
  condition='"[CONNECTED] == true"'

  local alerts_block=""
  if [[ "$GATUS_ALERTING" == "yes" ]]; then
    if [[ -n "$TOKEN" && -n "$CHAT_ID" ]]; then
      alerts_block+="      - type: telegram"$'\n'
    fi
    if [[ -n "$GOTIFY_SERVER" && -n "$GOTIFY_TOKEN" ]]; then
      alerts_block+="      - type: gotify"$'\n'
    fi
  fi

  cat <<EOF
  - name: ${name}
    group: ${group:-default}
    url: ${url}
EOF
  # HTTPS endpoints (e.g. Portainer behind a self-signed cert) would fail TLS
  # validation by default; skip cert verification so the `[CONNECTED]` check
  # succeeds the way a browser tolerating the cert would.
  if [[ "$protocol" == "https" ]]; then
    cat <<EOF
    skipTLSVerify: true
EOF
  fi
  cat <<EOF
    interval: 60s
    conditions:
      - ${condition}
EOF
  if [[ -n "$alerts_block" ]]; then
    printf '    alerts:\n%b' "$alerts_block"
  fi
}

# --- HOMEPAGE CONFIG GENERATION ---
# Default icons for apps that have no SERVICE_MAP entry / dedicated selfhst
# slug. Values are full CDN URLs (selfhst / dashboard-icons / the app's repo).
declare -A CUSTOM_ICON_DEFAULTS=(
  ["omnitools"]="https://cdn.jsdelivr.net/gh/iib0011/omni-tools@main/src/assets/logo.png"
  ["yuvomi"]="https://cdn.jsdelivr.net/gh/selfhst/icons@main/webp/yuvomi.webp"
  ["convertx"]="https://cdn.jsdelivr.net/gh/selfhst/icons@main/webp/convertx.webp"
  ["proxmox-hive"]="https://cdn.jsdelivr.net/gh/macokay/proxmox-hive@main/client/public/hive.svg"
  ["proxmox"]="https://cdn.jsdelivr.net/gh/selfhst/icons@main/svg/proxmox.svg"
)

# On-demand icon lookup from community-scripts.org (mirrors the old flame
# community-scripts port lookup). Each per-app page embeds its official logo
# as the `rel="icon"` link pointing to a jsDelivr CDN URL; we extract that.
# Results are cached for 7 days in /tmp. Returns the CDN URL or nothing.
fetch_icon_from_community_scripts() {
  local service_name="$1"
  local cache_file="/tmp/.dashboard-cs-icon-${service_name}"

  if [[ -f "$cache_file" ]]; then
    local cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0) ))
    if [[ $cache_age -lt 604800 ]]; then
      cat "$cache_file"
      return 0
    fi
  fi

  local page
  page=$(curl -sL --connect-timeout 5 --max-time 10 "https://community-scripts.org/scripts/${service_name}" 2>/dev/null)
  local icon
  icon=$(echo "$page" | grep -oE 'rel="icon" href="https://cdn\.jsdelivr\.net/[^"]*"' | head -1 | sed 's/.*href="//; s/"$//')

  if [[ -n "$icon" && "$icon" == https://* ]]; then
    echo "$icon" > "$cache_file"
    echo "$icon"
    return 0
  fi
  return 1
}

homepage_icon() {
  local hostname_lower
  hostname_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

  # Check manual overrides first — a custom icon URL overrides the shorthand.
  if [[ -n "$ICON_OVERRIDES" ]]; then
    local override
    # shellcheck disable=SC2086
    for override in $ICON_OVERRIDES; do
      local o_name="${override%%:*}"
      if [[ "$hostname_lower" == "$o_name" ]]; then
        echo "${override#*:}"
        return 0
      fi
    done
  fi

  # Built-in defaults for known custom apps (before generic fallback).
  if [[ -n "${CUSTOM_ICON_DEFAULTS[$hostname_lower]+x}" ]]; then
    echo "${CUSTOM_ICON_DEFAULTS[$hostname_lower]}"
    return 0
  fi

  local service_info
  if service_info=$(lookup_service "$hostname_lower"); then
    local selfhst_ref="${service_info%%:*}"
    # selfh.st SVG filenames use dashes and lowercase (e.g. paperless-ngx),
    # so pass the slug through unchanged — no dash/underscore conversion.
    echo "sh-${selfhst_ref}"
    return 0
  fi

  # On-demand community-scripts icon lookup (cached), like the old flame port
  # lookup — gives an official logo for any community-scripts app.
  local cs_icon
  if cs_icon=$(fetch_icon_from_community_scripts "$hostname_lower" 2>/dev/null); then
    echo "$cs_icon"
    return 0
  fi

  # Generic fallback: selfhst CDN server icon (matches get_icon_url/flame
  # convention — never a local/favicon path).
  echo "https://cdn.jsdelivr.net/gh/selfhst/icons@main/svg/server.svg"
  return 0
}

# Human-facing host to show in Homepage links. With USE_LOCAL_DOMAINS=yes
# this is the avahi/mDNS hostname (name.local, matching the old Flame script);
# otherwise it falls back to the raw container IP.
link_host() {
  local name="$1"
  local ip="$2"
  if [[ "$USE_LOCAL_DOMAINS" == "yes" ]]; then
    printf '%s.local' "${name,,}"
  else
    printf '%s' "$ip"
  fi
}

# Build a Homepage services.yaml entry for a single service within a service
# group. Groups are emitted at column 0 (e.g. "- Media:"), so each service is
# indented 4 spaces and its properties 8 spaces (Homepage's required layout).
#
# The Homepage `gatus` widget shows Gatus-wide *aggregate* stats (up/down/
# uptime), so it's only attached to the `gatus` card — putting it on every
# card would show identical numbers everywhere.
homepage_service_yaml() {
  local name="$1"
  local protocol="$2"
  local ip="$3"
  local port="$4"
  local icon="$5"
  local gatus_url="$6"

  local host
  host=$(link_host "$name" "$ip")
  local href="${protocol}://${host}"
  [[ "$port" != "80" && "$port" != "443" ]] && href="${href}:${port}"

  # siteMonitor: Homepage makes a server-side HEAD request to show a live
  # up/down badge on the card. Uses the same host as href (name.local when
  # USE_LOCAL_DOMAINS=yes, matching how the browser reaches the service).
  local monitor="${protocol}://${host}"
  [[ "$port" != "80" && "$port" != "443" ]] && monitor="${monitor}:${port}"

  cat <<EOF
    - ${name}:
        href: ${href}
        icon: ${icon}
        description: Discovered from Proxmox LXC
        siteMonitor: ${monitor}
EOF
  if [[ "$name" == "gatus" ]]; then
    cat <<EOF
        widget:
          type: gatus
          url: ${gatus_url}
EOF
  fi
}

# --- HOMEPAGE MANUAL-SERVICE PRESERVATION ---

# Print service names (the `    - name:` lines) from a Homepage services.yaml.
extract_service_names() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -nE 's/^    - ([^:]+):.*/\1/p' "$file"
}

# Exit 0 if any `- Group:` header is repeated in a Homepage services.yaml. This
# catches files corrupted by older merge versions that emitted duplicate groups.
# Pure.
homepage_has_dup_groups() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk '
    /^[^ ]/ { g = $0; if (seen[g]) dup = 1; seen[g] = 1 }
    END { exit (dup ? 0 : 1) }
  ' "$file"
}

# Collapse duplicate `- Group:` headers in a Homepage services.yaml into a single
# header per group, consolidating every service block under the first occurrence
# of that group name. Output = one clean `- Group:` per group, in first-seen
# order, with all blocks (including from dropped duplicate headers) preserved
# verbatim. Only meaningful on files with duplicate headers; a clean file passes
# through unchanged apart from blank-line normalization.
# Args: file
# Stdout: deduplicated YAML.
dedup_homepage_groups() {
  awk '
    function header(line) { return (line ~ /^[^ ]/ && line != "") }
    {
      if (header($0)) {
        cur = $0
        if (!(cur in ord)) { order[++on] = cur; ord[cur] = 1 }
        next
      }
      if (cur != "" && $0 != "") {
        g[cur, ++n[cur]] = $0
      }
    }
    END {
      for (k = 1; k <= on; k++) {
        gname = order[k]
        if (k > 1) print ""
        print gname
        for (i = 1; i <= n[gname]; i++) print g[gname, i]
      }
    }
  ' "$1"
}

# --- HOMEPAGE MERGE (add new inside existing group; never rewrite existing) ---
# The generated Homepage config is merged against the currently deployed one
# before pushing, like Flame did: anything already present in the live file is
# left completely untouched, and only services this run discovered but that
# aren't in the live file yet are added. Each new service is inserted *inside*
# its group — if that group already exists in the deployed file the block is
# appended after that group's last service, otherwise a brand-new `- Group:`
# header is added at the end. This avoids emitting a repeated `- Group:`
# header (which previously produced duplicate categories that Homepage's
# same-name group merge rendered incorrectly). Manual edits stay preserved and
# unchanged files don't churn Homepage reloads.
#
# Args: generated_file existing_file  (existing_file may be empty/unset)
# Stdout: merged YAML.
merge_homepage_yaml() {
  local gen="$1"
  local existing="$2"

  # No existing config yet: use the generated file as-is.
  if [[ ! -f "$existing" ]]; then
    cat "$gen"
    return 0
  fi

  local existing_names
  existing_names=$(extract_service_names "$existing")
  local new_file="${TMPDIR:-/tmp}/home-new.$$"
  local spliced_file="${TMPDIR:-/tmp}/home-spliced.$$"
  local cleaned_file=""

  # Older merge versions could leave duplicate `- Group:` headers in the live
  # file. Repair that first so the splice/append logic below operates on a clean
  # structure (one header per group). Clean files pass through with no churn.
  local base="$existing"
  if homepage_has_dup_groups "$existing"; then
    cleaned_file="${TMPDIR:-/tmp}/home-cleaned.$$"
    dedup_homepage_groups "$existing" > "$cleaned_file"
    base="$cleaned_file"
  fi

  # Build new-records list: for each generated service whose name isn't already
  # deployed, emit the whole block as `group<TAB>line` records (group is the
  # generated group header). Used both for splicing into existing groups and
  # for appending brand-new groups at the end.
  EX_NAMES="$existing_names" awk '
    BEGIN { split(ENVIRON["EX_NAMES"], n, "\n"); for (i in n) if (n[i] != "") ex[n[i]] = 1 }
    /^[^ ]/ { group = $0; next }
    /^    - [^:]+:/ {
      name = $2; sub(/:$/, "", name)
      keep = !(name in ex)
      block = 1
      if (keep) print group "\t" $0
      next
    }
    {
      if (block && keep) print group "\t" $0
    }
  ' "$gen" > "$new_file"

  # Empty new list: the deployed file already has everything. Output verbatim.
  if [[ ! -s "$new_file" ]]; then
    inject_homepage_sitemonitor "$gen" "$base"
    rm -f "$new_file" "$cleaned_file" 2>/dev/null
    return 0
  fi

  # Splicing pass over the existing file. We emit it verbatim while recording new
  # records per group, then flush them at the end of each existing group and for
  # any brand-new group at EOF. Output is piped through inject_homepage_sitemonitor
  # so already-deployed entries that lack a siteMonitor get one added.
  NEW_FILE="$new_file" awk '
    function load_new() {
      if (loaded) return
      loaded = 1
      while ((getline rec < ENVIRON["NEW_FILE"]) > 0) {
        split(rec, parts, "\t")
        g = parts[1]
        line = substr(rec, length(parts[1]) + 2)  # strip the TAB and group prefix
        seen_new[g] = 1
        q[g, ++n[g]] = line
        order[++on] = g
      }
      close(ENVIRON["NEW_FILE"])
    }
    function flush_group() {
      if (cur != "" && n[cur] > 0) {
        for (i = 1; i <= n[cur]; i++) print q[cur, i]
        delete n[cur]
        printed[cur] = 1
      }
    }
    function is_header(line) {
      return (line ~ /^[^ ]/ && line != "")
    }
    load_new()
    {
      line = $0
      if (is_header(line)) {
        flush_group()
        cur = line
        present[cur] = 1
        gflush = 1
        print
        next
      } else {
        # not a header: just print (service line or property under current group)
        if (gflush) { gflush = 0 }
        print
        if (cur != "") tail[cur] = tail[cur] "\n" line
        next
      }
    }
    END {
      flush_group()
      # append any new service groups that are not present in the deployed file
      for (k = 1; k <= on; k++) {
        g = order[k]
        if (!(g in present) && n[g] > 0) {
          print ""
          print g
          for (i = 1; i <= n[g]; i++) print q[g, i]
          delete n[g]
        }
      }
    }
  ' "$base" > "$spliced_file"
  inject_homepage_sitemonitor "$gen" "$spliced_file"
  rm -f "$new_file" "$spliced_file" "$cleaned_file"
}

# Add a `siteMonitor:` line to any Homepage service block that lacks it.
# Args: generated_file merged_file  (merged = a Homepage services.yaml)
# Builds a name->siteMonitor map from the freshly generated file, then walks the
# merged file (which may be the untouched live config or the spliced output) and
# inserts `        siteMonitor: <value>` into every service block that doesn't
# already have one, right after its `description:` line. Existing siteMonitor
# lines (and every other manual edit: href/icon/widget/description) are left
# untouched. This is what back-fills the new field onto services that were
# deployed in earlier runs of the "only add new" merge.
inject_homepage_sitemonitor() {
  local gen="$1"
  local merged="$2"

  # Build name -> siteMonitor from the generated file.
  local map_file="${TMPDIR:-/tmp}/home-site.$$"
  GEN="$gen" awk '
    /^    - [^:]+:/ {
      name = $2; sub(/:$/, "", name)
      cur = name
      next
    }
    /^        siteMonitor: / {
      if (cur != "") { site[cur] = substr($0, index($0, ": ") + 2) }
    }
    END { for (n in site) print n "\t" site[n] }
  ' "$gen" > "$map_file"

  # Walk the merged file and inject where missing.
  MAP_FILE="$map_file" awk '
    function load_map() {
      if (loaded) return
      loaded = 1
      while ((getline kv < ENVIRON["MAP_FILE"]) > 0) {
        split(kv, p, "\t")
        site[p[1]] = p[2]
      }
      close(ENVIRON["MAP_FILE"])
    }
    {
      load_map()
      if (/^    - [^:]+:/) {
        name = $2; sub(/:$/, "", name)
        block = name
        emitted = 0
        has_site = 0
        print
        next
      } else if (/^        siteMonitor: /) {
        if (emitted) { next }   # already injected above description; drop the duplicate
        print
        has_site = 1
        next
      } else if (/^        description: /) {
        print
        if (block != "" && !has_site && !emitted && (block in site)) {
          print "        siteMonitor: " site[block]
          emitted = 1
        }
        next
      }
      print
    }
  ' "$merged"
  rm -f "$map_file"
}

# --- GATUS MERGE (add new; refresh IPs of known) ---
# Gatus config is overwritten each run too. Like the Homepage merge (and the
# old Flame tool), anything already in the live config is left untouched and
# only endpoint blocks this run discovered but that aren't deployed yet are
# added under the single `endpoints:` list.
#
# Additionally, for endpoints that ARE already deployed we still refresh the
# `url:` (and `group:`) line from this run's fresh scan. This keeps Gatus
# monitoring the current IP when a container's lease/address changes between
# cron runs — important because the script is intended to run on a schedule.
# Every other field (conditions, alerts, etc.) is preserved verbatim, so the
# merge never overwrites manual tuning. If the IP is unchanged the file is
# byte-identical (no reload churn).

# Print endpoint names (the `  - name:` lines) from a generated Gatus config.
extract_endpoint_names() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -nE 's/^  - name: *([^ ]+).*/\1/p' "$file"
}

# Build a "name -> url" map (newline-delimited `name\turl` lines) from a
# generated config; used to refresh the url of already-deployed endpoints.
# A URL may contain colons/space-adjacent chars, but never a tab.
extract_endpoint_urls() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    /^  - name: *([^ ]+)/ { name = $3 }
    /^    url: / && name != "" { print name "\t" $2; name = "" }
  ' "$file"
}

# Merge a generated Gatus config.yaml with the existing one. $2 may be
# empty/unset (no existing). Stdout: merged YAML.
#
#   - existing endpoints kept verbatim (header + all deployed checks)
#   - for known deployed endpoints, refresh only the `url:`/`group:` value
#     when this run discovered a different one
#   - newly-generated endpoint blocks (name not already deployed) spliced in
#     right under the `endpoints:` line
merge_gatus_yaml() {
  local gen="$1"
  local existing="$2"

  if [[ ! -f "$existing" ]]; then
    cat "$gen"
    return 0
  fi

  local existing_names new_blocks fresh_urls_file
  existing_names=$(extract_endpoint_names "$existing")
  fresh_urls_file="${TMPDIR:-/tmp}/gatus-fresh-urls.$$"
  extract_endpoint_urls "$gen" > "$fresh_urls_file"
  new_blocks="${TMPDIR:-/tmp}/gatus-new.$$"
  # New blocks = generated endpoint blocks whose name isn't deployed yet.
  EX_NAMES="$existing_names" awk '
    BEGIN {
      split(ENVIRON["EX_NAMES"], n, "\n")
      for (i in n) if (n[i] != "") ex[n[i]] = 1
    }
    /^  - name: / {
      name = $3
      block = (name in ex) ? 0 : 1
      if (block) print
      next
    }
    { if (block) print }
  ' "$gen" > "$new_blocks"

  # Existing config verbatim, splicing new blocks under `endpoints:` and
  # rewriting the `url:` of any deployed endpoint whose fresh scan differs.
  NEW_BLOCKS="$new_blocks" FRESH_URLS_FILE="$fresh_urls_file" awk '
    BEGIN { inserted = 0 }
    /^  - name: / {
      # load fresh url map lazily so any pre-endpoints header is untouched
      if (loaded == 0) {
        loaded = 1
        while ((getline line < ENVIRON["FRESH_URLS_FILE"]) > 0) {
          split(line, kv, "\t")
          fresh[kv[1]] = kv[2]
        }
        close(ENVIRON["FRESH_URLS_FILE"])
      }
      cur = $3
      print
      next
    }
    /^    url: / && cur != "" {
      if (cur in fresh) print "    url: " fresh[cur]
      else print
      cur = ""
      next
    }
    /^endpoints:/ {
      print
      if (!inserted) {
        while ((getline line < ENVIRON["NEW_BLOCKS"]) > 0) print line
        inserted = 1
      }
      next
    }
    { print }
  ' "$existing"

  rm -f "$new_blocks" "$fresh_urls_file"
}

# --- NOTIFICATION HELPERS ---
# Names that a generated file would add but that are not yet in the deployed
# file — i.e. services/endpoints actually discovered this run (mirrors Flame's
# "added" tracking so we can notify only on real changes).

# New service names (Homepage): names in gen not already in the deployed file.
new_service_names() {
  local gen="$1"
  local existing="$2"
comm -13 <(if [[ -n "$existing" && -f "$existing" ]]; then extract_service_names "$existing" | sort; fi) \
         <(extract_service_names "$gen" | sort)
}

# New endpoint names (Gatus): endpoints in gen not already deployed.
new_endpoint_names() {
  local gen="$1"
  local existing="$2"
comm -13 <(if [[ -n "$existing" && -f "$existing" ]]; then extract_endpoint_names "$existing" | sort; fi) \
         <(extract_endpoint_names "$gen" | sort)
}

# --- PCT PUSH ---
# Push a local file into the given LXC, creating parent dir and setting perms.
pct_push() {
  local vmid="$1"
  local local_file="$2"
  local remote_path="$3"
  local perms="${4:-0644}"

  local remote_dir="${remote_path%/*}"
  if ! pct exec "$vmid" -- mkdir -p "$remote_dir" &>/dev/null; then
    log ERROR "LXC ${vmid}: failed to create ${remote_dir}"
    return 1
  fi
  if ! pct push "$vmid" "$local_file" "$remote_path" &>/dev/null; then
    log ERROR "LXC ${vmid}: failed to push ${local_file} -> ${remote_path}"
    return 1
  fi
  pct exec "$vmid" -- chmod "$perms" "$remote_path" &>/dev/null
  return 0
}

# --- GATUS /etc/hosts SYNC ---
# Gatus is a static Go binary whose resolver does not implement mDNS, so
# `*.local` names won't resolve via avahi/NSS (confirmed on host). However Go's
# resolver DOES read /etc/hosts. So we write a hosts file into the Gatus LXC
# mapping each discovered `name.local` (and bare `name`) to its current IP each
# run. This lets Gatus resolve `.local` reliably and keeps the mapping fresh on
# cron (an IP change is reflected next run).
#
# Pushes the *whole* hosts file, preserving the standard 127.0.0.1 / ::1 lines
# plus our generated hostname->IP entries. Respects USE_LOCAL_DOMAINS; no-op
# when USE_LOCAL_DOMAINS!=yes.
write_gatus_hosts() {
  local vmid="$1"
  shift
  local -a services=("$@")

  [[ "$USE_LOCAL_DOMAINS" != "yes" ]] && return 0

  local hosts_file="${TMPDIR:-/tmp}/gatus-hosts.$$"
  {
    echo "127.0.0.1 localhost"
    echo "::1 localhost ip6-localhost ip6-loopback"
    local svc
    for svc in "${services[@]}"; do
      local sname sprotocol sip sport sgroup
      IFS='|' read -r sname sprotocol sip sport sgroup <<< "$svc"
      [[ -z "$sname" || -z "$sip" ]] && continue
      echo "${sip} ${sname} ${sname}.local"
    done
  } > "$hosts_file"

  if pct_push "$vmid" "$hosts_file" "/etc/hosts" "0644"; then
    log INFO "  Synced Gatus /etc/hosts (${#services[@]} host mappings)."
  else
    log ERROR "  Could not sync Gatus /etc/hosts."
    ((failed++)) || true
  fi
  rm -f "$hosts_file"
}

# --- KUMA (Uptime Kuma) MONITOR SYNC ---
# Uptime Kuma exposes NO official REST endpoint to create monitors (only its
# private Socket.IO API), so to auto-mirror discovered services we write monitor
# rows directly into Kuma's SQLite DB (KUMA_DB_PATH) from inside the Kuma LXC.
# Idempotent and mirrors Gatus "only add new + refresh url":
#   - a monitor whose name already exists -> UPDATE url/ignore_tls (keep all else)
#   - a monitor that doesn't exist         -> INSERT the row
# Because Kuma loads monitors into memory at startup / on Socket.IO events,
# the Kuma service is restarted after the write so it picks up the change.
#
# This touches the `monitor` and (when KUMA_STATUS_PAGE_SLUG is set) `group`/
# `monitor_group` tables, and backs the DB up first. It is considered fragile by
# Uptime-Kuma upstream ("not recommended"), so it is opt-in via KUMA_ENABLED=yes
# and guarded; column drift across Kuma versions is possible, and any sqlite3
# error is logged and skipped (Gatus keeps working).

# Emit the SQL to create/update one monitor row for a single service.
# Pure (testable). Args: create|update  name  protocol  ip  port
# The monitor url uses the local domain host when USE_LOCAL_DOMAINS=yes (Kuma
# resolves mDNS, unlike Gatus), else the raw IP.
kuma_monitor_sql() {
  local mode="$1"
  local name="$2"
  local protocol="$3"
  local ip="$4"
  local port="$5"

  local host
  host=$(link_host "$name" "$ip")
  local url="${protocol}://${host}"
  [[ "$port" != "80" && "$port" != "443" ]] && url="${url}:${port}"
  local ignore_tls=0
  [[ "$protocol" == "https" ]] && ignore_tls=1
  # escape single quotes inside the name/url for SQL
  name=${name//\'/''}
  url=${url//\'/''}

  if [[ "$mode" == "update" ]]; then
    printf "UPDATE monitor SET url='%s', ignore_tls=%s, active=1 WHERE name='%s';\n" \
      "$url" "$ignore_tls" "$name"
    return 0
  fi

  printf "INSERT INTO monitor \
(name, type, url, active, interval, retry_interval, maxretries, method, \
accepted_statuscodes_json, conditions, ignore_tls, upside_down, user_id, weight) \
VALUES ('%s', 'http', '%s', 1, %s, %s, 0, 'GET', '[\"200-299\"]', '[]', %s, 0, 1, 2000);\n" \
      "$name" "$url" "$KUMA_INTERVAL" "$KUMA_INTERVAL" "$ignore_tls"
}

# Emit the SQL to find the default group id of a status page (by slug), e.g. for
# the configured KUMA_STATUS_PAGE_SLUG. The default group is the first-created
# one (lowest id) belonging to that page; status pages always have at least one
# group, so new monitors can be attached to it to appear on the status page.
# Pure (testable). Args: slug
kuma_status_group_sql() {
  printf "SELECT g.id FROM \"group\" AS g JOIN status_page AS s ON s.id = g.status_page_id \
WHERE s.slug='%s' ORDER BY g.id ASC LIMIT 1;\n" "${1//\'/''}"
}

# Emit the SQL to link a monitor to a group (status page membership), unless it is
# already linked. `monitor_group` has no UNIQUE constraint on (monitor_id, group_id),
# so guard with NOT EXISTS to stay idempotent.
# Pure (testable). Args: monitor_id  group_id
kuma_link_sql() {
  local mid="$1"
  local gid="$2"
  printf "INSERT INTO monitor_group (monitor_id, group_id, weight, send_url) \
SELECT %s, %s, 1000, 0 \
WHERE NOT EXISTS (SELECT 1 FROM monitor_group WHERE monitor_id=%s AND group_id=%s);\n" \
    "$mid" "$gid" "$mid" "$gid"
}

# Write discovered services into Kuma's SQLite DB inside the Kuma LXC.
# Args: vmid  db_path  service... (name|proto|ip|port|group)
# No-op unless sqlite3 is available in the LXC; backs the DB up first. When
# KUMA_STATUS_PAGE_SLUG is set, each synced monitor is also linked to that status
# page's default group so it shows up on the page.
write_kuma_monitors() {
  local vmid="$1"
  local db_path="$2"
  shift 2
  local -a services=("$@")

  if [[ -z "$vmid" || -z "$db_path" ]]; then
    log WARN "  KUMA: no LXC/DB path configured; skipping Kuma sync."
    return 0
  fi

  # Auto-install sqlite3 in the LXC if missing (same approach as the old Flame
  # script's ensure_sqlite3_in_lxc), so a stock Kuma LXC works without manual
  # prep. Only the running status of the install is guarded — Gatus still works.
  if ! pct exec "$vmid" -- sh -c "command -v sqlite3 || which sqlite3 || test -x /usr/bin/sqlite3" &>/dev/null; then
    log INFO "  KUMA: sqlite3 not found in LXC ${vmid}, installing..."
    if ! pct exec "$vmid" -- bash -c "apt-get update -qq && apt-get install -y -qq sqlite3" &>/dev/null; then
      log WARN "  KUMA: failed to install sqlite3 in LXC ${vmid}; skipping Kuma sync."
      return 0
    fi
    log INFO "  KUMA: sqlite3 installed in LXC ${vmid}."
  fi

  # Backup the DB before any write.
  if ! pct exec "$vmid" -- cp "$db_path" "${db_path%.db}-backup.db" 2>/dev/null; then
    log WARN "  KUMA: could not back up ${db_path}; skipping Kuma sync."
    return 0
  fi

  # Existing monitor names in Kuma (for idempotency).
  local existing
  existing=$(pct exec "$vmid" -- sqlite3 "$db_path" "SELECT name FROM monitor;" 2>/dev/null)
  local -A exist=()
  local en
  while IFS= read -r en; do [[ -n "$en" ]] && exist["$en"]=1; done <<< "$existing"

  # Resolve the status-page group to link discovered monitors to (so they appear
  # on the configured status page). Optional; skipped when KUMA_STATUS_PAGE_SLUG
  # is empty or the page/group can't be found.
  local page_group_id=""
  if [[ -n "$KUMA_STATUS_PAGE_SLUG" ]]; then
    local pg_sql
    pg_sql=$(kuma_status_group_sql "$KUMA_STATUS_PAGE_SLUG")
    page_group_id=$(pct exec "$vmid" -- sqlite3 "$db_path" "$pg_sql" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$page_group_id" ]]; then
      log INFO "  Kuma status page '${KUMA_STATUS_PAGE_SLUG}': linking new monitors to group #${page_group_id}."
    else
      log WARN "  Kuma status page '${KUMA_STATUS_PAGE_SLUG}' not found; monitors will not be added to a status page."
    fi
  fi

  local added=0 updated=0 linked=0 failed=0
  local svc
  for svc in "${services[@]}"; do
    local sname sprotocol sip sport sgroup
    IFS='|' read -r sname sprotocol sip sport sgroup <<< "$svc"
    [[ -z "$sname" || -z "$sip" ]] && continue

    local sql
    if [[ -n "${exist[$sname]+x}" ]]; then
      sql=$(kuma_monitor_sql update "$sname" "$sprotocol" "$sip" "$sport")
      if pct exec "$vmid" -- sqlite3 "$db_path" "$sql" >/dev/null 2>&1; then
        ((updated++)) || true
      else
        ((failed++)) || true
      fi
    else
      sql=$(kuma_monitor_sql create "$sname" "$sprotocol" "$sip" "$sport")
      if pct exec "$vmid" -- sqlite3 "$db_path" "$sql" >/dev/null 2>&1; then
        ((added++)) || true
        exist[$sname]=1
      else
        ((failed++)) || true
      fi
    fi

    # Attach the monitor to the status page's default group (idempotent).
    if [[ -n "$page_group_id" ]]; then
      local mid sql_link
      mid=$(pct exec "$vmid" -- sqlite3 "$db_path" \
        "SELECT id FROM monitor WHERE name='${sname//\'/''}';" 2>/dev/null | tr -d '[:space:]')
      if [[ -n "$mid" ]]; then
        sql_link=$(kuma_link_sql "$mid" "$page_group_id")
        if pct exec "$vmid" -- sqlite3 "$db_path" "$sql_link" >/dev/null 2>&1; then
          ((linked++)) || true
        fi
      fi
    fi
  done

  # Restart Kuma so it reloads monitors into memory from the DB edit.
  if [[ "$KUMA_RESTART_SERVICE" == "yes" ]]; then
    pct exec "$vmid" -- systemctl restart uptime-kuma &>/dev/null \
      && log INFO "  Kuma restarted to reload monitors." \
      || log WARN "  Kuma: could not restart uptime-kuma (reload may be pending)."
  fi

  local link_note=""
  [[ -n "$page_group_id" ]] && link_note=" (${linked} linked to status page)"
  log INFO "  Kuma monitor sync: +${added} added, ~${updated} updated, ${failed} failed${link_note}."
}

# --- ARGUMENT PARSING ---
DRY_RUN=false
DO_DETECT=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --detect)
        DO_DETECT=true
        shift
        ;;
      --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Auto-detects running LXC containers and generates Gatus + Homepage config."
        echo "Runs directly on the Proxmox host using pct commands."
        echo ""
        echo "Options:"
        echo "  --dry-run    Show what would be written without pushing files"
        echo "  --detect     Re-detect the Gatus/Homepage LXC containers"
        echo "  --help       Show this help message"
        echo ""
        echo "Gatus and Homepage reload their config automatically on file change."
        exit 0
        ;;
      *)
        log ERROR "Unknown option: $1"
        exit 1
        ;;
    esac
  done
}

# --- LXC DETECTION ---
# Find a running LXC by name substring, optionally requiring an open port.
find_lxc_by_name() {
  local name_pattern="$1"
  local port="${2:-}"
  local found_vmid=""

  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local vmid status name
    vmid=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    name=$(echo "$line" | awk '{print $3}')

    if [[ "$status" != "running" ]]; then
      continue
    fi
    if [[ "${name,,}" == *"${name_pattern}"* ]]; then
      found_vmid="$vmid"
      break
    fi
  done < <(pct list 2>/dev/null | awk 'NR>1')

  if [[ -z "$found_vmid" && -n "$port" ]]; then
    # Fallback: scan for the port on running LXCs
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local vmid status name
      vmid=$(echo "$line" | awk '{print $1}')
      status=$(echo "$line" | awk '{print $2}')
      name=$(echo "$line" | awk '{print $3}')

      if [[ "$status" != "running" ]]; then
        continue
      fi
      local ip
      if ip=$(get_lxc_ip "$vmid"); then
        if nc -zw2 "$ip" "$port" 2>/dev/null; then
          found_vmid="$vmid"
          break
        fi
      fi
    done < <(pct list 2>/dev/null | awk 'NR>1')
  fi

  if [[ -z "$found_vmid" ]]; then
    log ERROR "Could not find a running LXC matching '${name_pattern}'."
    return 1
  fi

  echo "$found_vmid"
  return 0
}

# --- MAIN ---
main() {
  parse_args "$@"

  log INFO "Starting Dashboard Auto-Discover ${SCRIPT_VERSION} on ${HOSTNAME}..."

  # Pre-flight checks
  if [[ $EUID -ne 0 ]]; then
    log ERROR "This script must be run as root."
    exit 1
  fi

  if ! command -v pct &>/dev/null; then
    log ERROR "pct command not found — must run on a Proxmox host."
    exit 1
  fi

  # Resolve Gatus LXC
  if [[ -z "$GATUS_LXC_ID" || "$DO_DETECT" == "true" ]] && [[ "$GATUS_ENABLED" == "yes" ]]; then
    GATUS_LXC_ID=$(find_lxc_by_name "gatus" "8080") || exit 1
    log INFO "Gatus LXC: ${GATUS_LXC_ID}"
  elif [[ "$GATUS_ENABLED" == "yes" ]]; then
    log INFO "Using Gatus LXC: ${GATUS_LXC_ID}"
  fi

  # Resolve the Gatus base URL used by Homepage widgets. Gatus listens on
  # 0.0.0.0:${GATUS_PORT}, so the widget URL must include the port or the
  # Homepage widget hits port 80 and shows "Api Error".
  if [[ -z "$HOMEPAGE_GATUS_URL" ]] && [[ "$GATUS_ENABLED" == "yes" && -n "$GATUS_LXC_ID" ]]; then
    if [[ "$USE_LOCAL_DOMAINS" == "yes" ]]; then
      HOMEPAGE_GATUS_URL="http://gatus.local:${GATUS_PORT}"
      log INFO "Homepage Gatus URL: ${HOMEPAGE_GATUS_URL}"
    elif gatus_ip=$(get_lxc_ip "$GATUS_LXC_ID" 2>/dev/null); then
      HOMEPAGE_GATUS_URL="http://${gatus_ip}:${GATUS_PORT}"
      log INFO "Homepage Gatus URL: ${HOMEPAGE_GATUS_URL}"
    else
      HOMEPAGE_GATUS_URL="http://gatus.local:${GATUS_PORT}"
      log INFO "Homepage Gatus URL (fallback): ${HOMEPAGE_GATUS_URL}"
    fi
  elif [[ -z "$HOMEPAGE_GATUS_URL" ]]; then
    HOMEPAGE_GATUS_URL="http://gatus.local:${GATUS_PORT}"
  fi

  # Resolve Homepage LXC
  if [[ -z "$HOMEPAGE_LXC_ID" || "$DO_DETECT" == "true" ]] && [[ "$HOMEPAGE_ENABLED" == "yes" ]]; then
    HOMEPAGE_LXC_ID=$(find_lxc_by_name "homepage" "3000") || exit 1
    log INFO "Homepage LXC: ${HOMEPAGE_LXC_ID}"
  elif [[ "$HOMEPAGE_ENABLED" == "yes" ]]; then
    log INFO "Using Homepage LXC: ${HOMEPAGE_LXC_ID}"
  fi

  # Resolve Uptime Kuma LXC (trial backend). Optional; only used when enabled.
  if [[ -z "$KUMA_LXC_ID" || "$DO_DETECT" == "true" ]] && [[ "$KUMA_ENABLED" == "yes" ]]; then
    if KUMA_LXC_ID=$(find_lxc_by_name "kuma" "$KUMA_PORT" 2>/dev/null); then
      log INFO "Uptime Kuma LXC: ${KUMA_LXC_ID}"
    else
      log WARN "KUMA enabled but no Kuma LXC found; skipping Kuma sync."
      KUMA_LXC_ID=""
    fi
  elif [[ "$KUMA_ENABLED" == "yes" ]]; then
    log INFO "Using Uptime Kuma LXC: ${KUMA_LXC_ID}"
  fi

  # Get running LXC containers
  log INFO "Scanning for running LXC containers..."
  local lxc_lines
  mapfile -t lxc_lines < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"')

  if [[ ${#lxc_lines[@]} -eq 0 ]]; then
    log WARN "No running LXC containers found."
    send_notification "Dashboard Auto-Discover: No running LXC containers found on \`${HOSTNAME}\`."
    exit 0
  fi

  log INFO "Found ${#lxc_lines[@]} running LXC containers."

  # Discovery phase: collect name|protocol|ip|port for each web service.
  local -a services=()
  local -a names=()
  local added=0
  local skipped_no_port=0
  local failed=0
  local new_gatus_names=""
  local new_homepage_names=""

  for line in "${lxc_lines[@]}"; do
    [[ -z "$line" ]] && continue

    local vmid name
    vmid=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $3}')

    local name_lower
    name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')

    # Skip if in SKIP_APPS list
    if [[ ",${SKIP_APPS}," == *",${name_lower},"* ]]; then
      log INFO "Skipping LXC ${vmid} (${name}) — in SKIP_APPS list."
      continue
    fi

    log INFO "Processing LXC ${vmid} (${name})..."

    local ip
    if ! ip=$(get_lxc_ip "$vmid"); then
      log WARN "  Could not determine IP for ${name} — skipping."
      ((skipped_no_port++)) || true
      continue
    fi
    log INFO "  IP: ${ip}"

    local port=""
    port=$(get_port_override "$name_lower" 2>/dev/null)

    if [[ -z "$port" ]]; then
      local service_info
      if service_info=$(lookup_service "$name_lower"); then
        port="${service_info##*:}"
      fi
    fi

    if [[ -z "$port" ]]; then
      log INFO "  Scanning common ports..."
      port=$(scan_web_port "$ip" "$SCAN_PORTS" 2>/dev/null)
    fi

    if [[ -z "$port" ]]; then
      log INFO "  No web service detected on ${name} — skipping."
      ((skipped_no_port++)) || true
      continue
    fi

    log INFO "  Detected port: ${port}"

    local protocol="http"
    [[ "$port" == "443" || "$port" == "8443" || "$port" == "9443" ]] && protocol="https"

    local group=""
    group=$(get_service_group "$name_lower" 2>/dev/null) || group=""

    services+=("${name}|${protocol}|${ip}|${port}|${group}")
    names+=("$name")
    ((added++)) || true
  done

  log INFO "Discovered ${added} web services."

  # Add the Proxmox host itself as a managed service (it's not an LXC, so it
  # isn't found by the container scan above). PVE web UI runs on https:8006.
  if [[ -z "$PVE_HOST_IP" ]]; then
    PVE_HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [[ -n "$PVE_HOST_IP" ]]; then
    if [[ ",${SKIP_APPS}," != *",${PVE_HOST_NAME},"* ]]; then
      log INFO "Adding Proxmox host (${PVE_HOST_NAME}) at ${PVE_HOST_IP}:${PVE_HOST_PORT}"
      services+=("${PVE_HOST_NAME}|https|${PVE_HOST_IP}|${PVE_HOST_PORT}|infrastructure")
      names+=("$PVE_HOST_NAME")
      ((added++)) || true
    fi
  else
    log WARN "PVE_HOST_IP not set and could not be auto-detected; skipping Proxmox host service."
  fi

  local gatus_file=""
  local homepage_file=""

  # --- Write Gatus config ---
  if [[ "$GATUS_ENABLED" == "yes" ]]; then
    log INFO "Generating Gatus config..."
    gatus_file=$(mktemp /tmp/gatus.XXXXXX.yaml)

    gatus_config_header "$GATUS_SCAN_INTERVAL" > "$gatus_file"
    # Replace placeholder empty endpoints with real list
    sed -i 's/^endpoints: \[\]$/endpoints:/' "$gatus_file"
    for svc in "${services[@]}"; do
      IFS='|' read -r sname sprotocol sip sport sgroup <<< "$svc"
      gatus_endpoint_yaml "$sname" "$sprotocol" "$sip" "$sport" "$sgroup" >> "$gatus_file"
    done

    # Preserve manual-only endpoint blocks from the live config.
    local existing_gatus_yaml=""
    if [[ "$DRY_RUN" != "true" && -n "$GATUS_LXC_ID" ]]; then
      existing_gatus_yaml=$(mktemp /tmp/gatus-existing.XXXXXX.yaml)
      if ! pct exec "$GATUS_LXC_ID" -- cat "${GATUS_CONFIG_DIR}/config.yaml" 2>/dev/null > "$existing_gatus_yaml"; then
        rm -f "$existing_gatus_yaml"
        existing_gatus_yaml=""
      fi
    fi
    local gatus_merged_file="${TMPDIR:-/tmp}/gatus-final.$$.yaml"
    merge_gatus_yaml "$gatus_file" "$existing_gatus_yaml" > "$gatus_merged_file"

    new_gatus_names=""
    if [[ "$DRY_RUN" != "true" ]]; then
      new_gatus_names=$(new_endpoint_names "$gatus_file" "$existing_gatus_yaml")
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log INFO "  [DRY RUN] Would push Gatus config to LXC ${GATUS_LXC_ID}:${GATUS_CONFIG_DIR}/config.yaml"
    else
      if [[ -n "$GATUS_LXC_ID" ]]; then
        if pct_push "$GATUS_LXC_ID" "$gatus_merged_file" "${GATUS_CONFIG_DIR}/config.yaml"; then
          log INFO "  Pushed Gatus config."
          if [[ "$GATUS_RESTART_SERVICE" == "yes" ]]; then
            pct exec "$GATUS_LXC_ID" -- systemctl restart gatus &>/dev/null && log INFO "  Restarted Gatus service."
          fi
        else
          ((failed++)) || true
        fi
      else
        log ERROR "  GATUS_LXC_ID not set; cannot push Gatus config."
        ((failed++)) || true
      fi
    fi
    rm -f "$existing_gatus_yaml" "$gatus_file" "$gatus_merged_file"
  fi

  # --- Sync Gatus /etc/hosts so `*.local` resolves (Go reads hosts, not mDNS) ---
  if [[ "$GATUS_ENABLED" == "yes" && -n "$GATUS_LXC_ID" && "$DRY_RUN" != "true" ]]; then
    write_gatus_hosts "$GATUS_LXC_ID" "${services[@]}"
  elif [[ "$GATUS_ENABLED" == "yes" && "$DRY_RUN" == "true" && -n "$GATUS_LXC_ID" ]]; then
    log INFO "  [DRY RUN] Would sync Gatus /etc/hosts with ${#services[@]} host mappings."
  fi

  # --- Mirror discovered services into Uptime Kuma (trial backend) ---
  if [[ "$KUMA_ENABLED" == "yes" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      log INFO "  [DRY RUN] Would sync ${#services[@]} monitors into Kuma (LXC ${KUMA_LXC_ID:-?})."
    elif [[ -n "$KUMA_LXC_ID" ]]; then
      write_kuma_monitors "$KUMA_LXC_ID" "$KUMA_DB_PATH" "${services[@]}"
    else
      log WARN "  Kuma enabled but no Kuma LXC resolved; skipping Kuma sync."
    fi
  fi

  # --- Write Homepage config ---
  if [[ "$HOMEPAGE_ENABLED" == "yes" ]]; then
    log INFO "Generating Homepage config..."
    homepage_file=$(mktemp /tmp/homepage.XXXXXX.yaml)

    # Group services by category for Homepage sections.
    local -A sections=()
    local -a section_order=()
    for svc in "${services[@]}"; do
      IFS='|' read -r sname sprotocol sip sport sgroup <<< "$svc"
      local section="${sgroup:-other}"
      if [[ -z "${sections[$section]+x}" ]]; then
        sections[$section]=1
        section_order+=("$section")
      fi
    done

    for section in "${section_order[@]}"; do
      echo "- ${section}:" >> "$homepage_file"
      for svc in "${services[@]}"; do
        IFS='|' read -r sname sprotocol sip sport sgroup <<< "$svc"
        local this_section="${sgroup:-other}"
        if [[ "$this_section" != "$section" ]]; then
          continue
        fi
        local icon
        icon=$(homepage_icon "$sname")
        homepage_service_yaml "$sname" "$sprotocol" "$sip" "$sport" "$icon" "$HOMEPAGE_GATUS_URL" >> "$homepage_file"
      done
    done

    # Preserve manual-only service blocks from the live services.yaml
    # ("only add new", like the old Flame script). Fetch the current file when
    # possible (not dry-run and LXC known), else merge with nothing.
    local existing_homepage_yaml=""
    if [[ "$DRY_RUN" != "true" && -n "$HOMEPAGE_LXC_ID" ]]; then
      existing_homepage_yaml=$(mktemp /tmp/homepage-existing.XXXXXX.yaml)
      if ! pct exec "$HOMEPAGE_LXC_ID" -- cat "${HOMEPAGE_CONFIG_DIR}/${HOMEPAGE_SERVICES_FILE}" 2>/dev/null > "$existing_homepage_yaml"; then
        rm -f "$existing_homepage_yaml"
        existing_homepage_yaml=""
      fi
    fi

    local merged_file="${TMPDIR:-/tmp}/homepage-final.$$.yaml"
    merge_homepage_yaml "$homepage_file" "$existing_homepage_yaml" > "$merged_file"

    new_homepage_names=""
    if [[ "$DRY_RUN" != "true" ]]; then
      new_homepage_names=$(new_service_names "$homepage_file" "$existing_homepage_yaml")
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log INFO "  [DRY RUN] Would push Homepage config to LXC ${HOMEPAGE_LXC_ID}:${HOMEPAGE_CONFIG_DIR}/${HOMEPAGE_SERVICES_FILE}"
    else
      if [[ -n "$HOMEPAGE_LXC_ID" ]]; then
        if pct_push "$HOMEPAGE_LXC_ID" "$merged_file" "${HOMEPAGE_CONFIG_DIR}/${HOMEPAGE_SERVICES_FILE}"; then
          log INFO "  Pushed Homepage config."
        else
          ((failed++)) || true
        fi
      else
        log ERROR "  HOMEPAGE_LXC_ID not set; cannot push Homepage config."
      fi
    fi

    rm -f "$existing_homepage_yaml" "$homepage_file" "$merged_file"
  fi

  # Summary
  # "added" = services actually new this run (union of Gatus + Homepage new
  # names). Everything else we discovered was already deployed.
  local all_new
  all_new=$(printf '%s\n' "$new_gatus_names" "$new_homepage_names" | sort -u | grep -v '^$')
  local added_names=""
  local -A newset=()
  local n
  while IFS= read -r n; do [[ -n "$n" ]] && newset["$n"]=1; done <<< "$all_new"

  # Recompute "added" as only the services truly new this run (Flame semantics),
  # not the raw discovery count accumulated in the loop above.
  added=0
  local skipped_exists=0
  local skipped_names=""
  for own in "${names[@]}"; do
    if [[ -n "${newset[$own]+x}" ]]; then
      added_names+="${added_names:+, }${own}"
      ((added++)) || true
    else
      skipped_names+="${skipped_names:+, }${own}"
      ((skipped_exists++)) || true
    fi
  done

  log INFO "========================================"
  log INFO "Summary"
  log INFO "   Added:           $added"
  if [[ -n "$added_names" ]]; then
    log INFO "     - ${added_names}"
  fi
  log INFO "   Already known:   $skipped_exists"
  if [[ -n "$skipped_names" ]]; then
    log INFO "     - ${skipped_names}"
  fi
  log INFO "   No web service:  $skipped_no_port"
  log INFO "   Failed:          $failed"
  log INFO "========================================"

  # Notify only on real changes or failures (like Flame), never on an idle run.
  if [[ "$DRY_RUN" != "true" ]] && [[ "$added" -gt 0 || "$failed" -gt 0 ]]; then
    local REPORT="*Dashboard Auto-Discover: ${HOSTNAME}*"$'\n\n'
    REPORT+="Added: ${added}"$'\n'
    [[ -n "$added_names" ]] && REPORT+="${added_names}"$'\n'
    REPORT+="Already known: ${skipped_exists}"$'\n'
    [[ -n "$skipped_names" ]] && REPORT+="${skipped_names}"$'\n'
    REPORT+="No web service: ${skipped_no_port}"$'\n'
    REPORT+="Failed: ${failed}"
    log INFO "Sending notification..."
    send_notification "$REPORT"
  else
    log INFO "No changes — skipping notification."
  fi

  log INFO "Reloading note: Gatus checks its config every 30s and Homepage watches "
  log INFO "its YAML files, so new config is picked up automatically."
  log INFO "Done."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi