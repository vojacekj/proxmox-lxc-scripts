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