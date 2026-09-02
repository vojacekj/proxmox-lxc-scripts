#!/usr/bin/env bats
# tests/test_gatus_config.bats — tests for gatus_config_header() and gatus_endpoint_yaml()

load test_helper

# --- gatus_config_header ---

@test "gatus_config_header: emits metrics true" {
  run gatus_config_header "60"
  [ "$status" -eq 0 ]
  [[ "$output" == *"metrics: true"* ]]
}

@test "gatus_config_header: emits sqlite storage" {
  run gatus_config_header "60"
  [[ "$output" == *"storage:"* ]]
  [[ "$output" == *"type: sqlite"* ]]
}

@test "gatus_config_header: emits interval from arg" {
  run gatus_config_header "30"
  [[ "$output" == *"interval: 30"* ]]
}

@test "gatus_config_header: no alerting block when empty creds" {
  export GATUS_ALERTING="yes"
  export TOKEN=""
  export CHAT_ID=""
  export GOTIFY_SERVER=""
  export GOTIFY_TOKEN=""
  run gatus_config_header "60"
  [[ "$output" != *"alerting:"* ]]
}

@test "gatus_config_header: telegram alerting with creds" {
  export GATUS_ALERTING="yes"
  export TOKEN="abc123"
  export CHAT_ID="chat1"
  export GOTIFY_SERVER=""
  export GOTIFY_TOKEN=""
  run gatus_config_header "60"
  [[ "$output" == *"alerting:"* ]]
  [[ "$output" == *"telegram:"* ]]
  [[ "$output" == *"token: abc123"* ]]
  [[ "$output" == *"id: chat1"* ]]
}

@test "gatus_config_header: gotify alerting with creds" {
  export GATUS_ALERTING="yes"
  export TOKEN=""
  export CHAT_ID=""
  export GOTIFY_SERVER="http://gotify.local"
  export GOTIFY_TOKEN="tok"
  run gatus_config_header "60"
  [[ "$output" == *"alerting:"* ]]
  [[ "$output" == *"gotify:"* ]]
  [[ "$output" == *"server: http://gotify.local"* ]]
  [[ "$output" == *"token: tok"* ]]
}

@test "gatus_config_header: both telegram and gotify alerting" {
  export GATUS_ALERTING="yes"
  export TOKEN="abc123"
  export CHAT_ID="chat1"
  export GOTIFY_SERVER="http://gotify.local"
  export GOTIFY_TOKEN="tok"
  run gatus_config_header "60"
  [[ "$output" == *"telegram:"* ]]
  [[ "$output" == *"gotify:"* ]]
}

@test "gatus_config_header: no alerting when disabled" {
  export GATUS_ALERTING="no"
  export TOKEN="abc123"
  export CHAT_ID="chat1"
  run gatus_config_header "60"
  [[ "$output" != *"alerting:"* ]]
}

@test "gatus_config_header: emits endpoints placeholder" {
  run gatus_config_header "60"
  [[ "$output" == *"endpoints:"* ]]
}

# --- gatus_endpoint_yaml ---

@test "gatus_endpoint_yaml: emits name, group, url" {
  run gatus_endpoint_yaml "jellyfin" "http" "10.0.0.5" "8096" "media"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: jellyfin"* ]]
  [[ "$output" == *"group: media"* ]]
  [[ "$output" == *"url: http://10.0.0.5:8096"* ]]
}

@test "gatus_endpoint_yaml: default group when empty" {
  run gatus_endpoint_yaml "unknown" "http" "10.0.0.9" "8080" ""
  [[ "$output" == *"group: default"* ]]
}

@test "gatus_endpoint_yaml: http condition CONNECTED quoted for valid yaml" {
  export GATUS_ALERTING="no"; export TOKEN=""; export CHAT_ID=""; export GOTIFY_SERVER=""; export GOTIFY_TOKEN=""
  local quoted='"[CONNECTED] == true"'
  run gatus_endpoint_yaml "jellyfin" "http" "10.0.0.5" "8096" "media"
  [[ "$output" == *"${quoted}"* ]]
}

@test "gatus_endpoint_yaml: omits default port 80" {
  run gatus_endpoint_yaml "pihole" "http" "10.0.0.6" "80" "dns"
  [[ "$output" == *"url: http://10.0.0.6"* ]]
  [[ "$output" != *":80"* ]]
}

