#!/usr/bin/env bash
# Tests for schema-drift.sh. Run from anywhere:
#
#   bash .github/scripts/tests/schema-drift-test.sh
#
# Needs bash and jq. Exits non-zero when a case fails.

# The backticks in single quotes below are Markdown, not command substitution.
# shellcheck disable=SC2016

set -u

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/schema-drift.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

failures=0
current=""

begin() {
    current="$1"
    rm -rf "${WORK}/old" "${WORK}/new"
    mkdir -p "${WORK}/old" "${WORK}/new"
}

fail() {
    echo "FAIL ${current}: $1"
    failures=$((failures + 1))
}

# schema <directory> <name> <jq filter over the base schema> [comment]
schema() {
    local comment="${4:-Generated from c2pa-rs v1.0.0 by make update-schemas.}"
    jq -n --arg comment "${comment}" "
        {
            \"\$schema\": \"https://json-schema.org/draft/2020-12/schema\",
            \"\$comment\": \$comment,
            type: \"object\",
            properties: {},
            \"\$defs\": {}
        } | $3" > "${WORK}/$1/$2.schema.json"
}

drift() {
    output="$(bash "${SCRIPT}" "${WORK}/old" "${WORK}/new" 2>&1)"
    status=$?
}

release() {
    output="$(bash "${SCRIPT}" --release "${WORK}/old" 2>&1)"
    status=$?
}

expect_status() {
    [ "${status}" -eq "$1" ] || fail "exit status ${status}, expected $1 (output: ${output})"
}

expect_output() {
    [ "${output}" = "$1" ] || fail "output was: ${output}"
}

expect_contains() {
    case "${output}" in
        *"$1"*) ;;
        *) fail "missing: $1 (output: ${output})" ;;
    esac
}

expect_lacks() {
    case "${output}" in
        *"$1"*) fail "unexpected: $1 (output: ${output})" ;;
    esac
}

expect_items() {
    local count
    count="$(printf '%s\n' "${output}" | grep -c '^- ')"
    [ "${count}" -eq "$1" ] || fail "${count} list items, expected $1 (output: ${output})"
}

STRING='{type: "string"}'
INTEGER='{type: "integer"}'

begin "identical schemas report nothing"
schema old Settings ".[\"\$defs\"].Foo = {type: \"object\", properties: {a: ${STRING}}} | .properties.title = ${STRING}"
cp "${WORK}/old/Settings.schema.json" "${WORK}/new/"
drift; expect_status 0; expect_output ""

begin "the comment is ignored"
schema old Settings ".[\"\$defs\"].Foo = {type: \"object\", properties: {a: ${STRING}}}" "Generated from c2pa-rs v1.0.0 by make update-schemas."
schema new Settings ".[\"\$defs\"].Foo = {type: \"object\", properties: {a: ${STRING}}}" "Generated from c2pa-rs v1.0.1 by make update-schemas."
drift; expect_status 0; expect_output ""

begin "key order is not a difference"
schema old Settings ".[\"\$defs\"].Foo = {type: \"object\", properties: {a: ${STRING}, b: ${INTEGER}}}"
schema new Settings ".[\"\$defs\"].Foo = {properties: {b: ${INTEGER}, a: ${STRING}}, type: \"object\"}"
drift; expect_status 0; expect_output ""

begin "added and removed definitions"
schema old Settings ".[\"\$defs\"] = {Bar: {type: \"object\"}, Kept: {type: \"object\"}}"
schema new Settings ".[\"\$defs\"] = {Foo: {type: \"object\"}, Kept: {type: \"object\"}}"
drift; expect_status 0; expect_items 2
expect_contains '- added definition `Foo`'
expect_contains '- removed definition `Bar`'
expect_lacks 'Kept'

begin "a changed definition names its properties"
schema old Settings ".[\"\$defs\"].Foo = {type: \"object\", properties: {b: ${STRING}, c: ${STRING}, same: ${STRING}}}"
schema new Settings ".[\"\$defs\"].Foo = {type: \"object\", properties: {a: ${STRING}, c: ${INTEGER}, same: ${STRING}}}"
drift; expect_status 0; expect_items 1
expect_contains '- changed definition `Foo`: added `a`, removed `b`, changed `c`'
expect_lacks '`same`'

begin "a changed definition without property changes"
schema old Settings ".[\"\$defs\"].Foo = {type: \"object\", properties: {a: ${STRING}}, required: []}"
schema new Settings ".[\"\$defs\"].Foo = {type: \"object\", properties: {a: ${STRING}}, required: [\"a\"]}"
drift; expect_status 0; expect_items 1
expect_contains '- changed definition `Foo`'
expect_lacks '`a`'

