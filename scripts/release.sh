#!/bin/bash
set -euo pipefail
source "$(dirname -- "$0")/packaging-common.sh"
configuration=release
output_dir="$PACKAGING_ROOT/dist"
universal=false
unsigned=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) [[ $# -ge 2 ]] || exit 2; configuration=$2; shift 2;;
        --output-dir) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2;;
        --universal) universal=true; shift;;
        --unsigned-for-testing) unsigned=true; shift;;
        --help) printf 'usage: release.sh [--configuration release|debug] [--output-dir repository-directory] [--universal] [--unsigned-for-testing]\n'; exit 0;;
        *) printf 'Unknown release option: %s\n' "$1" >&2; exit 2;;
    esac
done
if [[ -n "${NOTARY_PROFILE:-}" && -z "${SIGNING_IDENTITY:-}" ]]; then
    printf 'NOTARY_PROFILE requires a nonempty SIGNING_IDENTITY for notarisation.\n' >&2
    exit 1
fi
# The release Team ID the app pins its own updates to (PatchedReleaseTeamID). A Developer ID release must
# name its certificate's team, checked against the actual signature after building; an ad-hoc one must not
# pin anything. Checked before building, so nothing is produced on a refusal.
release_team_id=${RELEASE_TEAM_ID:-}
packaging_check_release_team "$release_team_id" "${SIGNING_IDENTITY:-}" 1 || exit 1
# Self-update requires a pinned release to be notarised, so a Developer ID release is always notarised.
if [[ -n "${SIGNING_IDENTITY:-}" && -z "${NOTARY_PROFILE:-}" ]]; then
    printf 'SIGNING_IDENTITY requires NOTARY_PROFILE: Developer ID releases must be notarised and stapled.\n' >&2
    exit 1
fi
# Release signing: the zip is signed with the Ed25519 key in the owner's login Keychain (generic password,
# account ed25519), and the signature must verify against the public key built into Patched, which is what
# self-update checks. The service can be changed only so the packaging checks can use a throwaway key in a
# throwaway keychain; the public-key override is refused for the real service.
default_key_service=im.patched.release-signing
key_service=${PATCHED_RELEASE_KEY_SERVICE:-$default_key_service}
keychain_args=()
if [[ -n "${PATCHED_RELEASE_KEYCHAIN:-}" ]]; then keychain_args=("$PATCHED_RELEASE_KEYCHAIN"); fi
expected_key=$(/usr/bin/sed -n 's/^    public static let publicKeyBase64 = "\([A-Za-z0-9+\/=]*\)"$/\1/p' \
    "$PACKAGING_ROOT/Sources/UpdateInstaller/SelfUpdate.swift")