@test "gatus_endpoint_yaml: omits default port 443" {
  run gatus_endpoint_yaml "nextcloud" "https" "10.0.0.7" "443" "cloud"
  [[ "$output" == *"url: https://10.0.0.7"* ]]
  [[ "$output" != *":443"* ]]
}

@test "gatus_endpoint_yaml: client.insecure on https endpoint" {
  run gatus_endpoint_yaml "portainer" "https" "10.0.0.8" "9443" "infrastructure"
  [[ "$output" == *"client:"* ]]
  [[ "$output" == *"insecure: true"* ]]
  [[ "$output" != *"skipTLSVerify"* ]]
}

@test "gatus_endpoint_yaml: no client.insecure on http endpoint" {
  run gatus_endpoint_yaml "jellyfin" "http" "10.0.0.5" "8096" "media"
  [[ "$output" != *"client:"* ]]
  [[ "$output" != *"insecure"* ]]
}

@test "gatus_endpoint_yaml: no alerts block when no creds and alerting disabled" {
  export GATUS_ALERTING="no"
  export TOKEN=""
  export CHAT_ID=""
  export GOTIFY_SERVER=""
  export GOTIFY_TOKEN=""
  run gatus_endpoint_yaml "jellyfin" "http" "10.0.0.5" "8096" "media"
  [[ "$output" != *"alerts:"* ]]
}

@test "gatus_endpoint_yaml: no alerts block when no creds configured" {
  export GATUS_ALERTING="yes"
  export TOKEN=""
  export CHAT_ID=""
  export GOTIFY_SERVER=""
  export GOTIFY_TOKEN=""
  run gatus_endpoint_yaml "jellyfin" "http" "10.0.0.5" "8096" "media"
  [[ "$output" != *"alerts:"* ]]
}

@test "gatus_endpoint_yaml: emits telegram alert with telegram creds" {
  export GATUS_ALERTING="yes"
  export TOKEN="abc123"
  export CHAT_ID="chat1"
  export GOTIFY_SERVER=""
  export GOTIFY_TOKEN=""
  run gatus_endpoint_yaml "jellyfin" "http" "10.0.0.5" "8096" "media"
  [[ "$output" == *"alerts:"* ]]
  [[ "$output" == *"type: telegram"* ]]
  [[ "$output" != *"type: gotify"* ]]
}

@test "gatus_endpoint_yaml: emits gotify alert with gotify creds" {
  export GATUS_ALERTING="yes"
  export TOKEN=""
  export CHAT_ID=""
  export GOTIFY_SERVER="http://gotify.local"
  export GOTIFY_TOKEN="tok"
  run gatus_endpoint_yaml "jellyfin" "http" "10.0.0.5" "8096" "media"
  [[ "$output" == *"alerts:"* ]]
  [[ "$output" == *"type: gotify"* ]]
  [[ "$output" != *"type: telegram"* ]]
}

@test "gatus_endpoint_yaml: emits both alerts with both creds" {
  export GATUS_ALERTING="yes"
  export TOKEN="abc123"
  export CHAT_ID="chat1"
  export GOTIFY_SERVER="http://gotify.local"
  export GOTIFY_TOKEN="tok"
  run gatus_endpoint_yaml "jellyfin" "http" "10.0.0.5" "8096" "media"
  [[ "$output" == *"type: telegram"* ]]
  [[ "$output" == *"type: gotify"* ]]
}

# --- kuma_monitor_url ---

@test "kuma_monitor_url: local domain host when USE_LOCAL_DOMAINS=yes" {
  export USE_LOCAL_DOMAINS="yes"
  run kuma_monitor_url "proxmox" "https" "192.168.1.238" "8006"
  [[ "$output" == "https://proxmox.local:8006" ]]
}

@test "kuma_monitor_url: real_host overrides display name for .local" {
  export USE_LOCAL_DOMAINS="yes"
  run kuma_monitor_url "proxmox" "https" "192.168.1.238" "8006" "pve01"
  [[ "$output" == "https://pve01.local:8006" ]]
}

@test "kuma_monitor_url: raw ip when USE_LOCAL_DOMAINS=no" {
  export USE_LOCAL_DOMAINS="no"
  run kuma_monitor_url "proxmox" "https" "192.168.1.238" "8006"
  [[ "$output" == "https://192.168.1.238:8006" ]]
}

