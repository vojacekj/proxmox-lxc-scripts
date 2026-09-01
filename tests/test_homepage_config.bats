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

@test "homepage_icon: unknown service falls back to selfhst server svg" {
  run homepage_icon "totally-unknown-service-xyz"
  [[ "$output" == "https://cdn.jsdelivr.net/gh/selfhst/icons@main/svg/server.svg" ]]
  [[ "$output" != *"sh-server"* ]]
  [[ "$output" != *".local"* ]]
}

@test "homepage_icon: uses override URL when ICON_OVERRIDES set" {
  export ICON_OVERRIDES="myapp:https://cdn.example/icon.svg"
  run homepage_icon "myapp"
  [[ "$output" == "https://cdn.example/icon.svg" ]]
}

@test "homepage_icon: custom default icon for known custom app" {
  run homepage_icon "yuvomi"
  [[ "$output" == "https://cdn.jsdelivr.net/gh/selfhst/icons@main/webp/yuvomi.webp" ]]
}

@test "homepage_icon: custom default for omnitools uses its repo logo url" {
  run homepage_icon "omnitools"
  [[ "$output" == "https://cdn.jsdelivr.net/gh/iib0011/omni-tools@main/src/assets/logo.png" ]]
}

@test "homepage_icon: custom default for convertx uses selfhst webp" {
  run homepage_icon "convertx"
  [[ "$output" == "https://cdn.jsdelivr.net/gh/selfhst/icons@main/webp/convertx.webp" ]]
}

@test "homepage_icon: proxmox-hive uses its github logo url" {
  run homepage_icon "proxmox-hive"
  [[ "$output" == "https://cdn.jsdelivr.net/gh/macokay/proxmox-hive@main/client/public/hive.svg" ]]
  [[ "$output" != *"proxmox.svg"* ]]
}

@test "homepage_icon: proxmox uses the proxmox.svg logo" {
  run homepage_icon "proxmox"
  [[ "$output" == "https://cdn.jsdelivr.net/gh/selfhst/icons@main/svg/proxmox.svg" ]]
}

@test "homepage_icon: never returns a .local icon path" {
  for name in omnitools yuvomi convertx proxmox-hive proxmox jellyfin unknown-custom-app; do
    run homepage_icon "$name"
    [[ "$output" != *".local"* ]]
  done
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

# --- merge_homepage_yaml (only add new) ---

@test "merge_homepage_yaml: keeps existing verbatim, adds only new service" {
  local gen exist
  gen=$(mktemp); exist=$(mktemp)
  printf '%s\n' \
    '- Infrastructure:' \
    '    - proxmox:' \
    '        href: https://192.168.1.238:8006' \
    '    - jellyfin:' \
    '        href: http://192.168.1.210:8096' > "$gen"
  printf '%s\n' \
    '- Infrastructure:' \
    '    - proxmox:' \
    '        href: https://pve.mydomain.net:8006' \
    '' \
    '- Custom:' \
    '    - mydash:' \
    '        href: http://192.168.1.50:8080' > "$exist"
  run merge_homepage_yaml "$gen" "$exist"
  [[ "$status" -eq 0 ]]
  # existing proxmox domain edit is KEPT (existing not rewritten)
  [[ "$output" == *"href: https://pve.mydomain.net:8006"* ]]
  # manual mydash block + its Custom group preserved
  [[ "$output" == *"- Custom:"* ]]
  [[ "$output" == *"href: http://192.168.1.50:8080"* ]]
  # NEW jellyfin (not in existing) is added, with its name/href
  [[ "$output" == *"jellyfin:"* ]]
  [[ "$output" == *"href: http://192.168.1.210:8096"* ]]
  rm -f "$gen" "$exist"
}

@test "merge_homepage_yaml: already-present service is not duplicated" {
  local gen exist
  gen=$(mktemp); exist=$(mktemp)
  printf '%s\n' \
    '- Media:' \
    '    - jellyfin:' \
    '        href: http://192.168.1.210:8096' > "$gen"
  printf '%s\n' \
    '- Media:' \
    '    - jellyfin:' \
    '        href: http://192.168.1.210:8096' > "$exist"
  run merge_homepage_yaml "$gen" "$exist"
  [[ "$status" -eq 0 ]]
  [[ "$output" != *"jellyfin:"*"jellyfin:"* ]]
  rm -f "$gen" "$exist"
}

@test "merge_homepage_yaml: no existing file uses generated output" {
  local gen
  gen=$(mktemp)
  printf '%s\n' \
    '- Media:' \
    '    - jellyfin:' \
    '        href: http://192.168.1.210:8096' > "$gen"
  run merge_homepage_yaml "$gen" ""
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"href: http://192.168.1.210:8096"* ]]
  [[ "$output" != *"- Custom:"* ]]
  rm -f "$gen"
}

# --- merge_gatus_yaml (only add new) ---

