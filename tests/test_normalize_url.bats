#!/usr/bin/env bats
# tests/test_normalize_url.bats — tests for the normalize_url() function

load test_helper

# --- Trailing slash removal ---

@test "normalize_url: removes single trailing slash" {
  run normalize_url "http://example.com/"
  [ "$output" = "http://example.com" ]
}

@test "normalize_url: no trailing slash unchanged" {
  run normalize_url "http://example.com"
  [ "$output" = "http://example.com" ]
}

# --- Lowercasing ---

@test "normalize_url: lowercases hostname" {
  run normalize_url "http://MyService.Local"
  [ "$output" = "http://myservice.local" ]
}

@test "normalize_url: lowercases entire URL" {
  run normalize_url "HTTP://EXAMPLE.COM/Path"
  [ "$output" = "http://example.com/path" ]
}

# --- Default port stripping ---

@test "normalize_url: strips :80 from http at end of URL" {
  run normalize_url "http://example.com:80"
  [ "$output" = "http://example.com" ]
}

@test "normalize_url: strips :443 from https at end of URL" {
  run normalize_url "https://example.com:443"
  [ "$output" = "https://example.com" ]
}

@test "normalize_url: does not strip :80 from :8000" {
  run normalize_url "http://example.com:8000"
  [ "$output" = "http://example.com:8000" ]
}

@test "normalize_url: does not strip :443 from :4430" {
  run normalize_url "https://example.com:4430"
  [ "$output" = "https://example.com:4430" ]
}

@test "normalize_url: preserves non-default ports" {
  run normalize_url "http://example.com:8080"
  [ "$output" = "http://example.com:8080" ]
}

@test "normalize_url: preserves non-default port 3000" {
  run normalize_url "http://grafana.local:3000"
  [ "$output" = "http://grafana.local:3000" ]
}

# --- Combined scenarios ---

@test "normalize_url: lowercase + trailing slash + default port at end" {
  run normalize_url "http://MyService.local:80/"
  [ "$output" = "http://myservice.local" ]
}

@test "normalize_url: default port before path is preserved" {
  run normalize_url "http://PiHole.Local:80/admin/"
  [ "$output" = "http://pihole.local:80/admin" ]
}

@test "normalize_url: empty string" {
  run normalize_url ""
  [ "$output" = "" ]
}