@test "kuma_monitor_url: omits default port 80/443" {
  export USE_LOCAL_DOMAINS="yes"
  run kuma_monitor_url "adguard" "http" "10.0.0.9" "80"
  [[ "$output" == "http://adguard.local" ]]
}

# --- kuma_monitor_sql ---

@test "kuma_monitor_sql: create inserts row with interval/baseline fields" {
  export KUMA_INTERVAL="60"
  export USE_LOCAL_DOMAINS="yes"
  run kuma_monitor_sql create "jellyfin" "http" "10.0.0.5" "8096"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSERT INTO monitor"* ]]
  [[ "$output" == *"'jellyfin'"* ]]
  [[ "$output" == *"'http://jellyfin.local:8096'"* ]]
  [[ "$output" == *", 60, 60,"* ]]              # interval + retry_interval
  [[ "$output" == *"'[]'"* ]]                  # conditions (NOT NULL)
  [[ "$output" == *"ignore_tls"* ]]
  [[ "$output" == *"WHERE NOT EXISTS (SELECT 1 FROM monitor WHERE name='jellyfin')"* ]]
}

@test "kuma_monitor_sql: uses raw IP when USE_LOCAL_DOMAINS=no" {
  export KUMA_INTERVAL="60"
  export USE_LOCAL_DOMAINS="no"
  run kuma_monitor_sql create "jellyfin" "http" "10.0.0.5" "8096"
  [[ "$output" == *"'http://10.0.0.5:8096'"* ]]
}

@test "kuma_monitor_sql: https sets ignore_tls=1" {
  export KUMA_INTERVAL="60"
  export USE_LOCAL_DOMAINS="yes"
  run kuma_monitor_sql create "portainer" "https" "10.0.0.8" "9443"
  [[ "$output" == *"'https://portainer.local:9443'"* ]]
  [[ "$output" == *"'[]', 1, 0, 1, 2000 WHERE NOT EXISTS"* ]]   # conditions='[]', ignore_tls=1
}

@test "kuma_monitor_sql: http sets ignore_tls=0, omits default port 80" {
  export KUMA_INTERVAL="60"
  export USE_LOCAL_DOMAINS="yes"
  run kuma_monitor_sql create "adguard" "http" "10.0.0.9" "80"
  [[ "$output" == *"'http://adguard.local'"* ]]
  [[ "$output" == *"'[]', 0, 0, 1, 2000 WHERE NOT EXISTS"* ]]   # conditions='[]', ignore_tls=0
  [[ "$output" != *":80"* ]]
}

@test "kuma_monitor_sql: update refreshes url/ignore_tls/active only" {
  export KUMA_INTERVAL="60"
  export USE_LOCAL_DOMAINS="yes"
  run kuma_monitor_sql update "jellyfin" "http" "10.0.0.5" "8096"
  [[ "$output" == "UPDATE monitor SET url='http://jellyfin.local:8096', ignore_tls=0, active=1 WHERE name='jellyfin';" ]]
}

@test "kuma_dedupe_sql: emits delete keeping lowest id per duplicated name" {
  run kuma_dedupe_sql
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"DELETE FROM monitor WHERE id NOT IN (SELECT MIN(id) FROM monitor GROUP BY name)"* ]]
  [[ "$output" == *"HAVING COUNT(*) > 1"* ]]
}

@test "kuma_status_group_sql: selects default group by slug" {
  run kuma_status_group_sql "all"
  [[ "$output" == *'FROM "group" AS g JOIN status_page AS s'* ]]
  [[ "$output" == *"WHERE s.slug='all'"* ]]
  [[ "$output" == *"ORDER BY g.id ASC LIMIT 1;"* ]]
}

@test "kuma_status_group_sql: escapes single quote in slug" {
  run kuma_status_group_sql "it's"
  [[ "$output" == *"s.slug='its'"* ]]
}

@test "kuma_link_sql: inserts monitor-group link guarded by NOT EXISTS" {
  run kuma_link_sql "12" "3"
  [[ "$output" == "INSERT INTO monitor_group (monitor_id, group_id, weight, send_url) SELECT 12, 3, 1000, 0 WHERE NOT EXISTS (SELECT 1 FROM monitor_group WHERE monitor_id=12 AND group_id=3);" ]]
}