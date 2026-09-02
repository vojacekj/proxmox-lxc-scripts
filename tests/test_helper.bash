#!/usr/bin/env bash
# tests/test_helper.bash — shared setup for all bats tests
#
# Sources dashboard-discover.sh functions for testing.
#
# We can't simply `source dashboard-discover.sh` because:
#   1. bash does not propagate `declare -A SERVICE_MAP` into the
#      subshells that bats `run` uses, so the map would be empty.
#   2. Top-level code (config loading, PATH export) has side effects.
#
# Instead we generate a "testable extract" containing the mandatory
# globals (SCAN_PORTS, PORT_OVERRIDES, ICON_OVERRIDES, SKIP_APPS,
# and the Gatus/Homepage defaults), the SERVICE_MAP array, and the pure
# functions under test. This is regenerated on every test run.

generate_testable_script() {
  local repo_root="$1"
  local out="$2"

  {
    cat <<'HEADER'
#!/bin/bash
export LOG_STDOUT=no
SCAN_PORTS="80,443,8080,8443,3000,5000,8096,8920,9090,8123,7878,8888,9000,9696,5678"
PORT_OVERRIDES=""
ICON_OVERRIDES=""
SKIP_APPS=""
GATUS_ENABLED="yes"
GATUS_CONFIG_DIR="/opt/gatus/config"
GATUS_SCAN_INTERVAL="60"
GATUS_ALERTING="yes"
HOMEPAGE_ENABLED="yes"
HOMEPAGE_CONFIG_DIR="/opt/homepage/config"
HOMEPAGE_SERVICES_FILE="services.yaml"
HOMEPAGE_GATUS_URL="http://gatus.local"
USE_LOCAL_DOMAINS="yes"
HEADER

    # Export the associative array (declare -gxA, bash 5.1+) so it
    # propagates into the subshells used by bats `run`.
    sed -n '/^declare -A SERVICE_MAP=(/,/^)/p' "${repo_root}/dashboard-discover.sh" \
      | sed 's/^declare -A SERVICE_MAP=(/declare -gxA SERVICE_MAP=(/'

    # CATEGORY_MAP (plain string) used by get_service_group.
    # Block starts with 'CATEGORY_MAP="...' and ends at the first line
    # that closes the quote (ends with a trailing '"').
    sed -n '/^CATEGORY_MAP="/,/\"$/p' "${repo_root}/dashboard-discover.sh"

    # CUSTOM_ICON_DEFAULTS (assoc array) used by homepage_icon as fallback
    # icons for apps without a SERVICE_MAP / selfhst slug.
    sed -n '/^declare -A CUSTOM_ICON_DEFAULTS=(/,/^)/p' "${repo_root}/dashboard-discover.sh" \
      | sed 's/^declare -A CUSTOM_ICON_DEFAULTS=(/declare -gxA CUSTOM_ICON_DEFAULTS=(/'


    for fn in normalize_url lookup_service get_icon_url get_port_override get_service_group homepage_icon link_host extract_service_names merge_homepage_yaml inject_homepage_sitemonitor homepage_has_dup_groups dedup_homepage_groups extract_endpoint_names extract_endpoint_urls merge_gatus_yaml new_service_names new_endpoint_names kuma_monitor_url kuma_monitor_sql kuma_status_group_sql kuma_link_sql; do
      sed -n "/^${fn}()/,/^}/p" "${repo_root}/dashboard-discover.sh"
      echo ''
    done

    # gatus_config_header and gatus_endpoint_yaml and homepage_service_yaml
    sed -n '/^gatus_config_header()/,/^}/p' "${repo_root}/dashboard-discover.sh"
    echo ''
    sed -n '/^gatus_endpoint_yaml()/,/^}/p' "${repo_root}/dashboard-discover.sh"
    echo ''
    sed -n '/^homepage_service_yaml()/,/^}/p' "${repo_root}/dashboard-discover.sh"
    echo ''

    sed -n '/^parse_args()/,/^}/p' "${repo_root}/dashboard-discover.sh"

    # Stub the community-scripts icon lookup so unit tests stay offline and
    # deterministic (homepage_icon falls back to the server.svg CDN icon).
    cat <<'STUB'
fetch_icon_from_community_scripts() {
  return 1
}
STUB
  } > "$out"
}

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  TESTABLE_SCRIPT="${BATS_TEST_TMPDIR:-/tmp}/dashboard-testable.sh"
  generate_testable_script "$REPO_ROOT" "$TESTABLE_SCRIPT"
  source "$TESTABLE_SCRIPT"
}