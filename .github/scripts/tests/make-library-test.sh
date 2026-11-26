#!/usr/bin/env bash
# Tests how the Makefile's library target behaves when one of its steps fails.
# Run from anywhere:
#
#   bash .github/scripts/tests/make-library-test.sh
#
# The real recipe runs, in a scratch directory, against stand-ins for
# xcodebuild and zip, so it needs no Xcode and touches nothing in the checkout.
# Exits non-zero when a case fails.

set -u

MAKEFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/Makefile"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/bin"

# Leaves a framework directory for its destination and logs the call. When
# FAIL_AT names the step it fails, with the directory still there: a failed
# build leaves partial or earlier products behind, which is how a broken
# framework used to reach the packaging steps.
cat > "${WORK}/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
step=""
output=""
previous=""
for argument in "$@"; do
    case "${previous}" in
        -destination)
            case "${argument}" in
                "generic/platform=iOS") step="device"; products="Release-iphoneos" ;;
                "generic/platform=iOS Simulator") step="simulator"; products="Release-iphonesimulator" ;;
                "generic/platform=macOS,variant=Mac Catalyst") step="catalyst"; products="Release-maccatalyst" ;;
                "generic/platform=macOS") step="macos"; products="Release" ;;
            esac ;;
        -output) output="${argument}" ;;
    esac
    case "${argument}" in
        -showBuildSettings) echo "    SYMROOT = ${STUB_ROOT}/Products"; exit 0 ;;
        -create-xcframework) step="xcframework" ;;
    esac
    previous="${argument}"
done
echo "${step}" >> "${STUB_ROOT}/calls.log"
if [ "${step}" != "xcframework" ]; then
    mkdir -p "${STUB_ROOT}/Products/${products}/C2PAC.framework"
elif [ "${FAIL_AT:-}" != "xcframework" ]; then
    mkdir -p "${output}"
fi
if [ "${step}" = "${FAIL_AT:-}" ]; then
    echo "** BUILD FAILED **"
    exit 65
fi
STUB

cat > "${WORK}/bin/zip" <<'STUB'
#!/usr/bin/env bash
echo "zip" >> "${STUB_ROOT}/calls.log"
[ "${FAIL_AT:-}" = "zip" ] && exit 12
: > "$2"
STUB

chmod +x "${WORK}/bin/xcodebuild" "${WORK}/bin/zip"

failures=0
current=""

fail() {
    echo "FAIL ${current}: $1"
    failures=$((failures + 1))
}

# run <step to fail at, or "none">
run() {
    current="$1"
    rm -rf "${WORK}/run"
    mkdir -p "${WORK}/run"
    output="$(cd "${WORK}/run" && PATH="${WORK}/bin:${PATH}" STUB_ROOT="${WORK}/run" FAIL_AT="$1" \
        make -f "${MAKEFILE}" library 2>&1)"
    status=$?
    calls="$(tr '\n' ' ' < "${WORK}/run/calls.log")"
}

expect_calls() {
    [ "${calls}" = "$1" ] || fail "steps run: ${calls}(expected: $1)"
}

expect_failure() {
    [ "${status}" -ne 0 ] || fail "make exited 0"
    case "${output}" in
        *"Library build completed."*) fail "reported the build as completed" ;;
    esac
}

expect_lacks() {
    case "${output}" in
        *"$1"*) fail "printed: $1" ;;
    esac
}

run none
current="every step succeeds"
[ "${status}" -eq 0 ] || fail "make exited ${status}: ${output}"
expect_calls "device simulator catalyst macos xcframework zip "
case "${output}" in
    *"Library build completed."*) ;;
    *) fail "did not report the build as completed" ;;
esac
[ -d "${WORK}/run/Library/Frameworks/C2PAC.xcframework" ] || fail "no XCFramework in Library/Frameworks"
[ -f "${WORK}/run/output/C2PAC.xcframework.zip" ] || fail "no packaged XCFramework in output"

run device
expect_failure
expect_calls "device "

run simulator
expect_failure
expect_calls "device simulator "

run catalyst
expect_failure
expect_calls "device simulator catalyst "

run macos
expect_failure
expect_calls "device simulator catalyst macos "
expect_lacks "Creating XCFramework"

run xcframework
expect_failure
expect_calls "device simulator catalyst macos xcframework "
expect_lacks "C2PAC.xcframework created"
expect_lacks "XCFramework packaged"

run zip
expect_failure
expect_calls "device simulator catalyst macos xcframework zip "
expect_lacks "XCFramework packaged"

if [ "${failures}" -gt 0 ]; then
    echo "${failures} failed"
    exit 1
fi
echo "All library recipe tests passed."
