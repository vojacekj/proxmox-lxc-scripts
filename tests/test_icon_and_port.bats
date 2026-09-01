#!/usr/bin/env bats
# tests/test_icon_and_port.bats — tests for get_icon_url() and get_port_override()

load test_helper

# --- get_icon_url ---

@test "get_icon_url: returns selfhst icon for known service" {
  run get_icon_url "jellyfin"
  [ "$status" -eq 0 ]
  [[ "$output" == *"selfhst/icons"* ]]
  [[ "$output" == *"jellyfin"* ]]
}

@test "get_icon_url: returns selfhst icon for grafana" {
  run get_icon_url "grafana"
  [ "$status" -eq 0 ]
  [[ "$output" == *"selfhst/icons"* ]]
  [[ "$output" == *"grafana"* ]]
}

@test "get_icon_url: returns generic icon for unknown service" {
  run get_icon_url "totally-unknown-service-xyz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"server.svg"* ]]
}

@test "get_icon_url: case-insensitive lookup" {
  run get_icon_url "JELLYFIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"jellyfin"* ]]
}

@test "get_icon_url: partial match works" {
  run get_icon_url "pihole"
  [ "$status" -eq 0 ]
  [[ "$output" == *"selfhst/icons"* ]]
}

# --- get_port_override ---

@test "get_port_override: returns port for override match" {
  export PORT_OVERRIDES="myapp:9999 custom:3000"
  run get_port_override "myapp"
  [[ "$output" == "9999"* ]]
}

@test "get_port_override: returns correct port from multiple" {
  export PORT_OVERRIDES="myapp:9999 custom:3000"
  run get_port_override "custom"
  [[ "$output" == "3000"* ]]
}

@test "get_port_override: no match returns failure" {
  export PORT_OVERRIDES="myapp:9999 custom:3000"
  run get_port_override "unknown"
  [ "$status" -eq 1 ]
}

@test "get_port_override: empty overrides returns failure" {
  export PORT_OVERRIDES=""
  run get_port_override "myapp"
  [ "$status" -eq 1 ]
}

@test "get_port_override: case-sensitive match" {
  export PORT_OVERRIDES="MyApp:8080"
  run get_port_override "myapp"
  [ "$status" -eq 1 ]
}
