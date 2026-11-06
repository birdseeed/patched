#!/bin/bash
set -euo pipefail
export PATCHED_FORBID_REAL_STATE=1
source "$(dirname -- "$0")/packaging-common.sh"
universal=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --universal) universal=true; shift;;
        --help) printf 'usage: verify-packaging.sh [--universal]\n'; exit 0;;
        *) printf 'Unknown packaging verification option: %s\n' "$1" >&2; exit 2;;
    esac
done
cd "$PACKAGING_ROOT"
packaging_version
mkdir -p .build
stage=$(mktemp -d "$PACKAGING_ROOT/.build/packaging-check.XXXXXX")
cleanup() {
    local status=$?
    if [[ $status -eq 0 ]]; then rm -rf "$stage"; else printf 'Packaging check artifacts retained: %s\n' "$stage" >&2; fi
}
trap cleanup EXIT
build_options=(--configuration debug)
if "$universal"; then build_options+=(--universal); fi
# This refusal must happen before building or creating the requested output.
if env -u SIGNING_IDENTITY NOTARY_PROFILE=packaging-verification-unused \
    /bin/bash scripts/release.sh --output-dir "$stage/rejected-release" > "$stage/rejected-release.log" 2>&1; then
    printf 'Release unexpectedly accepted NOTARY_PROFILE without SIGNING_IDENTITY.\n' >&2
    exit 1
else
    rejected_status=$?
fi
[[ $rejected_status -eq 1 ]] || { printf 'Expected exit 1 for missing signing identity.\n' >&2; exit 1; }
/usr/bin/grep -q 'NOTARY_PROFILE requires a nonempty SIGNING_IDENTITY' "$stage/rejected-release.log"
[[ ! -e "$stage/rejected-release" ]] || { printf 'Rejected release created output artifacts.\n' >&2; exit 1; }
printf 'Notarisation without signing identity refused: exit 1, no output artifacts.\n'
env -u SIGNING_IDENTITY -u NOTARY_PROFILE /bin/bash scripts/build-app.sh "${build_options[@]}" --output-dir "$stage/build"
app="$stage/build/Patched.app"
cli="$app/Contents/Helpers/patched"
plist="$app/Contents/Info.plist"
assert_key() {
    local actual
    actual=$(/usr/bin/plutil -extract "$1" raw -o - "$plist")
    [[ "$actual" = "$2" ]] || { printf 'Info.plist %s: expected %s, got %s\n' "$1" "$2" "$actual" >&2; exit 1; }
}
/usr/bin/plutil -lint "$plist" packaging/Patched.entitlements
assert_key CFBundleName Patched
assert_key CFBundleDisplayName Patched
assert_key CFBundleIdentifier im.patched.app
assert_key CFBundleExecutable Patched
assert_key CFBundlePackageType APPL
assert_key CFBundleShortVersionString "$PACKAGING_VERSION"
assert_key CFBundleVersion "$(git rev-list --count HEAD)"
assert_key CFBundleIconFile AppIcon
assert_key LSMinimumSystemVersion 13.0
assert_key LSUIElement false
assert_key NSHumanReadableCopyright 'Copyright © 2026 Andy Bridson'
[[ -x "$app/Contents/MacOS/Patched" && -x "$cli" ]]
# The brand icon is part of the bundle and is a real icon file with the 1024 pixel representation.
icon="$app/Contents/Resources/AppIcon.icns"
[[ -s "$icon" ]] || { printf 'Missing app icon: %s\n' "$icon" >&2; exit 1; }
/usr/bin/file "$icon" | /usr/bin/grep -q 'Mac OS X icon' || { printf 'App icon is not an icns file: %s\n' "$icon" >&2; exit 1; }
assert_universal() {
    local executable=$1 architecture
    for architecture in arm64 x86_64; do
        /usr/bin/lipo -verify_arch "$architecture" "$executable" || {
            printf 'Missing %s Mach-O slice: %s\n' "$architecture" "$executable" >&2; exit 1;
        }
    done
}
if "$universal"; then
    assert_universal "$app/Contents/MacOS/Patched"
    assert_universal "$cli"
fi
for executable in "$app" "$cli"; do
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$executable"
    signature=$(/usr/bin/codesign -d --verbose=2 "$executable" 2>&1)
    # Hardened runtime is 0x10000; ad-hoc signatures additionally require 0x2.
    # Accept only these two exact combinations, and print the matched evidence.
    /usr/bin/grep -E '^CodeDirectory[[:space:]].*[[:space:]]flags=(0x10000\(runtime\)|0x10002\(adhoc,runtime\))([[:space:]]|$)' <<< "$signature" || {
        printf 'Expected exact runtime or ad-hoc runtime signing flags: %s\n' "$executable" >&2; exit 1;
    }
    expected_identifier=im.patched.app
    if [[ "$executable" = "$cli" ]]; then expected_identifier=im.patched.cli; fi
    /usr/bin/grep -Fxq "Identifier=$expected_identifier" <<< "$signature" || {
        printf 'Expected signing identifier %s: %s\n' "$expected_identifier" "$executable" >&2; exit 1;
    }
    /usr/bin/codesign -d --entitlements :- "$executable" > "$stage/entitlements.plist" 2> "$stage/entitlements.stderr"
    /usr/bin/python3 -I - "$stage/entitlements.plist" "$stage/entitlements.stderr" "$executable" <<'PY'