@test "merge_gatus_yaml: keeps existing verbatim, adds only new endpoint" {
  local gen exist
  gen=$(mktemp); exist=$(mktemp)
  printf '%s\n' \
    'metrics: true' \
    'endpoints:' \
    '  - name: jellyfin' \
    '    group: media' \
    '    url: http://192.168.1.210:8096' > "$gen"
  printf '%s\n' \
    'metrics: true' \
    'endpoints:' \
    '  - name: proxmox' \
    '    url: https://OLD.example:8006' \
    '  - name: myprobe' \
    '    url: https://example.com/healthz' \
    '    conditions:' \
    '      - "[STATUS] == 200"' > "$exist"
  run merge_gatus_yaml "$gen" "$exist"
  [[ "$status" -eq 0 ]]
  # existing endpoints + manual block kept verbatim
  [[ "$output" == *"- name: myprobe"* ]]
  [[ "$output" == *"url: https://example.com/healthz"* ]]
  [[ "$output" == *'"[STATUS] == 200"'* ]]
  [[ "$output" == *"url: https://OLD.example:8006"* ]]
  # NEW jellyfin added once
  [[ "$output" == *"- name: jellyfin"* ]]
  rm -f "$gen" "$exist"
}

@test "merge_gatus_yaml: identical generated+existing adds nothing" {
  local gen exist
  gen=$(mktemp); exist=$(mktemp)
  printf '%s\n' 'metrics: true' 'endpoints:' '  - name: jellyfin' '    url: http://192.168.1.210:8096' > "$gen"
  printf '%s\n' 'metrics: true' 'endpoints:' '  - name: jellyfin' '    url: http://192.168.1.210:8096' > "$exist"
  run merge_gatus_yaml "$gen" "$exist"
  [[ ${#output} -gt 0 ]]
  [[ "$output" != *"- name: jellyfin"*"- name: jellyfin"* ]]
  rm -f "$gen" "$exist"
}

# Idempotency: once a generated service is in the deployment, a later display
# run leaves the file byte-identical (no reload churn on cron). We verify run2
# (existing = run1 output) equals run3 (existing = run2 output).
@test "merge_homepage_yaml: stable after first merge (no cron churn)" {
  local gen base
  gen=$(mktemp); base=$(mktemp)
  printf '%s\n' \
    '- Media:' \
    '    - jellyfin:' \
    '        href: http://192.168.1.210:8096' \
    '    - sonarr:' \
    '        href: http://192.168.1.211:8989' > "$gen"
  printf '%s\n' \
    '- Media:' \
    '    - jellyfin:' \
    '        href: http://192.168.1.210:8096' > "$base"
  local a b c
  a=$(merge_homepage_yaml "$gen" "$base")      # run1
  local fa; fa=$(mktemp); printf '%s' "$a" > "$fa"
  b=$(merge_homepage_yaml "$gen" "$fa")        # run2
  local fb; fb=$(mktemp); printf '%s' "$b" > "$fb"
  c=$(merge_homepage_yaml "$gen" "$fb")        # run3
  [[ "$b" == "$c" ]]                           # stable from run2 onward
  rm -f "$gen" "$base" "$fa" "$fb"
}

@test "merge_gatus_yaml: stable after first merge (no cron churn)" {
  local gen base
  gen=$(mktemp); base=$(mktemp)
  printf '%s\n' \
    'metrics: true' \
    'endpoints:' \
    '  - name: jellyfin' \
    '    url: http://192.168.1.210:8096' \
    '  - name: sonarr' \
    '    url: http://192.168.1.211:8989' > "$gen"
  printf '%s\n' \
    'metrics: true' \
    'endpoints:' \
    '  - name: jellyfin' \
    '    url: http://192.168.1.210:8096' > "$base"
  local a b c
  a=$(merge_gatus_yaml "$gen" "$base")         # run1
  local fa; fa=$(mktemp); printf '%s' "$a" > "$fa"
  b=$(merge_gatus_yaml "$gen" "$fa")           # run2
  local fb; fb=$(mktemp); printf '%s' "$b" > "$fb"
  c=$(merge_gatus_yaml "$gen" "$fb")           # run3
  [[ "$a" == "$b" ]] && [[ "$b" == "$c" ]]     # stable from run1 for gatus
  rm -f "$gen" "$base" "$fa" "$fb"
}

# --- new_service_names / new_endpoint_names (notification "added" tracking) ---

@test "new_service_names: only returns names not already deployed" {
  local gen exist
  gen=$(mktemp); exist=$(mktemp)
  printf '%s\n' '- Media:' '    - jellyfin:' '    - sonarr:' > "$gen"
  printf '%s\n' '- Media:' '    - jellyfin:' > "$exist"
  run new_service_names "$gen" "$exist"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "sonarr" ]]
  rm -f "$gen" "$exist"
}

@test "new_service_names: empty when all already deployed" {
  local gen exist
  gen=$(mktemp); exist=$(mktemp)
  printf '%s\n' '- Media:' '    - jellyfin:' > "$gen"
  printf '%s\n' '- Media:' '    - jellyfin:' > "$exist"
  run new_service_names "$gen" "$exist"
  [[ "$output" == "" ]]
  rm -f "$gen" "$exist"
}

@test "new_endpoint_names: returns only undeployed endpoints" {
  local gen exist
  gen=$(mktemp); exist=$(mktemp)
  printf '%s\n' 'endpoints:' '  - name: jellyfin' '  - name: sonarr' > "$gen"
  printf '%s\n' 'endpoints:' '  - name: jellyfin' > "$exist"
  run new_endpoint_names "$gen" "$exist"
  [[ "$output" == "sonarr" ]]
  rm -f "$gen" "$exist"
}