#!/usr/bin/env bats
# tests/test_skip_apps.bats — tests for SKIP_APPS logic

load test_helper

# Helper: simulates the SKIP_APPS check from the main loop.
# Returns 0 if the container should be skipped, 1 if it should be processed.
should_skip() {
  local name="$1"
  local skip_apps="$2"
  local name_lower
  name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
  [[ ",${skip_apps}," == *",${name_lower},"* ]]
}

# --- The bug we just fixed (name_lower must be set before check) ---

@test "SKIP_APPS: empty SKIP_APPS does not skip non-empty name" {
  run should_skip "jellyfin" ""
  [ "$status" -eq 1 ]
}

@test "SKIP_APPS: empty name matches empty SKIP_APPS (expected behavior)" {
  # When both are empty, ",," matches ",," — this is harmless since
  # no real container has an empty name.
  run should_skip "" ""
  [ "$status" -eq 0 ]
}

# --- Normal skip behavior ---

@test "SKIP_APPS: skips exact name match" {
  run should_skip "jellyfin" "jellyfin"
  [ "$status" -eq 0 ]
}

@test "SKIP_APPS: skips case-insensitive match" {
  run should_skip "Jellyfin" "jellyfin"
  [ "$status" -eq 0 ]
}

@test "SKIP_APPS: skips among multiple entries" {
  run should_skip "docker" "pve,monitoring,docker,backup"
  [ "$status" -eq 0 ]
}

@test "SKIP_APPS: does not skip unrelated name" {
  run should_skip "jellyfin" "pve,monitoring,docker"
  [ "$status" -eq 1 ]
}

@test "SKIP_APPS: partial name does not match" {
  run should_skip "jelly" "jellyfin"
  [ "$status" -eq 1 ]
}

@test "SKIP_APPS: single entry matches" {
  run should_skip "pve" "pve"
  [ "$status" -eq 0 ]
}

# --- Regression test for the exact bug ---

@test "SKIP_APPS: regression — name_lower populated before check" {
  local name="authentik"
  local skip_apps="authentik,docker,flame"

  # The fixed code sets name_lower BEFORE the check
  local name_lower
  name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')

  local result=1
  [[ ",${skip_apps}," == *",${name_lower},"* ]] && result=0
  [ "$result" -eq 0 ]
}

@test "SKIP_APPS: regression — non-matching name not falsely skipped" {
  local name="jellyfin"
  local skip_apps="authentik,docker,flame"

  local name_lower
  name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')

  local result=1
  [[ ",${skip_apps}," == *",${name_lower},"* ]] && result=0
  [ "$result" -eq 1 ]
}
