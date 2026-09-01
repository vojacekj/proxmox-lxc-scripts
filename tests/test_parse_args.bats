#!/usr/bin/env bats
# tests/test_parse_args.bats — tests for parse_args() function

load test_helper

@test "parse_args: --dry-run sets DRY_RUN" {
  DRY_RUN=false
  DO_DETECT=false
  parse_args --dry-run
  [ "$DRY_RUN" = "true" ]
}

@test "parse_args: --detect sets DO_DETECT" {
  DRY_RUN=false
  DO_DETECT=false
  parse_args --detect
  [ "$DO_DETECT" = "true" ]
}

@test "parse_args: multiple flags" {
  DRY_RUN=false
  DO_DETECT=false
  parse_args --dry-run --detect
  [ "$DRY_RUN" = "true" ]
  [ "$DO_DETECT" = "true" ]
}

@test "parse_args: no args leaves defaults" {
  DRY_RUN=false
  DO_DETECT=false
  parse_args
  [ "$DRY_RUN" = "false" ]
  [ "$DO_DETECT" = "false" ]
}

@test "parse_args: --help exits 0" {
  run parse_args --help
  [ "$status" -eq 0 ]
}

@test "parse_args: unknown flag exits non-zero" {
  run parse_args --invalid-flag
  [ "$status" -eq 1 ]
}