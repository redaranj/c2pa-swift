#!/usr/bin/env bash
# Dependency-free tests for the c2pa-rs tracking helper scripts.
# Run with: make test-ci-scripts

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESOLVE="$ROOT/.github/scripts/resolve-c2pa-version.sh"
ASSETS="$ROOT/.github/scripts/check-c2pa-assets.sh"
FIXTURES="$ROOT/tests/ci/fixtures"

pass=0
fail=0

# assert <name> <expected-stdout> <expected-exit> <command> [args...]
assert() {
  local name="$1" expected="$2" expected_code="$3"
  shift 3
  # Declared separately from the assignment below: `local actual="$(...)"`
  # would make `local` itself the last command, so $? would always read 0.
  local actual code errors
  errors="$(mktemp)"
  # stderr is kept rather than discarded, and echoed on failure only. Without
  # it a script that crashed (unbound variable, missing jq, unreadable fixture)
  # is indistinguishable from one that correctly reported nothing and exited
  # non-zero -- both render as empty stdout with the same exit code.
  actual="$("$@" 2>"$errors")"
  code=$?
  if [ "$actual" = "$expected" ] && [ "$code" = "$expected_code" ]; then
    printf 'ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s\n       expected: %s (exit %s)\n       actual:   %s (exit %s)\n' \
      "$name" "'$expected'" "$expected_code" "'$actual'" "$code"
    if [ -s "$errors" ]; then
      printf '       stderr:   %s\n' "$(tr '\n' ' ' < "$errors")"
    fi
    fail=$((fail + 1))
  fi
  rm -f "$errors"
}

resolve() {
  local fixture="$1"
  shift
  "$RESOLVE" "$@" < "$FIXTURES/$fixture"
}

check_assets() {
  local fixture="$1"
  shift
  "$ASSETS" "$@" < "$FIXTURES/$fixture"
}

# --- tests go here ---

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
