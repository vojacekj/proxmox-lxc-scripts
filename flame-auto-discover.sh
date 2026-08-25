#!/bin/bash
#
# Flame Auto-Discover for Proxmox LXC
#
# Automatically detects running LXC containers on the Proxmox host,
# determines which ones are web services, and adds them to your
# Flame dashboard with .local domains and official icons.
#
# Runs directly on the Proxmox host using pct commands.
# Uses sqlite3 to directly modify Flame's database — no auth needed.
#
# Icons sourced from selfhst/icons (https://github.com/selfhst/icons)
# Default ports sourced from community-scripts/ProxmoxVE
#
# Use this script at your own risk.

SCRIPT_VERSION="v2.1.0"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- LOGGING ---
LOG_STDOUT="${LOG_STDOUT:-yes}"

log() {
  local level="${1:-INFO}"
  shift
  local timestamp
  printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1
  local message="${timestamp} [${level}] $*"

  if [[ "${LOG_STDOUT}" == "yes" ]]; then
    echo "${message}" >&2
  fi

  if command -v logger &>/dev/null; then
    logger -t "flame-discover" -p "user.${level,,}" -- "$*" 2>/dev/null || true
  fi
}

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
CONF_FILE="${SCRIPT_DIR}/flame-auto-discover.conf"
FLAME_DB_PATH="/opt/flame/data/db.sqlite"

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
FLAME_LXC_ID=""
SCAN_PORTS="80,443,8080,8443,3000,5000,8096,8920,9090,8123,7878,8888,9000,9696,5678"
PORT_OVERRIDES=""
ICON_OVERRIDES=""

if [[ -f "$CONF_FILE" ]]; then
  secure_source "$CONF_FILE"
elif [[ -f "/etc/pve-flame-discover.conf" ]]; then
  secure_source "/etc/pve-flame-discover.conf"
  CONF_FILE="/etc/pve-flame-discover.conf"
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
  [[ -z "${TOKEN}" || -z "${CHAT_ID}" ]] && { log INFO "Telegram config missing, skipping notification."; return 0; }

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
  else
    log INFO "Telegram delivery successful."
  fi
}

