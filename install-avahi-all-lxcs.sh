#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="v1.0.0"

# ─── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()    { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()     { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔${NC} $*"; }
warn()   { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*"; }
err()    { echo -e "${RED}[$(date '+%H:%M:%S')] ✖${NC} $*" >&2; }

# ─── Config loading ────────────────────────────────────────────────────────────
secure_source() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local perms
        perms=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null)
        if [[ "$perms" != "600" && "$perms" != "640" ]]; then
            warn "Insecure permissions ($perms) on $file — expected 600. Skipping."
            return 1
        fi
        # shellcheck source=/dev/null
        source "$file"
    fi
}

load_configs() {
    # Telegram
    unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID 2>/dev/null
    if [[ -f "${SCRIPT_DIR}/telegram.conf" ]]; then
        secure_source "${SCRIPT_DIR}/telegram.conf"
    elif [[ -f "/etc/pve-telegram.conf" ]]; then
        secure_source "/etc/pve-telegram.conf"
    fi

    # Gotify
    unset GOTIFY_SERVER GOTIFY_TOKEN 2>/dev/null
    if [[ -f "${SCRIPT_DIR}/gotify.conf" ]]; then
        secure_source "${SCRIPT_DIR}/gotify.conf"
    elif [[ -f "/etc/pve-gotify.conf" ]]; then
        secure_source "/etc/pve-gotify.conf"
    fi
}

# ─── Notification functions ────────────────────────────────────────────────────
send_telegram() {
    local message="$1"
    [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0

    curl -s --connect-timeout 10 --max-time 30 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="Markdown" \
        -d text="${message}" \
        >/dev/null 2>&1 || warn "Telegram notification failed"
}

send_gotify() {
    local message="$1"
    [[ -z "${GOTIFY_SERVER:-}" || -z "${GOTIFY_TOKEN:-}" ]] && return 0

    local url="${GOTIFY_SERVER}/message?token=${GOTIFY_TOKEN}"
    local curl_flags=(-s --connect-timeout 10 --max-time 30)

    if [[ "$GOTIFY_SERVER" == https://* ]]; then
        curl_flags+=(--proto '=https' --tlsv1.2)
    fi

    curl "${curl_flags[@]}" \
        -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"Proxmox LXC\", \"message\": \"${message}\", \"priority\": 5}" \
        >/dev/null 2>&1 || warn "Gotify notification failed"
}

send_notification() {
    local message="$1"
    send_telegram "$message"
    local plain_message
    plain_message=$(echo "$message" | sed 's/\*//g')
    send_gotify "$plain_message"
}

# ─── Main ──────────────────────────────────────────────────────────────────────
main() {
    load_configs

    echo -e "${CYAN}=========================================="
    echo " Avahi-daemon Installer for Proxmox LXCs"
    echo " ${VERSION}"
    echo -e "==========================================${NC}"
    echo ""

    if ! command -v pct &>/dev/null; then
        err "pct command not found — must run on a Proxmox host."
        exit 1
    fi

    mapfile -t lxc_ids < <(pct list | awk 'NR>1 {print $1}')

    if [[ ${#lxc_ids[@]} -eq 0 ]]; then
        warn "No LXC containers found."
        send_notification "⚠️ *Avahi Installer*\nNo LXC containers found on \$(hostname)."
        exit 0
    fi

    local installed=0 skipped_already=0 skipped_stopped=0 failed=0

    for ctid in "${lxc_ids[@]}"; do
        local name
        name=$(pct config "$ctid" 2>/dev/null | grep '^hostname:' | awk '{print $2}')
        local status
        status=$(pct status "$ctid" | awk '{print $2}')

        if [[ "$status" != "running" ]]; then
            printf "[%s] %-20s SKIP (stopped)\n" "$ctid" "$name"
            ((skipped_stopped++))
            continue
        fi

        if pct exec "$ctid" -- dpkg -l avahi-daemon &>/dev/null; then
            printf "[%s] %-20s already installed\n" "$ctid" "$name"
            ((skipped_already++))
            continue
        fi

        printf "[%s] %-20s installing avahi-daemon..." "$ctid" "$name"

        if pct exec "$ctid" -- bash -c "apt-get update -qq && apt-get install -y -qq avahi-daemon" &>/dev/null; then
            pct exec "$ctid" -- systemctl enable --now avahi-daemon &>/dev/null
            printf " done\n"
            ((installed++))
        else
            printf " FAILED\n"
            ((failed++))
        fi
    done

    echo ""
    echo -e "${CYAN}=========================================="
    echo " Summary"
    echo -e "==========================================${NC}"
    echo " Installed:         $installed"
    echo " Already present:   $skipped_already"
    echo " Skipped (stopped): $skipped_stopped"
    echo " Failed:            $failed"
    echo -e "${CYAN}==========================================${NC}"

    local host
    host=$(hostname 2>/dev/null || echo "unknown")

    send_notification "✅ *Avahi Installer Complete*
 Host: \`${host}\`
 Installed: \`${installed}\`
 Already present: \`${skipped_already}\`
 Skipped (stopped): \`${skipped_stopped}\`
 Failed: \`${failed}\`"
}

main "$@"
