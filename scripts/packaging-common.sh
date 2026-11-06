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
