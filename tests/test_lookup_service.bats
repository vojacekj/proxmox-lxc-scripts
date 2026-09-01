#!/usr/bin/env bats
# tests/test_lookup_service.bats — tests for lookup_service() function

load test_helper

# --- Direct matches ---

@test "lookup_service: direct match 'jellyfin'" {
  run lookup_service "jellyfin"
  [[ "$output" == "jellyfin:8096"* ]]
}

@test "lookup_service: direct match 'sonarr'" {
  run lookup_service "sonarr"
  [[ "$output" == "sonarr:8989"* ]]
}

@test "lookup_service: direct match 'portainer'" {
  run lookup_service "portainer"
  [[ "$output" == "portainer:9443"* ]]
}

@test "lookup_service: direct match 'gotify'" {
  run lookup_service "gotify"
  [[ "$output" == "gotify:8080"* ]]
}

@test "lookup_service: direct match 'home-assistant'" {
  run lookup_service "home-assistant"
  [[ "$output" == "home-assistant:8123"* ]]
}

# --- Case insensitivity ---

@test "lookup_service: case-insensitive match 'JELLYFIN'" {
  run lookup_service "JELLYFIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"8096"* ]]
}

@test "lookup_service: case-insensitive match 'Sonarr'" {
  run lookup_service "Sonarr"
  [ "$status" -eq 0 ]
  [[ "$output" == *"8989"* ]]
}

# --- Partial matches ---

@test "lookup_service: partial match 'pihole' via pi-hole key" {
  run lookup_service "pihole"
  [ "$status" -eq 0 ]
}

@test "lookup_service: partial match 'uptime-kuma'" {
  run lookup_service "uptime-kuma"
  [[ "$output" == "uptime-kuma:3001"* ]]
}

# --- Misses ---

@test "lookup_service: unknown service returns failure" {
  run lookup_service "nonexistent-service-xyz"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "lookup_service: empty string returns failure" {
  run lookup_service ""
  [ "$status" -eq 1 ]
}

# --- Multiple alias coverage ---

@test "lookup_service: 'hass' maps to home-assistant" {
  run lookup_service "hass"
  [[ "$output" == "home-assistant:8123"* ]]
}

@test "lookup_service: 'npm' maps to nginx-proxy-manager" {
  run lookup_service "npm"
  [[ "$output" == "nginx-proxy-manager:81"* ]]
}

@test "lookup_service: 'actual' maps to actual-budget" {
  run lookup_service "actual"
  [[ "$output" == "actual-budget:5006"* ]]
}
