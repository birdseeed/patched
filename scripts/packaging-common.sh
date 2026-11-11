#!/bin/bash
# Shared local packaging helpers; source from the entry-point scripts.
PACKAGING_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

packaging_version() {
    PACKAGING_VERSION=$(cat "$PACKAGING_ROOT/VERSION")
    [[ "$PACKAGING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        printf 'VERSION must contain a numeric major.minor.patch version\n' >&2; return 1;
    }
}

# Outputs are build artifacts, never installation targets. Resolve symlinks before use.
packaging_output_dir() {
    local requested=$1 existing physical
    [[ "$requested" = /* ]] || requested="$PWD/$requested"
    # Restrict before mkdir as well, then check the physical directory below.
    case "$requested" in "$PACKAGING_ROOT"/*) ;; *) printf 'Output must be inside the repository\n' >&2; return 1;; esac
    case "/${requested#/}/" in */../*) printf 'Output may not contain .. components\n' >&2; return 1;; esac
    existing=$requested
    while [[ ! -d "$existing" ]]; do existing=$(dirname -- "$existing"); done
    physical=$(CDPATH= cd -- "$existing" && pwd -P)
    case "$physical" in "$PACKAGING_ROOT"|"$PACKAGING_ROOT"/*) ;; *) printf 'Output ancestor resolves outside the repository\n' >&2; return 1;; esac
    mkdir -p "$requested"
    PACKAGING_OUTPUT=$(CDPATH= cd -- "$requested" && pwd -P)
    case "$PACKAGING_OUTPUT" in "$PACKAGING_ROOT"/*) ;; *) printf 'Output resolves outside the repository\n' >&2; return 1;; esac
}

# Values come through argv/environment, never shell interpolation or executable code.
packaging_render() {
    local template=$1 output=$2
    shift 2
    env "$@" /usr/bin/perl -0777 -pe '
        sub xml { my ($s) = @_; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g;
            $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g; $s =~ s/\x27/&apos;/g; return $s; }
        s/\@([A-Z_]+)\@/exists $ENV{$1} ? xml($ENV{$1}) : die "Missing template value $1\n"/ge;
    ' "$template" > "$output"
    /usr/bin/plutil -lint "$output"
}

# The release Team ID a build pins its own updates to (Info.plist PatchedReleaseTeamID, read by self-update).
# Usage: packaging_check_release_team <team> <signing identity> <require: 0|1>
# An ad-hoc build (no signing identity) must have none: it could never accept its own future updates. With a
# signing identity it must be exactly ten upper-case letters or digits, and when <require> is 1 it must be set.
packaging_check_release_team() {
    local team=$1 signing=$2 require=$3
    if [[ -z "$signing" ]]; then
        [[ -z "$team" ]] || {
            printf 'RELEASE_TEAM_ID must be empty for an ad-hoc build (no SIGNING_IDENTITY): a pinned ad-hoc app could never accept its own updates.\n' >&2
            return 1; }
        return 0
    fi
    if [[ -z "$team" ]]; then
        [[ "$require" = 1 ]] || return 0
        printf 'SIGNING_IDENTITY requires RELEASE_TEAM_ID, the Team ID of that Developer ID certificate.\n' >&2
        return 1
    fi
    # Spelled out rather than A-Z, so no locale's collation can widen the range.
    [[ "$team" =~ ^[ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789]{10}$ ]] || {
        printf 'RELEASE_TEAM_ID must be exactly ten upper-case letters or digits.\n' >&2; return 1; }
}

# The signed app's certificate team (TeamIdentifier= in `codesign -dv`) must be exactly <team>.
# Usage: packaging_require_signing_team <app> <team>
packaging_require_signing_team() {
    local app=$1 team=$2 details actual
    details=$(/usr/bin/codesign -dv "$app" 2>&1) || { printf 'Could not read the code signature of %s.\n' "$app" >&2; return 1; }
    actual=$(/usr/bin/sed -n 's/^TeamIdentifier=//p' <<< "$details")
    [[ -n "$team" && "$actual" = "$team" ]] || {
        printf 'RELEASE_TEAM_ID %s does not match the team of the signing certificate (%s); refusing.\n' "$team" "${actual:-none}" >&2
        return 1; }
}

# The Developer ID requirement self-update checks a pinned release against, for <team>. Read from its single
# source, ReleaseTeamPin.requirementTemplate in Sources/UpdateInstaller/SelfUpdate.swift.
# Usage: packaging_release_requirement <team>
packaging_release_requirement() {
    local team=$1 template
    [[ "$team" =~ ^[ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789]{10}$ ]] || {
        printf 'RELEASE_TEAM_ID must be exactly ten upper-case letters or digits.\n' >&2; return 1; }
    template=$(/usr/bin/sed -n 's/^    public static let requirementTemplate = "\(.*\)"$/\1/p' \
        "$PACKAGING_ROOT/Sources/UpdateInstaller/SelfUpdate.swift")
    [[ "$template" = *'@IDENTIFIER@'*'@TEAM@'* ]] || {
        printf 'Could not read the release requirement from SelfUpdate.swift.\n' >&2; return 1; }
    printf '%s\n' "$template" | /usr/bin/sed -e 's/\\"/"/g' -e 's/@IDENTIFIER@/im.patched.app/g' -e "s/@TEAM@/$team/g"
}

# The signed (and notarised, stapled) app must satisfy that same requirement, so a certificate of the right team
# that is not Developer ID Application (for example Apple Development) is refused.
# Usage: packaging_require_release_requirement <app> <team>
packaging_require_release_requirement() {
    local app=$1 team=$2 requirement
    requirement=$(packaging_release_requirement "$team") || return 1
    /usr/bin/codesign --verify --strict --deep "-R=$requirement" "$app" > /dev/null 2>&1 || {
        printf 'The app does not satisfy the Developer ID release requirement that self-update checks (%s); refusing.\n' "$requirement" >&2
        return 1; }
}
