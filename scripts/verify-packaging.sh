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
# Release signing uses a throwaway key in a throwaway keychain, never the owner's login Keychain item.
test_service=im.patched.release-signing.packaging-check
test_keychain="$stage/release-signing-test.keychain-db"
/usr/bin/security create-keychain -p "packaging-check-$RANDOM$RANDOM" "$test_keychain"
/usr/bin/security set-keychain-settings "$test_keychain"
release_env=(env -u SIGNING_IDENTITY -u NOTARY_PROFILE -u PATCHED_RELEASE_PUBLIC_KEY_OVERRIDE
             PATCHED_RELEASE_KEY_SERVICE="$test_service" PATCHED_RELEASE_KEYCHAIN="$test_keychain")
expect_release_refusal() {
    local name=$1 message=$2 status
    shift 2
    if "$@" --output-dir "$stage/$name" > "$stage/$name.log" 2>&1; then
        printf 'Release unexpectedly succeeded (%s).\n' "$name" >&2; exit 1
    else
        status=$?
    fi
    [[ $status -eq 1 ]] || { printf 'Expected exit 1 for %s, got %s.\n' "$name" "$status" >&2; exit 1; }
    /usr/bin/grep -q "$message" "$stage/$name.log" || { printf 'Missing refusal text for %s.\n' "$name" >&2; exit 1; }
    [[ ! -e "$stage/$name/Patched-$PACKAGING_VERSION.zip" && ! -e "$stage/$name/Patched-$PACKAGING_VERSION.zip.sig" ]] || {
        printf 'Refused release (%s) left a zip or signature.\n' "$name" >&2; exit 1; }
}
# No key: refused before building, nothing produced.
expect_release_refusal no-key-release 'Release signing key not found' \
    "${release_env[@]}" /bin/bash scripts/release.sh "${build_options[@]}"
[[ ! -e "$stage/no-key-release" ]] || { printf 'Release without a key created output.\n' >&2; exit 1; }
# The public-key override is refused for the real service.
expect_release_refusal real-override-release 'only for a throwaway test key' \
    env -u SIGNING_IDENTITY -u NOTARY_PROFILE -u PATCHED_RELEASE_KEY_SERVICE PATCHED_RELEASE_KEYCHAIN="$test_keychain" \
    PATCHED_RELEASE_PUBLIC_KEY_OVERRIDE=czM+l4MfG6HP6I7YVIjQSjPvW/7wIKTfJw1wN74W1EU= /bin/bash scripts/release.sh "${build_options[@]}"
# ...and for any other service unless a throwaway keychain is named too.
expect_release_refusal no-keychain-override-release 'only for a throwaway test key' \
    env -u SIGNING_IDENTITY -u NOTARY_PROFILE -u PATCHED_RELEASE_KEYCHAIN PATCHED_RELEASE_KEY_SERVICE="$test_service" \
    PATCHED_RELEASE_PUBLIC_KEY_OVERRIDE=czM+l4MfG6HP6I7YVIjQSjPvW/7wIKTfJw1wN74W1EU= /bin/bash scripts/release.sh "${build_options[@]}"
mkdir -p .build/packaging-module-cache
/usr/bin/xcrun swiftc -module-cache-path "$PACKAGING_ROOT/.build/packaging-module-cache" \
    -o "$stage/release-signing" scripts/release-signing.swift
test_private_key=$("$stage/release-signing" generate-test-key)
test_public_key=$(printf '%s\n' "$test_private_key" | "$stage/release-signing" public-key)
embedded_key=$(/usr/bin/sed -n 's/^    public static let publicKeyBase64 = "\([A-Za-z0-9+\/=]*\)"$/\1/p' Sources/UpdateInstaller/SelfUpdate.swift)
[[ "$embedded_key" = 3pXCQuK7pRsCXKXhXwld3tJw+yisZpSMKef3OjEsk/k= ]] || { printf 'Unexpected embedded release key.\n' >&2; exit 1; }
[[ "$test_public_key" != "$embedded_key" ]]
/usr/bin/security add-generic-password -s "$test_service" -a ed25519 -w "$test_private_key" -T /usr/bin/security "$test_keychain"
unset test_private_key
# A key that is not the one built into Patched: signed, but the self-check refuses to publish.
expect_release_refusal wrong-key-release 'does not verify against the release public key built into Patched' \
    "${release_env[@]}" /bin/bash scripts/release.sh "${build_options[@]}"
printf 'Release signing refused without a key, with the real-service override, and with a key Patched does not embed.\n'
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
"${release_env[@]}" PATCHED_RELEASE_PUBLIC_KEY_OVERRIDE="$test_public_key" \
    /bin/bash scripts/release.sh "${build_options[@]}" --output-dir "$stage/release"
[[ "$(cat "$stage/checksum-sentinel")" = 'Packaging checksum sentinel' ]]
[[ ! -L "$stage/release/Patched-$PACKAGING_VERSION.zip.sha256" ]]
(cd "$stage/release" && /usr/bin/shasum -a 256 -c "Patched-$PACKAGING_VERSION.zip.sha256")
# The .sig is one base64 line that verifies over the zip with the throwaway key, and with nothing else.
release_zip="$stage/release/Patched-$PACKAGING_VERSION.zip"
release_sig="$release_zip.sig"
[[ -f "$release_sig" && ! -L "$release_sig" && "$(/usr/bin/wc -l < "$release_sig" | /usr/bin/tr -d ' ')" = 1 ]]
/usr/bin/grep -Eq '^[A-Za-z0-9+/]{86}==$' "$release_sig"
"$stage/release-signing" verify "$release_zip" "$release_sig" "$test_public_key"
if "$stage/release-signing" verify "$release_zip" "$release_sig" "$embedded_key" > /dev/null 2>&1; then
    printf 'A throwaway signature verified against the real release key.\n' >&2; exit 1
fi
/bin/cp "$release_zip" "$stage/tampered.zip"
printf 'x' >> "$stage/tampered.zip"
if "$stage/release-signing" verify "$stage/tampered.zip" "$release_sig" "$test_public_key" > /dev/null 2>&1; then
    printf 'A tampered zip verified.\n' >&2; exit 1
fi
printf 'Release signature verified with the throwaway key; the real key and a tampered zip are refused.\n'
# --unsigned-for-testing still builds a zip without the Keychain, and writes no signature.
env -u SIGNING_IDENTITY -u NOTARY_PROFILE PATCHED_RELEASE_KEY_SERVICE=im.patched.release-signing.absent \
    PATCHED_RELEASE_KEYCHAIN="$stage/absent.keychain-db" \
    /bin/bash scripts/release.sh "${build_options[@]}" --unsigned-for-testing --output-dir "$stage/unsigned-release"
[[ -f "$stage/unsigned-release/Patched-$PACKAGING_VERSION.zip" && ! -e "$stage/unsigned-release/Patched-$PACKAGING_VERSION.zip.sig" ]]
(cd "$stage/unsigned-release" && /usr/bin/shasum -a 256 -c "Patched-$PACKAGING_VERSION.zip.sha256")
/usr/bin/ditto -x -k "$stage/release/Patched-$PACKAGING_VERSION.zip" "$stage/unpacked"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$stage/unpacked/Patched.app"
/usr/bin/codesign --verify --strict --verbose=2 "$stage/unpacked/Patched.app/Contents/Helpers/patched"
if "$universal"; then
    assert_universal "$stage/unpacked/Patched.app/Contents/MacOS/Patched"
    assert_universal "$stage/unpacked/Patched.app/Contents/Helpers/patched"
fi
printf '\nverify-packaging.sh: all checks passed\n'