import pathlib
import plistlib
import sys

payload = pathlib.Path(sys.argv[1]).read_bytes()
if payload:
    try:
        entitlements = plistlib.loads(payload)
    except Exception as error:
        sys.exit(f"Malformed signed entitlements for {sys.argv[3]}: {error}")
    if type(entitlements) is not dict or entitlements:
        sys.exit(f"Expected an empty entitlement dictionary for {sys.argv[3]}")
else:
    # A successful codesign display can emit nothing when no entitlements exist.
    # Do not mistake a diagnostic about malformed entitlements for that case.
    diagnostics = pathlib.Path(sys.argv[2]).read_text().splitlines()
    allowed = (
        f"Executable={sys.argv[3]}/Contents/MacOS/Patched",
        f"Executable={sys.argv[3]}",
        "warning: Specifying ':' in the path is deprecated and will not work in a future release",
    )
    if any(line not in allowed for line in diagnostics):
        sys.exit(f"Unexpected empty-entitlements diagnostic for {sys.argv[3]}: {diagnostics!r}")
PY
    printf 'Verified identifier %s and empty signed entitlements: %s\n' "$expected_identifier" "$executable"
done
# The current CLI treats --help as usage with exit 2; do not run a real check.
if "$cli" --help > "$stage/help.txt" 2>&1; then help_status=0; else help_status=$?; fi
[[ $help_status -eq 0 || $help_status -eq 2 ]]
/usr/bin/grep -q '^usage: patched check' "$stage/help.txt"
if "$cli" --packaging-invalid-argument > "$stage/bad-argument.txt" 2>&1; then bad_status=0; else bad_status=$?; fi
[[ $bad_status -eq 2 ]]
escaped_app="$stage/Patched & <test> \"quoted\" 'app'.app"
/bin/bash scripts/schedule.sh install --target-dir "$stage/schedule" --app "$escaped_app"
schedule="$stage/schedule/im.patched.check.plist"
[[ "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$schedule")" = "$escaped_app/Contents/Helpers/patched" ]]
[[ "$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$schedule")" = check ]]
[[ "$(/usr/bin/plutil -extract ProgramArguments.2 raw -o - "$schedule")" = --json ]]
[[ "$(/usr/bin/plutil -extract Label raw -o - "$schedule")" = im.patched.check ]]
[[ "$(/usr/bin/plutil -extract StartInterval raw -o - "$schedule")" = 10800 ]]
! /usr/bin/plutil -extract StartCalendarInterval raw -o - "$schedule" > /dev/null 2>&1
[[ "$(/usr/bin/plutil -extract StandardOutPath raw -o - "$schedule")" = "$stage/schedule/Logs/check.log" ]]
[[ "$(/usr/bin/plutil -extract StandardErrorPath raw -o - "$schedule")" = "$stage/schedule/Logs/check-error.log" ]]
[[ ! -e "$stage/schedule/Logs" ]]
/bin/bash scripts/schedule.sh status --target-dir "$stage/schedule"
/bin/bash scripts/schedule.sh remove --target-dir "$stage/schedule"
[[ ! -e "$schedule" ]]
mkdir -p "$stage/release"
printf 'Packaging checksum sentinel\n' > "$stage/checksum-sentinel"
ln -s "$stage/checksum-sentinel" "$stage/release/Patched-$PACKAGING_VERSION.zip.sha256"
env -u SIGNING_IDENTITY -u NOTARY_PROFILE /bin/bash scripts/release.sh "${build_options[@]}" --output-dir "$stage/release"
[[ "$(cat "$stage/checksum-sentinel")" = 'Packaging checksum sentinel' ]]
[[ ! -L "$stage/release/Patched-$PACKAGING_VERSION.zip.sha256" ]]
(cd "$stage/release" && /usr/bin/shasum -a 256 -c "Patched-$PACKAGING_VERSION.zip.sha256")
/usr/bin/ditto -x -k "$stage/release/Patched-$PACKAGING_VERSION.zip" "$stage/unpacked"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$stage/unpacked/Patched.app"
/usr/bin/codesign --verify --strict --verbose=2 "$stage/unpacked/Patched.app/Contents/Helpers/patched"
if "$universal"; then
    assert_universal "$stage/unpacked/Patched.app/Contents/MacOS/Patched"
    assert_universal "$stage/unpacked/Patched.app/Contents/Helpers/patched"
fi
printf '\nverify-packaging.sh: all checks passed\n'
