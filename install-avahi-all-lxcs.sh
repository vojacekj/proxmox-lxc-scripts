#!/bin/bash
#
# Proxmox LXC Avahi-daemon Installer
#
# Checks all LXC containers for avahi-daemon and installs it if missing.
# Sends a summary notification via Telegram and/or Gotify.
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
  local message="${timestamp} [${level}] $*"

  if [[ "${LOG_STDOUT}" == "yes" ]]; then
    echo "${message}" >&2
  fi

  if command -v logger &>/dev/null; then
    logger -t "avahi-installer" -p "user.${level,,}" -- "$*" 2>/dev/null || true
  fi
}

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME=$(hostname -f 2>/dev/null || hostname)

secure_source() {
  local conf_file="$1"
  if [[ ! -f "$conf_file" ]]; then return 0; fi
  if [[ -h "$conf_file" ]]; then
    log ERROR "❌ SECURITY CRITICAL: $conf_file is a symlink. Refusing to load."
    return 1
  fi

  local stat_out perms owner
  stat_out=$(stat -c "%a %U" "$conf_file" 2>/dev/null || echo "777 root")
  perms="${stat_out%% *}"
  owner="${stat_out#* }"

  if [[ "$perms" != "600" ]] || [[ "$owner" != "root" ]]; then
    log ERROR "❌ SECURITY CRITICAL: Config file $conf_file has insecure permissions/ownership ($perms $owner). Refusing to load."
    return 1
  fi
  source "$conf_file"
}

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
  [[ -z "${TOKEN}" || -z "${CHAT_ID}" ]] && { log INFO "⏭️ Telegram config missing, skipping notification."; return 0; }

  local URL="https://api.telegram.org/bot${TOKEN}/sendMessage"

  local RESPONSE
  RESPONSE=$(curl --proto '=https' --tlsv1.2 -s --connect-timeout 10 --max-time 30 -X POST -K <(cat <<CURL_CONF
url = "$URL"
data-urlencode = "chat_id=$CHAT_ID"
data-urlencode = "parse_mode=Markdown"
CURL_CONF
) --data-urlencode "text@-" <<< "$message")

  if [[ $RESPONSE != *'"ok":true'* ]]; then
    log ERROR "❌ Telegram Error: $RESPONSE"
  else
    log INFO "✅ Telegram delivery successful."
  fi
}

