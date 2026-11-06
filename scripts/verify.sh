#!/bin/bash
# Single local gate for Patched. Run from anywhere; it cd's to the repo root.
set -euo pipefail
# Tests must never touch the owner's real state (Library folders, catalogue, caches).
export PATCHED_FORBID_REAL_STATE=1
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"

# Cap any single long command so nothing hangs the gate.
cap() { perl -e 'alarm 900; exec @ARGV' -- "$@"; }
step() { printf '\n==> %s\n' "$*"; }
run() { step "$*"; cap "$@"; }

run swift build

# Swift check executables (already built above).
run swift run --skip-build patched-shell-checks
run swift run --skip-build patched-client-checks
run swift run --skip-build patched-app-updates-checks
run swift run --skip-build update-sources-checks
run swift run --skip-build update-installer-checks
# Read-only check of the real code-signing verifier against installed third-party apps. It only reads
# /Applications signatures (copies go to a temp folder), so it runs on its own with the tripwire lifted.
run env -u PATCHED_FORBID_REAL_STATE PATCHED_RUN_INSTALLED_APP_CHECKS=1 swift run --skip-build update-installer-checks --real-verifier-only

# This independent guard ships with the public tree, alongside its Node requirement.
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) { console.error("Node >=22 required"); process.exit(1); }'
run node Tests/NoLipoSourceGuard.mjs

# The private discovery reference is optional; a present tree must pass in full.
if [[ -d reference ]]; then
    step "catalogue protocol swift vectors"
    mkdir -p .build/catalogue-protocol-module-cache
    cap swift -module-cache-path .build/catalogue-protocol-module-cache \
        reference/catalogue/protocol-vectors.swift > .build/catalogue-protocol-swift-vectors.json
    run node --test reference/catalogue/tests/
else
    printf 'Reference catalogue absent; private reference checks skipped.\n'
fi

step "git diff --check"
git diff --check

run /bin/bash scripts/verify-packaging.sh
printf '\nverify.sh: all checks passed\n'
