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

# --- resolve: stable mode ---

# Picks the semver-max stable release, NOT the most recently published one.
# releases.json lists the 0.89.4 backport first on purpose. This is the rich
# integration fixture covering ordering across the whole list; the three
# exclusion behaviours below get their own minimal, isolated fixtures so a
# single broken guard fails only its own test.
assert "stable: semver-max wins over list order" \
  "v0.90.0" 0 resolve releases.json --mode stable

# Release candidates must never be selected in stable mode. The trap
# (0.91.0-rc.2) outranks the legitimate answer (0.90.0), so removing the rc
# exclusion guard flips the result and only this test fails.
assert "stable: ignores rc prereleases" \
  "v0.90.0" 0 resolve stable-with-rc.json --mode stable

# Only the c2pa-v* tag family is considered; c2pa-c-ffi-v* and c2patool-v*
# share the repo but are not what library-release.yml builds binaries from.
# The trap (c2pa-c-ffi-v0.91.0) outranks the legitimate answer (0.90.0), so
# leaking that tag family flips the result and only this test fails. It is
# also a real upstream scenario: release-plz is documented to sometimes cut a
# crate without cutting the dependent, leaving c2pa-c-ffi ahead of c2pa with
# no c2pa binaries built.
assert "stable: ignores other crates' tags" \
  "v0.90.0" 0 resolve stable-with-other-crates.json --mode stable

# Drafts have no downloadable assets. The trap (draft c2pa-v0.92.0) outranks
# the legitimate answer (0.90.0), so removing the draft filter flips the
# result and only this test fails.
assert "stable: ignores drafts" \
  "v0.90.0" 0 resolve stable-with-draft.json --mode stable

assert "usage: rejects unknown mode" \
  "" 1 resolve releases.json --mode banana

# --- resolve: input validation ---

# A GitHub API error body (e.g. rate-limit) is a JSON object, not an array.
# Must be rejected outright rather than silently yielding "nothing to track".
assert "resolve: rejects non-array JSON input" \
  "" 1 resolve not-an-array.json --mode stable

# Empty stdin means the fetch step upstream produced nothing -- a failure,
# not a legitimately quiet release train. Must not be conflated with exit 3.
assert "resolve: rejects empty input" \
  "" 1 resolve empty.json --mode stable

# --- resolve: argument parsing ---

# --mode as the final argument, with no value following, must fail through
# the normal usage path (clear stderr message, exit 1) rather than aborting
# on an unhandled `shift` error with nothing printed.
assert "usage: rejects --mode with missing value" \
  "" 1 resolve releases.json --mode

# rc mode with a malformed --stable value: awk's split()/%05d would silently
# coerce a garbled value to a 0 floor, letting excluded rcs through. Must be
# rejected up front instead.
assert "usage: rejects malformed --stable value" \
  "" 1 resolve releases.json --mode rc --stable garbage

# --- resolve: rc mode ---

# Highest rc build of the in-flight train.
assert "rc: picks highest rc build" \
  "v0.91.0-rc.2" 0 resolve releases.json --mode rc --stable v0.90.0

# Skip-if-empty: upstream skips the train when nothing breaking is queued.
# Exit 3 is the idle-train no-op, not an error.
assert "rc: no train in flight exits 3" \
  "" 3 resolve releases-no-train.json --mode rc --stable v0.90.0

# An rc whose base version is already published is a stale leftover from a
# promoted train and must not be tracked.
assert "rc: ignores rc at or below current stable" \
  "" 3 resolve releases.json --mode rc --stable v0.91.0

assert "rc: requires --stable" \
  "" 1 resolve releases.json --mode rc

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
