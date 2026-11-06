#!/bin/bash
set -euo pipefail
source "$(dirname -- "$0")/packaging-common.sh"
configuration=release
output_dir="$PACKAGING_ROOT/dist"
universal=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) [[ $# -ge 2 ]] || exit 2; configuration=$2; shift 2;;
        --output-dir) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2;;
        --universal) universal=true; shift;;
        --help) printf 'usage: release.sh [--configuration release|debug] [--output-dir repository-directory] [--universal]\n'; exit 0;;
        *) printf 'Unknown release option: %s\n' "$1" >&2; exit 2;;
    esac
done
if [[ -n "${NOTARY_PROFILE:-}" && -z "${SIGNING_IDENTITY:-}" ]]; then
    printf 'NOTARY_PROFILE requires a nonempty SIGNING_IDENTITY for notarisation.\n' >&2
    exit 1
fi
packaging_version
packaging_output_dir "$output_dir"
build_options=(--configuration "$configuration" --output-dir "$PACKAGING_OUTPUT")
if "$universal"; then build_options+=(--universal); fi
/bin/bash "$PACKAGING_ROOT/scripts/build-app.sh" "${build_options[@]}"
app="$PACKAGING_OUTPUT/Patched.app"
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
    rm "$stage/$archive"
    zip_app
else
    printf 'Created local archive without notarisation (NOTARY_PROFILE was not supplied).\n'
fi
/bin/mv -fh "$stage/$archive" "$PACKAGING_OUTPUT/$archive"
(cd "$PACKAGING_OUTPUT" && /usr/bin/shasum -a 256 "$archive" > "$stage/$archive.sha256")
/bin/mv -fh "$stage/$archive.sha256" "$PACKAGING_OUTPUT/$archive.sha256"
printf 'Release artifacts: %s/%s and .sha256\n' "$PACKAGING_OUTPUT" "$archive"