send_gotify() {
  local message="$1"
  [[ -z "${GOTIFY_SERVER}" || -z "${GOTIFY_TOKEN}" ]] && { log INFO "Gotify config missing, skipping notification."; return 0; }

  local url="${GOTIFY_SERVER}/message?token=${GOTIFY_TOKEN}"
  local curl_flags=(-s --connect-timeout 10 --max-time 30)

  if [[ "$GOTIFY_SERVER" == https://* ]]; then
    curl_flags+=(--proto '=https' --tlsv1.2)
  fi

  local plain_message
  plain_message=$(echo "$message" | sed 's/\*//g')
  plain_message="${plain_message//\\/\\\\}"
  plain_message="${plain_message//\"/\\\"}"
  plain_message="${plain_message//$'\n'/\\n}"
  plain_message="${plain_message//$'\t'/\\t}"

  local RESPONSE
  RESPONSE=$(curl "${curl_flags[@]}" \
    -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"Flame Auto-Discover\", \"message\": \"${plain_message}\", \"priority\": 5}")

  if [[ $RESPONSE != *"id"* ]]; then
    log ERROR "Gotify Error: $RESPONSE"
  else
    log INFO "Gotify delivery successful."
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
  ["jellyfin"]="jellyfin:8096:media"
  ["plex"]="plex:32400:media"
  ["tautulli"]="tautulli:8181:media"
  ["overseerr"]="overseerr:5055:media"
  ["jellyseerr"]="overseerr:5055:media"
  ["emby"]="emby:8096:media"
  ["audiobookshelf"]="audiobookshelf:13378:media"

  # Arr Stack
  ["sonarr"]="sonarr:8989:arr-stack"
  ["radarr"]="radarr:7878:arr-stack"
  ["prowlarr"]="prowlarr:9696:arr-stack"
  ["lidarr"]="lidarr:8686:arr-stack"
  ["readarr"]="readarr:8787:arr-stack"
  ["bazarr"]="bazarr:6767:arr-stack"
  ["autobrr"]="autobrr:7474:arr-stack"

  # Downloads
  ["qbittorrent"]="qbittorrent:8080:downloads"
  ["transmission"]="transmission:9091:downloads"
  ["deluge"]="deluge:8112:downloads"
  ["nzbget"]="nzbget:6789:downloads"
  ["sabnzbd"]="sabnzbd:8080:downloads"

  # Infrastructure
  ["portainer"]="portainer:9443:infrastructure"
  ["traefik"]="traefik:8080:infrastructure"
  ["nginxproxymanager"]="nginx-proxy-manager:81:infrastructure"
  ["npm"]="nginx-proxy-manager:81:infrastructure"
  ["caddy"]="caddy:2019:infrastructure"
  ["haproxy"]="haproxy:8404:infrastructure"
  ["dockge"]="dockge:5001:infrastructure"

  # DNS
  ["pihole"]="pi-hole:80:dns"
  ["pi-hole"]="pi-hole:80:dns"
  ["adguard"]="adguard-home:80:dns"
  ["adguardhome"]="adguard-home:80:dns"
  ["blocky"]="blocky:4000:dns"

  # Monitoring
  ["grafana"]="grafana:3000:monitoring"
  ["prometheus"]="prometheus:9090:monitoring"
  ["netdata"]="netdata:19999:monitoring"
  ["uptimekuma"]="uptime-kuma:3001:monitoring"
  ["uptime-kuma"]="uptime-kuma:3001:monitoring"
  ["gatus"]="gatus:8080:monitoring"
  ["beszel"]="beszel:8090:monitoring"

  # Automation
  ["n8n"]="n8n:5678:automation"
  ["node-red"]="node-red:1880:automation"
  ["nodered"]="node-red:1880:automation"
  ["homeassistant"]="home-assistant:8123:automation"
  ["home-assistant"]="home-assistant:8123:automation"
  ["hass"]="home-assistant:8123:automation"
  ["esphome"]="esphome:6052:automation"
  ["zigbee2mqtt"]="zigbee2mqtt:8080:automation"
  ["frigate"]="frigate:5000:automation"
  ["mosquitto"]="mosquitto:1883:automation"
  ["mqtt"]="mqtt:1883:automation"

  # Cloud / Storage
  ["nextcloud"]="nextcloud:443:cloud"
  ["owncloud"]="owncloud:443:cloud"
  ["seafile"]="seafile:80:cloud"
  ["filebrowser"]="file-browser:8080:cloud"
  ["file-browser"]="file-browser:8080:cloud"
  ["minio"]="minio:9001:cloud"
  ["immich"]="immich:2283:cloud"
  ["paperless"]="paperless:8000:cloud"
  ["paperless-ngx"]="paperless-ngx:8000:cloud"

  # Git / Code
  ["gitea"]="gitea:3000:git"
  ["forgejo"]="forgejo:3000:git"
  ["gitlab"]="gitlab:443:git"
  ["code-server"]="code-server:8443:git"
  ["nexterm"]="nexterm:6989:git"

  # Auth
  ["vaultwarden"]="vaultwarden:8000:auth"
  ["bitwarden"]="vaultwarden:8000:auth"
  ["authentik"]="authentik:9000:auth"
  ["authelia"]="authelia:9091:auth"

  # Communication
  ["matrix"]="matrix:8008:communication"
  ["gotify"]="gotify:8080:communication"
  ["ntfy"]="ntfy:80:communication"
  ["gotosocial"]="gotosocial:8080:communication"
  ["lemmy"]="lemmy:8536:communication"
  ["friendica"]="friendica:80:communication"
  ["discourse"]="discourse:80:communication"
  ["ghost"]="ghost:2368:communication"

  # Documents
  ["bookstack"]="bookstack:80:documents"
  ["wikijs"]="wikijs:3000:documents"
  ["dokuwiki"]="dokuwiki:80:documents"
  ["outline"]="outline:3000:documents"
  ["mealie"]="mealie:9925:documents"
  ["karakeep"]="karakeep:3000:documents"
  ["hedgedoc"]="hedgedoc:3000:documents"
  ["drawio"]="draw-io:8080:documents"

  # Dashboards
  ["dashy"]="dashy:4000:dashboards"
  ["heimdall"]="heimdall:80:dashboards"
  ["homarr"]="homarr:7575:dashboards"
  ["homepage"]="homepage:3000:dashboards"
  ["organizr"]="organizr:80:dashboards"

  # Analytics
  ["plausible"]="plausible:8000:analytics"
  ["matomo"]="matomo:80:analytics"
  ["umami"]="umami:3000:analytics"

  # Databases
  ["adminer"]="adminer:8080:databases"
  ["phpmyadmin"]="phpmyadmin:80:databases"
  ["cloudbeaver"]="cloudbeaver:8978:databases"

  # Proxmox
  ["pve"]="proxmox:8006:proxmox"
  ["pve01"]="proxmox:8006:proxmox"
  ["pve02"]="proxmox:8006:proxmox"
  ["proxmox"]="proxmox:8006:proxmox"

  # Other
  ["changedetection"]="changedetection:5000:other"
  ["cdio"]="changedetection:5000:other"
  ["actualbudget"]="actual-budget:5006:other"
  ["actual"]="actual-budget:5006:other"
  ["duplicati"]="duplicati:8200:other"
  ["freshrss"]="freshrss:80:other"
  ["filerun"]="filerun:80:other"
  ["grocy"]="grocy:80:other"
  ["firefly"]="firefly-iii:8080:other"
  ["firefly-iii"]="firefly-iii:8080:other"
  ["akkoma"]="akkoma:8080:other"
  ["librespeed"]="librespeed:80:other"
)

# --- FLAME LXC DETECTION ---
detect_flame_lxc() {
  log INFO "Searching for Flame LXC container..."

  local candidates=()
  local candidate_names=()

  # Method 1: Search by container name
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local vmid status name
    vmid=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    name=$(echo "$line" | awk '{print $3}')

    if [[ "$status" != "running" ]]; then
      continue
    fi

    # Check if name contains "flame"
    if [[ "${name,,}" == *"flame"* ]]; then
      candidates+=("$vmid")
      candidate_names+=("$name")
    fi
  done < <(pct list 2>/dev/null | awk 'NR>1')

  # Method 2: If no name match, scan for port 5005
  if [[ ${#candidates[@]} -eq 0 ]]; then
    log INFO "No container named 'flame' found. Scanning for port 5005..."

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local vmid status name
      vmid=$(echo "$line" | awk '{print $1}')
      status=$(echo "$line" | awk '{print $2}')
      name=$(echo "$line" | awk '{print $3}')

      if [[ "$status" != "running" ]]; then
        continue
      fi

      # Get IP from container config and check port 5005
      local ip
      ip=$(pct config "$vmid" 2>/dev/null | grep -A1 "net0:" | grep "ip=" | grep -oP 'ip=\K[^,/]+' | head -1)
      if [[ -n "$ip" && "$ip" != "dhcp" ]]; then
        if nc -zw2 "$ip" 5005 2>/dev/null; then
          candidates+=("$vmid")
          candidate_names+=("$name (port 5005)")
          log INFO "Found candidate: LXC $vmid ($name) on port 5005"
        fi
      fi
    done < <(pct list 2>/dev/null | awk 'NR>1')
  fi

  # No candidates found
  if [[ ${#candidates[@]} -eq 0 ]]; then
    log ERROR "Could not find Flame LXC container."
    log ERROR "Please set FLAME_LXC_ID manually in ${CONF_FILE}"
    return 1
  fi

  # Single candidate - validate and confirm
  if [[ ${#candidates[@]} -eq 1 ]]; then
    local vmid="${candidates[0]}"
    local name="${candidate_names[0]}"

    if ! validate_flame_db "$vmid"; then
      log ERROR "LXC $vmid ($name) found but Flame database not valid."
      return 1
    fi

    log INFO "Found Flame at LXC $vmid ($name)"
    read -r -p "Use this Flame container? [Y/n] " confirm
    if [[ "${confirm,,}" == "n" ]]; then
      log ERROR "Aborted by user."
      return 1
    fi

    save_flame_lxc_id "$vmid"
    return 0
  fi

  # Multiple candidates - let user choose
  log INFO "Found multiple potential Flame containers:"
  for i in "${!candidates[@]}"; do
    echo "  $((i+1))) LXC ${candidates[$i]} - ${candidate_names[$i]}"
  done

  local choice
  read -r -p "Select container [1-${#candidates[@]}]: " choice

  if [[ -z "$choice" || "$choice" -lt 1 || "$choice" -gt "${#candidates[@]}" ]]; then
    log ERROR "Invalid selection."
    return 1
  fi

  local selected_idx=$((choice-1))
  local vmid="${candidates[$selected_idx]}"

  if ! validate_flame_db "$vmid"; then
    log ERROR "LXC $vmid has a valid name but Flame database not found."
    return 1
  fi

  save_flame_lxc_id "$vmid"
  return 0
}

ensure_sqlite3_in_lxc() {
  local vmid="$1"

  # Check if sqlite3 is already available
  if pct exec "$vmid" -- sh -c "command -v sqlite3 || which sqlite3 || test -x /usr/bin/sqlite3" &>/dev/null; then
    return 0
  fi

  log INFO "LXC $vmid: sqlite3 not found, installing..."
  if pct exec "$vmid" -- bash -c "apt-get update -qq && apt-get install -y -qq sqlite3" &>/dev/null; then
    log INFO "LXC $vmid: sqlite3 installed successfully."
    return 0
  fi

  log ERROR "LXC $vmid: Failed to install sqlite3."
  return 1
}

validate_flame_db() {
  local vmid="$1"

  if ! pct status "$vmid" &>/dev/null; then
    log ERROR "LXC $vmid does not exist."
    return 1
  fi

  if ! pct exec "$vmid" -- test -f "$FLAME_DB_PATH" 2>/dev/null; then
    log WARN "LXC $vmid: $FLAME_DB_PATH not found."
    return 1
  fi

  # Ensure sqlite3 is installed in the LXC
  if ! ensure_sqlite3_in_lxc "$vmid"; then
    return 1
  fi

  # Verify it's a valid SQLite database with apps table
  local table_check
  table_check=$(pct exec "$vmid" -- sqlite3 "$FLAME_DB_PATH" ".tables" 2>/dev/null)
  if [[ "$table_check" != *"apps"* ]]; then
    log WARN "LXC $vmid: Database exists but no 'apps' table found."
    return 1
  fi

  return 0
}

save_flame_lxc_id() {
  local vmid="$1"

  # Set in current session
  FLAME_LXC_ID="$vmid"

  if [[ -z "$CONF_FILE" ]]; then
    CONF_FILE="${SCRIPT_DIR}/flame-auto-discover.conf"
  fi

  if [[ -f "$CONF_FILE" ]]; then
    # Update existing config
    if grep -q "^FLAME_LXC_ID=" "$CONF_FILE" 2>/dev/null; then
      sed -i "s/^FLAME_LXC_ID=.*/FLAME_LXC_ID=\"${vmid}\"/" "$CONF_FILE"
    else
      echo "FLAME_LXC_ID=\"${vmid}\"" >> "$CONF_FILE"
    fi
  else
    # Create new config
    cat > "$CONF_FILE" << EOF
# Flame Auto-Discover Configuration
# Auto-generated on $(date)

# --- Flame LXC ---
FLAME_LXC_ID="${vmid}"

# --- Optional ---
SCAN_PORTS="80,443,8080,8443,3000,5000,8096,8920,9090,8123,7878,8888,9000,9696,5678"
PORT_OVERRIDES=""
ICON_OVERRIDES=""
EOF
    chmod 600 "$CONF_FILE"
  fi

  log INFO "Saved FLAME_LXC_ID=${vmid} to ${CONF_FILE}"
}

# --- SQLITE FUNCTIONS (via pct exec) ---
flame_get_existing_urls() {
  local response
  response=$(pct exec "$FLAME_LXC_ID" -- sqlite3 "$FLAME_DB_PATH" \
    "SELECT url FROM apps;" 2>/dev/null)
  echo "$response"
}

flame_get_existing_names() {
  local response
  response=$(pct exec "$FLAME_LXC_ID" -- sqlite3 "$FLAME_DB_PATH" \
    "SELECT name FROM apps;" 2>/dev/null)
  echo "$response"
}

# Normalize URL for comparison (lowercase, remove trailing slash, strip default ports)
normalize_url() {
  local url="$1"
  url="${url%%/}"          # remove trailing slash
  url="${url,,}"           # lowercase
  # Strip default ports
  url="${url/:80$/}"       # remove :80 from http
  url="${url/:443$/}"      # remove :443 from https
  echo "$url"
}

flame_url_exists() {
  local existing_urls="$1"
  local url="$2"

  local norm_url
  norm_url=$(normalize_url "$url")

  while IFS= read -r existing; do
    [[ -z "$existing" ]] && continue
    local norm_existing
    norm_existing=$(normalize_url "$existing")
    if [[ "$norm_existing" == "$norm_url" ]]; then
      return 0
    fi
  done <<< "$existing_urls"

  return 1
}

flame_name_exists() {
  local existing_names="$1"
  local name="$2"

  local name_lower="${name,,}"

  while IFS= read -r existing; do
    [[ -z "$existing" ]] && continue
    local existing_lower="${existing,,}"
    if [[ "$existing_lower" == "$name_lower" ]]; then
      return 0
    fi
  done <<< "$existing_names"

  return 1
}

# --- CATEGORY MANAGEMENT ---
flame_get_or_create_category() {
  local category_name="$1"

  # Escape single quotes for SQL
  local escaped_name="${category_name//\'/\'\'}"

  # Try to get existing category
  local sql="SELECT id FROM categories WHERE name='${escaped_name}';"
  local result
  result=$(pct exec "$FLAME_LXC_ID" -- sqlite3 "$FLAME_DB_PATH" "$sql" 2>/dev/null)

  if [[ -n "$result" ]]; then
    echo "$result"
    return 0
  fi

  # Create new category
  sql="INSERT INTO categories (name, createdAt, updatedAt) VALUES ('${escaped_name}', datetime('now'), datetime('now'));"
  result=$(pct exec "$FLAME_LXC_ID" -- sqlite3 "$FLAME_DB_PATH" "$sql" 2>&1)

  if [[ $? -ne 0 ]]; then
    log ERROR "Failed to create category '${category_name}': $result"
    return 1
  fi

  # Get the ID of the newly created category
  sql="SELECT id FROM categories WHERE name='${escaped_name}';"
  result=$(pct exec "$FLAME_LXC_ID" -- sqlite3 "$FLAME_DB_PATH" "$sql" 2>/dev/null)

  if [[ -n "$result" ]]; then
    echo "$result"
    return 0
  fi

  log ERROR "Failed to get category ID for '${category_name}'"
  return 1
}

# Initialize categories and cache their IDs
declare -A CATEGORY_IDS

init_categories() {
  local categories=("proxmox" "media" "arr-stack" "downloads" "infrastructure" "dns" "monitoring" "automation" "cloud" "git" "auth" "communication" "documents" "dashboards" "analytics" "databases" "other")

  log INFO "Initializing categories..."
  for cat in "${categories[@]}"; do
    local cat_id
    if cat_id=$(flame_get_or_create_category "$cat"); then
      CATEGORY_IDS["$cat"]="$cat_id"
      log INFO "  Category '${cat}' -> ID ${cat_id}"
    else
      log ERROR "  Failed to initialize category '${cat}'"
      return 1
    fi
  done

  return 0
}

flame_insert_app() {
  local name="$1"
  local url="$2"
  local icon="$3"
  local description="$4"
  local category="$5"

  # Escape single quotes for SQL
  name="${name//\'/\'\'}"
  url="${url//\'/\'\'}"
  icon="${icon//\'/\'\'}"
  description="${description//\'/\'\'}"

  # Get category ID (default to "other" if not specified or not found)
  local cat_id="${CATEGORY_IDS[$category]:-${CATEGORY_IDS[other]}}"

  local sql="INSERT INTO apps (name, url, icon, description, categoryId, isPinned, isPublic, createdAt, updatedAt) VALUES ('${name}', '${url}', '${icon}', '${description}', ${cat_id}, 1, 1, datetime('now'), datetime('now'));"

  local result
  result=$(pct exec "$FLAME_LXC_ID" -- sqlite3 "$FLAME_DB_PATH" "$sql" 2>&1)

  if [[ $? -ne 0 ]]; then
    log ERROR "Failed to insert '${name}': $result"
    return 1
  fi

  return 0
}

flame_restart() {
  log INFO "Restarting Flame service..."
  if pct exec "$FLAME_LXC_ID" -- systemctl restart flame 2>/dev/null; then
    log INFO "Flame restarted successfully."
    return 0
  else
    # Try alternative service names
    if pct exec "$FLAME_LXC_ID" -- systemctl restart flame.service 2>/dev/null; then
      log INFO "Flame restarted successfully."
      return 0
    fi
    log ERROR "Failed to restart Flame service."
    return 1
  fi
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

# --- SERVICE LOOKUP ---
lookup_service() {
  local hostname_lower
  hostname_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

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

# Fetch port from community-scripts GitHub repo on demand
# Usage: fetch_port_from_community_scripts "jellyfin"
# Returns: "selfhst_ref:port" or empty string
fetch_port_from_community_scripts() {
  local service_name="$1"
  local cache_file="/tmp/.flame-cs-cache-${service_name}"

  # Check cache (valid for 7 days)
  if [[ -f "$cache_file" ]]; then
    local cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0) ))
    if [[ $cache_age -lt 604800 ]]; then
      cat "$cache_file"
      return 0
    fi
  fi

  # Try to fetch the script from GitHub
  local script_url="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/${service_name}.sh"
  local script_content
  script_content=$(curl --proto '=https' --tlsv1.2 -sf --connect-timeout 5 --max-time 10 "$script_url" 2>/dev/null)

  if [[ -z "$script_content" ]]; then
    return 1
  fi

  # Extract port from output messages like: http://${IP}:8096 or https://${IP}:9443
  local port=""
  port=$(echo "$script_content" | grep -oP 'http://\$\{IP\}:\K[0-9]+' | head -1)
  if [[ -z "$port" ]]; then
    port=$(echo "$script_content" | grep -oP 'https://\$\{IP\}:\K[0-9]+' | head -1)
  fi

  if [[ -n "$port" ]]; then
    # Cache the result (selfhst_ref:port format)
    echo "${service_name}:${port}" > "$cache_file"
    echo "${service_name}:${port}"
    return 0
  fi

  return 1
}

get_icon_url() {
  local hostname_lower
  hostname_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

  # Check manual overrides first
  if [[ -n "$ICON_OVERRIDES" ]]; then
    local override
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
  # (local favicons don't work from inside Flame LXC)
  echo "https://cdn.jsdelivr.net/gh/selfhst/icons@main/svg/server.svg"
  return 0
}

get_port_override() {
  local hostname_lower
  hostname_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')

  if [[ -n "$PORT_OVERRIDES" ]]; then
    local override
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

# --- ARGUMENT PARSING ---
DRY_RUN=false
DO_RESTART=false
DO_DETECT=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --restart)
        DO_RESTART=true
        shift
        ;;
      --detect)
        DO_DETECT=true
        shift
        ;;
      --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Auto-detects running LXC containers and adds them to your Flame dashboard."
        echo "Runs directly on the Proxmox host using pct commands."
        echo ""
        echo "Options:"
        echo "  --dry-run    Show what would be added without making changes"
        echo "  --restart    Restart Flame after making changes"
        echo "  --detect     Re-detect Flame LXC container"
        echo "  --help       Show this help message"
        echo ""
        echo "First run will auto-detect your Flame LXC and save the ID to config."
        exit 0
        ;;
      *)
        log ERROR "Unknown option: $1"
        exit 1
        ;;
    esac
  done
}

# --- MAIN ---
main() {
  parse_args "$@"

  log INFO "Starting Flame Auto-Discover ${SCRIPT_VERSION} on ${HOSTNAME}..."

  # Pre-flight checks
  if [[ $EUID -ne 0 ]]; then
    log ERROR "This script must be run as root."
    exit 1
  fi

  if ! command -v pct &>/dev/null; then
    log ERROR "pct command not found — must run on a Proxmox host."
    exit 1
  fi

  if ! command -v sqlite3 &>/dev/null; then
    log ERROR "sqlite3 not found. Install with: apt install sqlite3"
    exit 1
  fi

  # Detect or validate Flame LXC
  if [[ -z "$FLAME_LXC_ID" || "$DO_DETECT" == "true" ]]; then
    detect_flame_lxc || exit 1
  else
    # Validate existing config
    log INFO "Using Flame LXC: ${FLAME_LXC_ID}"
    if ! validate_flame_db "$FLAME_LXC_ID"; then
      log ERROR "Configured Flame LXC (${FLAME_LXC_ID}) is not valid. Run with --detect to re-detect."
      exit 1
    fi
  fi

  # Initialize categories
  if ! init_categories; then
    log ERROR "Failed to initialize categories."
    exit 1
  fi

  # Get existing apps from Flame
  log INFO "Fetching existing Flame applications..."
  local existing_urls
  existing_urls=$(flame_get_existing_urls)
  if [[ -z "$existing_urls" ]]; then
    existing_urls=""
  fi

  local existing_names
  existing_names=$(flame_get_existing_names)
  if [[ -z "$existing_names" ]]; then
    existing_names=""
  fi

  # Get running LXC containers
  log INFO "Scanning for running LXC containers..."
  local lxc_lines
  mapfile -t lxc_lines < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"')

  if [[ ${#lxc_lines[@]} -eq 0 ]]; then
    log WARN "No running LXC containers found."
    send_notification "Flame Auto-Discover: No running LXC containers found on \`${HOSTNAME}\`."
    exit 0
  fi

  log INFO "Found ${#lxc_lines[@]} running LXC containers."

  # Counters
  local added=0
  local skipped_exists=0
  local skipped_no_port=0
  local skipped_flame=0
  local failed=0
  local added_names=""
  local skipped_names=""

  # Process each container
  for line in "${lxc_lines[@]}"; do
    [[ -z "$line" ]] && continue

    local vmid name
    vmid=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $3}')

    # Skip Flame itself
    if [[ "$vmid" == "$FLAME_LXC_ID" ]]; then
      log INFO "Skipping LXC ${vmid} (${name}) — this is Flame."
      ((skipped_flame++)) || true
      continue
    fi

    log INFO "Processing LXC ${vmid} (${name})..."

    # Get container IP
    local ip
    if ! ip=$(get_lxc_ip "$vmid"); then
      log WARN "  Could not determine IP for ${name} — skipping."
      ((skipped_no_port++)) || true
      continue
    fi
    log INFO "  IP: ${ip}"

    # Determine port
    local port=""
    local name_lower
    name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')

    # Check manual overrides first
    port=$(get_port_override "$name_lower" 2>/dev/null)
    local category="other"

    # Check service map
    if [[ -z "$port" ]]; then
      local service_info
      if service_info=$(lookup_service "$name_lower"); then
        IFS=':' read -r _ port category <<< "$service_info"
        category="${category:-other}"
      fi
    fi

    # Try community-scripts GitHub (on demand, cached 7 days)
    if [[ -z "$port" ]]; then
      log INFO "  Not in built-in map, checking community-scripts..."
      local cs_info
      if cs_info=$(fetch_port_from_community_scripts "$name_lower" 2>/dev/null); then
        port="${cs_info##*:}"
        log INFO "  Found in community-scripts: port ${port}"
      fi
    fi

    # Scan ports if still unknown
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

    # Determine URL and protocol
    local protocol="http"
    [[ "$port" == "443" || "$port" == "8443" ]] && protocol="https"

    local service_url="${protocol}://${name_lower}.local"
    [[ "$port" != "80" && "$port" != "443" ]] && service_url="${service_url}:${port}"

    # Get icon
    local icon_url
    icon_url=$(get_icon_url "$name_lower" "$port")
    log INFO "  Icon: ${icon_url}"

    # Check if already exists in Flame (by URL or name)
    if flame_url_exists "$existing_urls" "$service_url"; then
      log INFO "  Already in Flame (URL match) — skipping."
      ((skipped_exists++)) || true
      skipped_names+="${skipped_names:+, }${name}"
      continue
    fi

    if flame_name_exists "$existing_names" "$name"; then
      log INFO "  Already in Flame (name match) — skipping."
      ((skipped_exists++)) || true
      skipped_names+="${skipped_names:+, }${name}"
      continue
    fi

    # Add to Flame
    local description="Discovered from Proxmox LXC (${vmid})"

    if [[ "$DRY_RUN" == "true" ]]; then
      log INFO "  [DRY RUN] Would add: ${name} -> ${service_url} [${category}]"
      ((added++)) || true
      continue
    fi

    if flame_insert_app "$name" "$service_url" "$icon_url" "$description" "$category"; then
      log INFO "  Added '${name}' to Flame [${category}]."
      ((added++)) || true
      added_names+="${added_names:+, }${name}"
      # Update existing lists to prevent duplicates within same run
      existing_urls="${existing_urls}"$'\n'"${service_url}"
      existing_names="${existing_names}"$'\n'"${name}"
    else
      ((failed++)) || true
    fi

    # Small delay between operations
    sleep 0.2
  done

  # Summary
  log INFO "========================================"
  log INFO "Summary"
  log INFO "   Added:           $added"
  log INFO "   Already existed: $skipped_exists"
  log INFO "   No web service:  $skipped_no_port"
  log INFO "   Skipped (Flame): $skipped_flame"
  log INFO "   Failed:          $failed"
  log INFO "========================================"

  # Restart Flame if requested and changes were made
  if [[ "$DO_RESTART" == "true" && "$DRY_RUN" != "true" && $added -gt 0 ]]; then
    flame_restart
  fi

  # Send notification if there were changes or failures
  if (( added > 0 || failed > 0 )); then
    local REPORT="*Flame Auto-Discover: ${HOSTNAME}*"$'\n\n'
    REPORT+="Added: ${added}"$'\n'
    if [[ -n "$added_names" ]]; then
      REPORT+="${added_names}"$'\n'
    fi
    REPORT+="Already existed: ${skipped_exists}"$'\n'
    if [[ -n "$skipped_names" ]]; then
      REPORT+="${skipped_names}"$'\n'
    fi
    REPORT+="No web service: ${skipped_no_port}"$'\n'
    REPORT+="Failed: ${failed}"

    log INFO "Sending notification..."
    send_notification "$REPORT"
  else
    log INFO "No changes — skipping notification."
  fi

  log INFO "Done."
}

main "$@"
