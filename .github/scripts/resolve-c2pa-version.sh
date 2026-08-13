#!/usr/bin/env bash
# Resolve the c2pa-rs release version a tracking branch should pin to.
#
# Reads a GitHub releases JSON array on stdin.
#
# Usage:
#   resolve-c2pa-version.sh --mode stable
#   resolve-c2pa-version.sh --mode rc --stable vX.Y.Z
#
# Exit codes:
#   0  resolved; the tag suffix (e.g. v0.91.0-rc.2) is on stdout
#   3  nothing to track -- the idle-train no-op; stdout empty
#   1  usage or input error

set -euo pipefail

usage() {
  echo "usage: $0 --mode stable|rc [--stable vX.Y.Z]" >&2
  exit 1
}

mode=""
stable=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)   mode="${2:-}";   shift 2 ;;
    --stable) stable="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

case "$mode" in
  stable) ;;
  rc)
    [ -n "$stable" ] || { echo "--mode rc requires --stable" >&2; exit 1; }
    ;;
  *) usage ;;
esac

# Consider only the c2pa-v* tag family. Per c2pa-rs docs/release-process.md it
# is library-release.yml, triggered on c2pa-v* tags, that builds the Apple
# binaries our Xcode build phase downloads -- so this tag family, and not
# c2pa-c-ffi-v*, is the authoritative "do binaries exist" signal.
#
# Selection is by tag SHAPE rather than the .prerelease flag, so a mis-flagged
# upstream release cannot put a release candidate on the stable branch.
# Drafts are excluded: they carry no downloadable assets.
tags="$(jq -r '.[] | select(.draft != true) | .tag_name' | sed -n 's/^c2pa-v//p')"

case "$mode" in
  stable)
    candidates="$(printf '%s\n' "$tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"
    ;;
  rc)
    candidates="$(printf '%s\n' "$tags" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$' || true)"
    ;;
esac

[ -n "$candidates" ] || exit 3

# Order by a zero-padded numeric key rather than `sort -V`, whose prerelease
# handling is not semver-correct (it sorts 0.91.0 BEFORE 0.91.0-rc.1) and
# differs between GNU and BSD userlands. Stable and RC candidates are never
# mixed in one sort, so the two key spaces stay independent.
#
# In rc mode, --stable acts as a floor: only candidates whose BASE version
# exceeds the current stable release are eligible.
best="$(printf '%s\n' "$candidates" | awk -F'[.-]' -v stable="${stable#v}" '
  BEGIN {
    if (stable != "") {
      split(stable, s, ".")
      floor_key = sprintf("%05d%05d%05d", s[1], s[2], s[3])
    }
  }
  {
    base = sprintf("%05d%05d%05d", $1, $2, $3)
    if (floor_key != "" && base <= floor_key) next
    rc = ($4 == "rc") ? $5 : 0
    printf "%s%05d\t%s\n", base, rc, $0
  }
' | sort | tail -1 | cut -f2)"

[ -n "$best" ] || exit 3

echo "v$best"
