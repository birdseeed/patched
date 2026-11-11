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
        --help) printf 'usage: build-app.sh [--configuration release|debug] [--output-dir repository-directory] [--universal]\n'; exit 0;;
        *) printf 'Unknown build option: %s\n' "$1" >&2; exit 2;;
    esac
done
[[ "$configuration" = release || "$configuration" = debug ]] || { printf 'Invalid build configuration\n' >&2; exit 2; }
release_team_id=${RELEASE_TEAM_ID:-}
packaging_check_release_team "$release_team_id" "${SIGNING_IDENTITY:-}" 0
packaging_version
packaging_output_dir "$output_dir"
cd "$PACKAGING_ROOT"
mkdir -p .build/packaging-module-cache .build/packaging-tmp
export CLANG_MODULE_CACHE_PATH="$PACKAGING_ROOT/.build/packaging-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export TMPDIR="$PACKAGING_ROOT/.build/packaging-tmp/"
build_args=(-c "$configuration" --scratch-path "$PACKAGING_ROOT/.build" --disable-automatic-resolution)
if [[ "$configuration" = release ]]; then build_args+=(-debug-info-format none); fi
case "${PACKAGING_DISABLE_SWIFTPM_SANDBOX:-0}" in
    0) ;;
    1) build_args+=(--disable-sandbox);;
    *) printf 'PACKAGING_DISABLE_SWIFTPM_SANDBOX must be 0 or 1\n' >&2; exit 2;;
esac
if "$universal"; then build_args+=(--arch arm64 --arch x86_64); fi
# Some SwiftPM versions honour only the last repeated --product. Explicitly build
# the GUI afterwards so both products exist on those versions too.
swift build "${build_args[@]}" --product PatchedApp --product patched
swift build "${build_args[@]}" --product PatchedApp
bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
build_number=$(git rev-list --count HEAD)
[[ "$build_number" =~ ^[0-9]+$ ]] || exit 1
stage=$(mktemp -d "$PACKAGING_ROOT/.build/packaging-app.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Patched.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
cp "$bin_dir/PatchedApp" "$app/Contents/MacOS/Patched"
cp "$bin_dir/patched" "$app/Contents/Helpers/patched"
chmod 755 "$app/Contents/MacOS/Patched" "$app/Contents/Helpers/patched"
# The app icon is generated from the brand PNG, so no binary icon file is kept in the repository.
icon_source="$PACKAGING_ROOT/packaging/brand/app-icon-1024.png"
[[ -f "$icon_source" ]] || { printf 'Missing brand icon: %s\n' "$icon_source" >&2; exit 1; }
mkdir -p "$app/Contents/Resources"
iconset="$stage/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" > /dev/null
    /usr/bin/sips -z "$((size * 2))" "$((size * 2))" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
packaging_render packaging/Info.plist.template "$app/Contents/Info.plist" \
    "VERSION=$PACKAGING_VERSION" "BUILD_NUMBER=$build_number" "RELEASE_TEAM_ID=$release_team_id"
sign_args=(--force --options runtime --entitlements "$PACKAGING_ROOT/packaging/Patched.entitlements")
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    sign_args+=(--timestamp -s "$SIGNING_IDENTITY")
else
    sign_args+=(--timestamp=none -s -)
fi
/usr/bin/codesign "${sign_args[@]}" --identifier im.patched.cli "$app/Contents/Helpers/patched"
/usr/bin/codesign "${sign_args[@]}" "$app"
/usr/bin/codesign --verify --strict --verbose=2 "$app/Contents/Helpers/patched"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
# A pinned build must be signed by the team it pins, or it would refuse its own next release.
if [[ -n "$release_team_id" ]]; then packaging_require_signing_team "$app" "$release_team_id"; fi
destination="$PACKAGING_OUTPUT/Patched.app"
[[ ! -L "$destination" ]] || { printf 'Refusing symlink app output\n' >&2; exit 1; }
if [[ -e "$destination" ]]; then
    [[ -d "$destination" && -f "$destination/Contents/Info.plist" ]] || { printf 'Unexpected app output already exists\n' >&2; exit 1; }
    # Move the previous artifact into our owned scratch directory before replacing.
    mv "$destination" "$stage/previous.app"
fi
mv "$app" "$destination"
printf 'Built %s\n' "$destination"