send_gotify() {
  local message="$1"
  [[ -z "${GOTIFY_SERVER}" || -z "${GOTIFY_TOKEN}" ]] && { log INFO "⏭️ Gotify config missing, skipping notification."; return 0; }

  local url="${GOTIFY_SERVER}/message?token=${GOTIFY_TOKEN}"
  local curl_flags=(-s --connect-timeout 10 --max-time 30)

  if [[ "$GOTIFY_SERVER" == https://* ]]; then
    curl_flags+=(--proto '=https' --tlsv1.2)
  fi

  local plain_message
  plain_message=$(echo "$message" | sed 's/\*//g')

  local RESPONSE
  RESPONSE=$(curl "${curl_flags[@]}" \
    -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"Proxmox Avahi Installer\", \"message\": \"${plain_message}\", \"priority\": 5}")

  if [[ $RESPONSE != *"id"* ]]; then
    log ERROR "❌ Gotify Error: $RESPONSE"
  else
    log INFO "✅ Gotify delivery successful."
  fi
}

send_notification() {
  local message="$1"
  send_telegram "$message"
  send_gotify "$message"
}

# --- PRE-FLIGHT ---
if [[ $EUID -ne 0 ]]; then
  log ERROR "❌ Error: This script must be run as root."
  exit 1
fi

if ! command -v pct &>/dev/null; then
  log ERROR "❌ pct command not found — must run on a Proxmox host."
  exit 1
fi

# --- MAIN ---
log INFO "ℹ️ Starting avahi-daemon check on $HOSTNAME..."

REPORT="*📦 Avahi-daemon Installer: $HOSTNAME*"$'\n\n'

# Get all LXCs with name and status
mapfile -t lxc_lines < <(pct list | awk 'NR>1 {print $1 ":" $2 ":" $NF}')

if [[ ${#lxc_lines[@]} -eq 0 ]]; then
  log WARN "⚠️ No LXC containers found."
  send_notification "⚠️ *Avahi Installer*\nNo LXC containers found on \`${HOSTNAME}\`."
  exit 0
fi

installed=0
skipped_already=0
skipped_stopped=0
skipped_no_apt=0
failed=0

for line in "${lxc_lines[@]}"; do
  [[ -z "$line" ]] && continue
  CTID="${line%%:*}"
  rest="${line#*:}"
  STATUS="${rest%%:*}"
  CTNAME="${rest##*:}"

  # Escape Markdown for Telegram
  CTNAME="${CTNAME//_/\\_}"
  CTNAME="${CTNAME//\*/\\*}"
  CTNAME="${CTNAME//\[/\\[}"
  CTNAME="${CTNAME//\]/\\]}"
  CTNAME="${CTNAME//\`/\\\`}"

  if [[ "$STATUS" != "running" ]]; then
    log INFO "⏭️ ID $CTID ($CTNAME): Stopped — skipping"
    REPORT+="• ID $CTID ($CTNAME): ⏭️ Stopped — skipped"$'\n'
    ((skipped_stopped++)) || true
    continue
  fi

  log INFO "ℹ️ Checking LXC $CTID ($CTNAME)..."

  # Check if apt-get is available in this container
  if ! timeout 30 pct exec "$CTID" -- bash -c 'command -v apt-get' &>/dev/null; then
    log INFO "⏭️ ID $CTID ($CTNAME): No apt-get found"
    REPORT+="• ID $CTID ($CTNAME): ⏭️ No apt-get found"$'\n'
    ((skipped_no_apt++)) || true
    continue
  fi

  # Check if avahi-daemon is installed (timeout prevents hung processes)
  if timeout 30 pct exec "$CTID" -- dpkg -l avahi-daemon &>/dev/null; then
    log INFO "✅ ID $CTID ($CTNAME): avahi-daemon already installed"
    REPORT+="• ID $CTID ($CTNAME): ✅ Already installed"$'\n'
    ((skipped_already++)) || true
    continue
  fi

  # Install avahi-daemon
  log INFO "⏳ ID $CTID ($CTNAME): Installing avahi-daemon..."
  if timeout 120 pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get install -y -qq avahi-daemon" &>/dev/null; then
    timeout 30 pct exec "$CTID" -- systemctl enable --now avahi-daemon &>/dev/null
    log INFO "✅ ID $CTID ($CTNAME): avahi-daemon installed and started"
    REPORT+="• ID $CTID ($CTNAME): ✅ Installed"$'\n'
    ((installed++)) || true
  else
    log ERROR "❌ ID $CTID ($CTNAME): Failed to install avahi-daemon"
    REPORT+="• ID $CTID ($CTNAME): ❌ Failed to install"$'\n'
    ((failed++)) || true
  fi
done

REPORT+=$'\n'"*📊 Summary:*"$'\n'
REPORT+="• Installed: \`${installed}\`"$'\n'
REPORT+="• Already present: \`${skipped_already}\`"$'\n'
REPORT+="• Skipped (stopped): \`${skipped_stopped}\`"$'\n'
REPORT+="• Skipped (no apt): \`${skipped_no_apt}\`"$'\n'
REPORT+="• Failed: \`${failed}\`"

log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log INFO "📊 Summary"
log INFO "   Installed:         $installed"
log INFO "   Already present:   $skipped_already"
log INFO "   Skipped (stopped): $skipped_stopped"
log INFO "   Skipped (no apt):  $skipped_no_apt"
log INFO "   Failed:            $failed"
log INFO "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

log INFO "ℹ️ Sending report..."
send_notification "$REPORT"

log INFO "✅ Done."