begin "top-level properties"
schema old Settings ".properties = {gone: ${STRING}, kind: ${STRING}, same: ${STRING}}"
schema new Settings ".properties = {fresh: ${STRING}, kind: ${INTEGER}, same: ${STRING}}"
drift; expect_status 0; expect_items 3
expect_contains '- added property `fresh`'
expect_contains '- removed property `gone`'
expect_contains '- changed property `kind`'
expect_lacks '`same`'

begin "a change outside definitions and properties"
schema old Settings "."
schema new Settings ".required = [\"title\"]"
drift; expect_status 0; expect_items 1
expect_contains '- changed `required`'

begin "the report groups by schema"
schema old Builder ".[\"\$defs\"].Foo = {type: \"object\"}"
schema new Builder ".[\"\$defs\"].Foo = {type: \"object\"}"
schema old Settings ".[\"\$defs\"].Core = {type: \"object\", properties: {a: ${STRING}}}"
schema new Settings ".[\"\$defs\"].Core = {type: \"object\", properties: {a: ${STRING}, b: ${STRING}}}"
drift; expect_status 0
expect_output '**`Settings.schema.json`**

- changed definition `Core`: added `b`'

begin "sections are separated by a blank line"
schema old Builder "."
schema new Builder ".required = [\"a\"]"
schema old Settings "."
schema new Settings ".required = [\"b\"]"
drift; expect_status 0
expect_output '**`Builder.schema.json`**

- changed `required`

**`Settings.schema.json`**

- changed `required`'

begin "a schema on one side only"
schema old Reader "."
schema new Ingredient "."
drift; expect_status 0
expect_output '**`Ingredient.schema.json`**

- new schema

**`Reader.schema.json`**

- no longer exported'

begin "files that are not schemas are ignored"
schema old Settings "."
schema new Settings "."
echo "not a schema" > "${WORK}/old/es256_certs.pem"
echo '{"a": 1}' > "${WORK}/new/other.json"
drift; expect_status 0; expect_output ""

begin "text that the shell could expand is reported as it is"
schema old Settings "."
schema new Settings ".[\"\$defs\"][\"\$(id) \$HOME\"] = {type: \"object\"}"
drift; expect_status 0
expect_contains '- added definition `$(id) $HOME`'

begin "a missing directory is a usage error"
output="$(bash "${SCRIPT}" "${WORK}/old" "${WORK}/absent" 2>&1)"; status=$?
expect_status 2; expect_contains "not a directory"

begin "the wrong number of arguments is a usage error"
output="$(bash "${SCRIPT}" "${WORK}/old" 2>&1)"; status=$?
expect_status 2; expect_contains "usage:"

begin "a file that is not JSON fails"
schema old Settings "."
echo "{ not json" > "${WORK}/new/Settings.schema.json"
drift
[ "${status}" -ne 0 ] || fail "a malformed schema was accepted (output: ${output})"

begin "release: reads the release the schemas were generated from"
schema old Builder "." "Generated from c2pa-rs v0.92.2 by make update-schemas."
schema old Settings "." "Generated from c2pa-rs v0.92.2 by make update-schemas."
release; expect_status 0; expect_output "v0.92.2"

begin "release: reads a release candidate"
schema old Settings "." "Generated from c2pa-rs v0.93.0-rc.1 by make update-schemas."
release; expect_status 0; expect_output "v0.93.0-rc.1"

begin "release: schemas from different releases are an error"
schema old Builder "." "Generated from c2pa-rs v0.92.2 by make update-schemas."
schema old Settings "." "Generated from c2pa-rs v0.92.3 by make update-schemas."
release; expect_status 1
expect_contains "v0.92.2: Builder.schema.json"
expect_contains "v0.92.3: Settings.schema.json"

begin "release: a schema without a stamp is an error"
schema old Builder "." "Generated from c2pa-rs v0.92.2 by make update-schemas."
schema old Settings "del(.[\"\$comment\"])"
release; expect_status 1
expect_contains "Settings.schema.json"

begin "release: a stamp in another form is an error"
schema old Settings "." "Generated from c2pa-rs main by hand."
release; expect_status 1
expect_contains "Settings.schema.json"

begin "release: a directory without schemas is an error"
release; expect_status 1
expect_contains "no .schema.json files"

if [ "${failures}" -gt 0 ]; then
    echo "${failures} failed"
    exit 1
fi
echo "All schema drift tests passed."