[[ ${#expected_key} -eq 44 ]] || { printf 'Could not read the release public key from SelfUpdate.swift.\n' >&2; exit 1; }
if [[ -n "${PATCHED_RELEASE_PUBLIC_KEY_OVERRIDE:-}" ]]; then
    if [[ "$key_service" = "$default_key_service" || -z "${PATCHED_RELEASE_KEYCHAIN:-}" ]]; then
        printf 'PATCHED_RELEASE_PUBLIC_KEY_OVERRIDE is only for a throwaway test key in a throwaway keychain (PATCHED_RELEASE_KEYCHAIN), never %s.\n' "$default_key_service" >&2
        exit 1
    fi
    expected_key=$PATCHED_RELEASE_PUBLIC_KEY_OVERRIDE
fi
if "$unsigned"; then
    printf 'Unsigned test archive (--unsigned-for-testing): no .sig is written, and Patched will not install it.\n'
elif ! /usr/bin/security find-generic-password -s "$key_service" -a ed25519 \
        ${keychain_args[@]+"${keychain_args[@]}"} > /dev/null 2>&1; then
    # Checked before building, so nothing is produced. Only the item's presence is read here.
    printf 'Release signing key not found (Keychain generic password, service %s, account ed25519).\n' "$key_service" >&2
    printf 'Refusing to produce release artifacts. Pass --unsigned-for-testing for a local test archive.\n' >&2
    exit 1
fi
packaging_version
packaging_output_dir "$output_dir"
build_options=(--configuration "$configuration" --output-dir "$PACKAGING_OUTPUT")
if "$universal"; then build_options+=(--universal); fi
RELEASE_TEAM_ID="$release_team_id" /bin/bash "$PACKAGING_ROOT/scripts/build-app.sh" "${build_options[@]}"
app="$PACKAGING_OUTPUT/Patched.app"
built_team_id=$(/usr/bin/plutil -extract PatchedReleaseTeamID raw -o - "$app/Contents/Info.plist") || {
    printf 'The built app has no PatchedReleaseTeamID; refusing to archive.\n' >&2; exit 1; }
if [[ "$built_team_id" != "$release_team_id" ]]; then
    printf 'The built app pins Team ID "%s", not RELEASE_TEAM_ID "%s"; refusing to archive.\n' "$built_team_id" "$release_team_id" >&2
    exit 1
fi
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    # The certificate actually used, including identities supplied by hash, must be the pinned team's.
    packaging_require_signing_team "$app" "$release_team_id" || exit 1
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    # Check the resulting certificate, including identities supplied by hash.
    authority=$(/usr/bin/codesign -d --verbose=2 "$app" 2>&1)
    if ! /usr/bin/grep -q '^Authority=Developer ID Application:' <<< "$authority"; then
        printf 'NOTARY_PROFILE requires an actual Developer ID Application signature; refusing to archive.\n' >&2
        exit 1
    fi
fi
archive="Patched-$PACKAGING_VERSION.zip"
stage=$(mktemp -d "$PACKAGING_ROOT/.build/packaging-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
zip_app() { /usr/bin/ditto -c -k --keepParent "$app" "$stage/$archive"; }
zip_app
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    /usr/bin/xcrun notarytool submit "$stage/$archive" --keychain-profile "$NOTARY_PROFILE" --wait \
        --output-format json > "$stage/notary-result.json"
    if ! notary_status=$(/usr/bin/plutil -extract status raw -o - "$stage/notary-result.json"); then
        printf 'Could not read notarisation status; refusing to publish release artifacts.\n' >&2
        exit 1
    fi
    if [[ "$notary_status" != Accepted ]]; then
        printf 'Notarisation status is %s, expected Accepted; refusing to publish release artifacts.\n' "$notary_status" >&2
        exit 1
    fi
    /usr/bin/xcrun stapler staple "$app"
    /usr/bin/xcrun stapler validate "$app"
    # The stapled app must satisfy exactly the requirement pinned copies of Patched will check it against.
    packaging_require_release_requirement "$app" "$release_team_id" || exit 1
    rm "$stage/$archive"
    zip_app
else
    printf 'Created local archive without notarisation (NOTARY_PROFILE was not supplied).\n'
fi
if ! "$unsigned"; then
    # Sign the final zip bytes. The key goes from the Keychain straight into the signer's stdin: it is never
    # in a variable, an argument, a file or the log.
    mkdir -p "$PACKAGING_ROOT/.build/packaging-module-cache"
    /usr/bin/xcrun swiftc -module-cache-path "$PACKAGING_ROOT/.build/packaging-module-cache" \
        -o "$stage/release-signing" "$PACKAGING_ROOT/scripts/release-signing.swift"
    if ! /usr/bin/security find-generic-password -s "$key_service" -a ed25519 -w \
            ${keychain_args[@]+"${keychain_args[@]}"} 2> /dev/null \
            | "$stage/release-signing" sign "$stage/$archive" "$stage/$archive.sig"; then
        printf 'Could not sign %s with the release key; refusing to publish release artifacts.\n' "$archive" >&2
        exit 1
    fi
    if ! "$stage/release-signing" verify "$stage/$archive" "$stage/$archive.sig" "$expected_key"; then
        printf 'The signature does not verify against the release public key built into Patched; refusing to publish release artifacts.\n' >&2
        exit 1
    fi
fi
# A .sig from an earlier build of this version must never sit beside the new zip, even if a later step fails.
rm -f "$PACKAGING_OUTPUT/$archive.sig"
/bin/mv -fh "$stage/$archive" "$PACKAGING_OUTPUT/$archive"
(cd "$PACKAGING_OUTPUT" && /usr/bin/shasum -a 256 "$archive" > "$stage/$archive.sha256")
/bin/mv -fh "$stage/$archive.sha256" "$PACKAGING_OUTPUT/$archive.sha256"
if "$unsigned"; then
    rm -f "$PACKAGING_OUTPUT/$archive.sig"
    printf 'Release artifacts: %s/%s and .sha256 (unsigned, for testing only)\n' "$PACKAGING_OUTPUT" "$archive"
else
    /bin/mv -fh "$stage/$archive.sig" "$PACKAGING_OUTPUT/$archive.sig"
    printf 'Release artifacts: %s/%s, .sha256 and .sig\n' "$PACKAGING_OUTPUT" "$archive"
fi
