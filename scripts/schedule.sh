#!/bin/bash
set -euo pipefail
source "$(dirname -- "$0")/packaging-common.sh"
action=${1:-}
[[ "$action" = install || "$action" = remove || "$action" = status ]] || {
    printf 'usage: schedule.sh install|remove|status [--app /path/Patched.app] [--target-dir repository-directory]\n' >&2; exit 2;
}
shift
app=/Applications/Patched.app
target_dir=""
custom=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) [[ $# -ge 2 ]] || exit 2; app=$2; shift 2;;
        --target-dir) [[ $# -ge 2 && -n "$2" ]] || exit 2; target_dir=$2; custom=true; shift 2;;
        *) printf 'Unknown schedule option: %s\n' "$1" >&2; exit 2;;
    esac
done
[[ "$app" = /* ]] || app="$PWD/$app"
if "$custom"; then
    # Test mode cannot address the user's LaunchAgents or Logs, even by symlink.
    # Restricting it to repository artifacts also makes the boundary unambiguous.
    packaging_output_dir "$target_dir"
    target_dir=$PACKAGING_OUTPUT
    log_dir="$target_dir/Logs"
else
    target_dir="$HOME/Library/LaunchAgents"
    log_dir="$HOME/Library/Logs/Patched"
fi
plist="$target_dir/im.patched.check.plist"
[[ ! -L "$plist" ]] || { printf 'Refusing symlink schedule file\n' >&2; exit 1; }
domain="gui/$(id -u)"
service="$domain/im.patched.check"
case "$action" in
    install)
        if ! "$custom"; then
            if ! /usr/bin/codesign --verify --strict "$app"; then
                printf 'Refusing schedule install: app signature is invalid at %s\n' "$app" >&2
                exit 1
            fi
            if ! bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist") || \
                [[ "$bundle_id" != im.patched.app ]]; then
                printf 'Refusing schedule install: CFBundleIdentifier must be im.patched.app.\n' >&2
                exit 1
            fi
            [[ -x "$app/Contents/Helpers/patched" ]] || { printf 'Packaged CLI not found at %s\n' "$app" >&2; exit 1; }
            mkdir -p "$target_dir" "$log_dir"
        fi
        temporary=$(mktemp "$target_dir/.im.patched.check.XXXXXX")
        trap 'rm -f "$temporary"' EXIT
        packaging_render "$PACKAGING_ROOT/packaging/im.patched.check.plist.template" "$temporary" \
            "CLI_PATH=$app/Contents/Helpers/patched" "LOG_DIR=$log_dir"
        chmod 644 "$temporary"
        mv -f "$temporary" "$plist"
        if ! "$custom"; then
            if /bin/launchctl print "$service" >/dev/null 2>&1; then /bin/launchctl bootout "$service"; fi
            /bin/launchctl bootstrap "$domain" "$plist"
        fi
        printf 'Schedule %s: %s\n' "$(if "$custom"; then printf rendered; else printf installed; fi)" "$plist"
        ;;
    remove)
        if ! "$custom" && /bin/launchctl print "$service" >/dev/null 2>&1; then /bin/launchctl bootout "$service"; fi
        rm -f "$plist"
        printf 'Removed schedule: %s\n' "$plist"
        ;;
    status)
        if [[ -f "$plist" ]]; then
            /usr/bin/plutil -lint "$plist"
            if ! "$custom"; then /bin/launchctl print "$service"; fi
            printf 'Schedule file: %s\n' "$plist"
        else
            printf 'Schedule is not installed: %s\n' "$plist"
        fi
        ;;
esac
