#!/usr/bin/env bash
# Reports how one set of c2pa-rs JSON schemas differs from another.
#
# Usage:
#   schema-drift.sh <checked-in-dir> <latest-dir>
#     Compare every *.schema.json in the two directories and print a Markdown
#     report of what the latest set adds, removes or changes: whole schemas,
#     then definitions and top-level properties, and for a changed definition
#     its properties. Prints nothing when the sets match.
#   schema-drift.sh --release <dir>
#     Print the c2pa-rs release the schemas in the directory were generated
#     from, for example v0.92.2. That is not always C2PA_VERSION: the pin can
#     move without the schemas being regenerated.
#
# "$comment" is left out of the comparison. update-schemas.sh stamps it with
# the release the schema came from, so it differs between any two releases.
#
# Exit codes:
#   0  done; the report (possibly empty) or the release is on stdout
#   1  a schema could not be read, or with --release the schemas do not all
#      carry the same release stamp
#   2  usage error, or a directory that does not exist
#
# Requires: jq. Kept to what bash 3.2 offers, since macOS runners ship that.

# The backticks in single quotes below are Markdown, not command substitution.
# shellcheck disable=SC2016

set -euo pipefail

SUFFIX=".schema.json"
STAMP='^Generated from c2pa-rs (v[^[:space:]]+) by make update-schemas\.$'

usage() {
    local name
    name="$(basename "$0")"
    echo "usage: ${name} <checked-in-dir> <latest-dir>" >&2
    echo "       ${name} --release <dir>" >&2
    exit 2
}

require_directory() {
    if [ ! -d "$1" ]; then
        echo "not a directory: $1" >&2
        exit 2
    fi
}

# The schema file names in a directory, one per line, in a fixed order.
schema_names() {
    local path
    for path in "$1"/*"${SUFFIX}"; do
        [ -e "${path}" ] || continue
        basename "${path}"
    done | LC_ALL=C sort
}

# Objects are compared by value, so the order of keys never counts.
COMPARE='
def properties_of: if type == "object" then (.properties // {}) else {} end;

def property_changes($old; $new):
    ($old | properties_of) as $before
    | ($new | properties_of) as $after
    | [ ($before + $after | keys[]) as $name
        | if ($before | has($name) | not) then "added `\($name)`"
          elif ($after | has($name) | not) then "removed `\($name)`"
          elif $before[$name] != $after[$name] then "changed `\($name)`"
          else empty end ];

($old[0]["$defs"] // {}) as $before
| ($new[0]["$defs"] // {}) as $after
| ( ($before + $after | keys[]) as $name
    | if ($before | has($name) | not) then "- added definition `\($name)`"
      elif ($after | has($name) | not) then "- removed definition `\($name)`"
      elif $before[$name] != $after[$name] then
          property_changes($before[$name]; $after[$name]) as $detail
          | "- changed definition `\($name)`"
            + (if ($detail | length) > 0 then ": " + ($detail | join(", ")) else "" end)
      else empty end ),
  ( property_changes($old[0]; $new[0])[]
    | capture("^(?<verb>[a-z]+) (?<name>.*)$")
    | "- \(.verb) property \(.name)" ),
  ( ($old[0] + $new[0] | keys[]) as $key
    | select($key != "$comment" and $key != "$defs" and $key != "properties")
    | select($old[0][$key] != $new[0][$key])
    | "- changed `\($key)`" )
'

report() {
    local checked_in="$1" latest="$2" name lines separator=""
    { schema_names "${checked_in}"; schema_names "${latest}"; } | LC_ALL=C sort -u | while IFS= read -r name; do
        if [ ! -e "${checked_in}/${name}" ]; then
            lines="- new schema"
        elif [ ! -e "${latest}/${name}" ]; then
            lines="- no longer exported"
        else
            lines="$(jq -n -r --slurpfile old "${checked_in}/${name}" --slurpfile new "${latest}/${name}" "${COMPARE}")"
        fi
        if [ -n "${lines}" ]; then
            printf '%s**`%s`**\n\n%s\n' "${separator}" "${name}" "${lines}"
            separator=$'\n'
        fi
    done
}

stamped_release() {
    local directory="$1" name comment found="" releases
    while IFS= read -r name; do
        comment="$(jq -r '."$comment" // "" | tostring' "${directory}/${name}")"
        if [[ "${comment}" =~ ${STAMP} ]]; then
            found="${found}${BASH_REMATCH[1]}"$'\t'"${name}"$'\n'
        else
            echo "${name} carries no release stamp in \$comment" >&2
            exit 1
        fi
    done < <(schema_names "${directory}")

    if [ -z "${found}" ]; then
        echo "no ${SUFFIX} files in ${directory}" >&2
        exit 1
    fi

    releases="$(printf '%s' "${found}" | cut -f1 | LC_ALL=C sort -u)"
    if [ "$(printf '%s\n' "${releases}" | wc -l)" -gt 1 ]; then
        echo "the schemas come from different releases ($(printf '%s' "${found}" | LC_ALL=C sort | awk -F'\t' '
            $1 != release { if (release != "") printf "; "; printf "%s: %s", $1, $2; release = $1; next }
            { printf ", %s", $2 }'))" >&2
        exit 1
    fi
    echo "${releases}"
}

if [ "${1:-}" = "--release" ]; then
    [ $# -eq 2 ] || usage
    require_directory "$2"
    stamped_release "$2"
else
    [ $# -eq 2 ] || usage
    require_directory "$1"
    require_directory "$2"
    report "$1" "$2"
fi
