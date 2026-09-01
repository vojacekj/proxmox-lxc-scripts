#!/usr/bin/env bats
# tests/test_homepage_config.bats — tests for homepage_icon(), homepage_service_yaml()
# and get_service_group()

load test_helper

# --- homepage_icon ---

@test "homepage_icon: sh-shorthand for known service" {
  run homepage_icon "jellyfin"
  [ "$status" -eq 0 ]
  [[ "$output" == "sh-jellyfin" ]]
}

@test "homepage_icon: passes dash slug through unchanged" {
  run homepage_icon "home-assistant"
  [[ "$output" == "sh-home-assistant" ]]
}

@test "homepage_icon: unknown service falls back to sh-server" {
  run homepage_icon "totally-unknown-service-xyz"
  [[ "$output" == "sh-server" ]]
}

@test "homepage_icon: uses override URL when ICON_OVERRIDES set" {
  export ICON_OVERRIDES="myapp:https://cdn.example/icon.svg"
  run homepage_icon "myapp"
  [[ "$output" == "https://cdn.example/icon.svg" ]]
}

@test "homepage_icon: custom default icon for known custom app" {
  run homepage_icon "yuvomi"
  [[ "$output" == "https://cdn.jsdelivr.net/gh/selfhst/icons@main/svg/yuvomi.svg" ]]
}

@test "homepage_icon: custom default for omnitools uses mdi shorthand" {
  run homepage_icon "omnitools"
  [[ "$output" == "mdi:sitemap" ]]
}

# --- homepage_service_yaml ---

@test "homepage_service_yaml: emits href, icon; no widget for non-gatus" {
  run homepage_service_yaml "jellyfin" "http" "10.0.0.5" "8096" "sh-jellyfin" "http://gatus.local"
  [ "$status" -eq 0 ]
  [[ "$output" == *"href: http://jellyfin.local:8096"* ]]
  [[ "$output" == *"icon: sh-jellyfin"* ]]
  [[ "$output" != *"widget:"* ]]
}

@test "homepage_service_yaml: attaches gatus widget only for gatus service" {
  run homepage_service_yaml "gatus" "http" "10.0.0.99" "8080" "sh-gatus" "http://gatus.local:8080"
  [[ "$output" == *"widget:"* ]]
  [[ "$output" == *"type: gatus"* ]]
  [[ "$output" == *"url: http://gatus.local:8080"* ]]
}

@test "homepage_service_yaml: omits default port 80" {
  run homepage_service_yaml "pihole" "http" "10.0.0.6" "80" "sh-pi_hole" "http://gatus.local"
  [[ "$output" == *"href: http://pihole.local"* ]]
  [[ "$output" != *":80"* ]]
}

@test "homepage_service_yaml: omits default port 443" {
  run homepage_service_yaml "nextcloud" "https" "10.0.0.7" "443" "sh-nextcloud" "http://gatus.local"
  [[ "$output" == *"href: https://nextcloud.local"* ]]
}

@test "homepage_service_yaml: uses IP href when USE_LOCAL_DOMAINS=no" {
  export USE_LOCAL_DOMAINS="no"
  run homepage_service_yaml "jellyfin" "http" "10.0.0.5" "8096" "sh-jellyfin" "http://gatus.local"
  [[ "$output" == *"href: http://10.0.0.5:8096"* ]]
}

# --- get_service_group ---

@test "get_service_group: matches known member" {
  run get_service_group "jellyfin"
  [[ "$output" == "media" ]]
}

@test "get_service_group: matches alias via partial" {
  run get_service_group "pihole"
  [[ "$output" == "dns" ]]
}

@test "get_service_group: home-assistant maps to automation" {
  run get_service_group "home-assistant"
  [[ "$output" == "automation" ]]
}

@test "get_service_group: unknown returns empty failure" {
  run get_service_group "totally-unknown-service-xyz"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}