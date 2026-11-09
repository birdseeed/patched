# Admin updates probe runbook

> **Result so far (macOS 27, ad-hoc build):** the owner's GUI probe got macOS's prompt
> and `authorization granted`, but `replaceItemAt` failed with NSCocoaErrorDomain 512 /
> POSIX EIO for a root-owned folder and a root-owned file. Patched now reports that as
> `admin_replace_unavailable`. Steps 1 to 5 are kept for re-testing once there is a
> Developer ID build; step 6 (packages) does not depend on Patched's signing and uses
> its own switch. Step 6 passed on 9 November 2026 against DisplayLink 17.1 (Team
> 73YQY62QM3), so `.pkg` updates are now on by default; `PATCHED_ENABLE_PKG_UPDATES=0`
> turns them off.

Admin updates (root-owned apps and `.pkg` installers) are built but switched off
until this probe shows that macOS's own authorization works for Patched on this
Mac, which has only ad-hoc signing. The probe touches only a dummy bundle under
`/private/tmp/patched-admin-probe`. It never touches `/Applications`, a real app or
your `~/Library` state.

Do every step in Terminal **on the Mac itself**, not over SSH, because macOS has to
show its prompt on the screen.

## 0. Build

    cd ~/Development/mac-updater-admin
    swift build --product patched
    PATCHED=$PWD/.build/debug/patched

## 1. Create the dummy root-owned app

    sudo mkdir -p /private/tmp/patched-admin-probe/root/Fake.app/Contents
    echo "probe 1 (original)" | sudo tee /private/tmp/patched-admin-probe/root/Fake.app/Contents/version.txt >/dev/null
    sudo chown -R root:wheel /private/tmp/patched-admin-probe
    sudo chmod -R u+rwX,go-w /private/tmp/patched-admin-probe
    ls -lR /private/tmp/patched-admin-probe

Every entry should be owned by `root wheel` and not group- or world-writable. The
probe refuses to run otherwise, and it only ever targets
`/private/tmp/patched-admin-probe/root/Fake.app`.

## 2. Check that admin replacement is off by default

    $PATCHED admin-probe

Expected: `admin-probe needs --enable-admin-updates or PATCHED_ENABLE_ADMIN_UPDATES=1`,
exit 2, and no prompt.

## 3. Decline once

    $PATCHED admin-probe --enable-admin-updates

When macOS asks for an administrator's password or Touch ID, choose **Cancel**.
Expected: `PROBE REFUSED: admin_denied: ...`, and the "after" line still says
`probe 1 (original)` and `uid 0`.

## 4. Allow once

    $PATCHED admin-probe --enable-admin-updates

Approve the prompt. With today's ad-hoc build, expect `PROBE REFUSED:
admin_replace_unavailable` and an unchanged target. With a Developer ID build, expect:

    after: /private/tmp/patched-admin-probe/root/Fake.app says "probe 2 (replaced by patched admin-probe)", uid ...
    PROBE OK: the admin replacement works here.

Note down:
- the exact prompt text and which app it names (`patched`, Terminal, or something else);
- how many prompts appeared (one is expected);
- the owner shown in the "after" line (root, or your uid?). That tells us who owns an app after an admin update;
- whether "replacement still at the staging path" is `no` (macOS moved it) or `yes` (it copied).

## 5. Compare with the orchestrator's GUI probe

The orchestrator prepared a small GUI probe app that makes the same calls from an
`NSApplication`:

    /private/tmp/claude-501/-Users-andybridson-Development/c6e254ca-213f-4635-bb4d-d24e69057d29/scratchpad/authprobe/AuthProbe.app

It targets `/private/tmp/patched-auth-probe/root-dir/Fake.app`. Set that up the same way:

    sudo mkdir -p /private/tmp/patched-auth-probe/root-dir/Fake.app/Contents
    echo "old" | sudo tee /private/tmp/patched-auth-probe/root-dir/Fake.app/Contents/version.txt >/dev/null
    sudo chown -R root:wheel /private/tmp/patched-auth-probe/root-dir
    sudo chown "$USER" /private/tmp/patched-auth-probe
    open /private/tmp/claude-501/-Users-andybridson-Development/c6e254ca-213f-4635-bb4d-d24e69057d29/scratchpad/authprobe/AuthProbe.app
    cat /private/tmp/patched-auth-probe/probe-result.txt

(The probe writes its log and staging folder in `/private/tmp/patched-auth-probe`, so
that folder must be yours, while `root-dir` stays root-owned.) If the GUI probe works
but step 4 does not, the admin path should be used from the app only, and the CLI
should refuse it.

## 6. Check the package parser on a real vendor package (read-only)

Download one notarised `.pkg` from a vendor you trust into a new, empty folder,
then read its Team ID and run the checks. Nothing is installed.

    mkdir -p ~/Downloads/pkg-probe && cd ~/Downloads/pkg-probe
    # put the vendor's .pkg here, then:
    /usr/sbin/pkgutil --check-signature Vendor.pkg
    $PATCHED admin-probe --enable-pkg-updates --package "$PWD/Vendor.pkg" --team <TEAMID from the line "Developer ID Installer: ... (TEAMID)">
    $PATCHED admin-probe --enable-pkg-updates --package "$PWD/Vendor.pkg" --team AAAAAAAAAA

Expected: `PACKAGE OK` for the right Team ID and `PACKAGE REFUSED: package_signature_invalid`
for `AAAAAAAAAA`. The probe prints the raw `pkgutil` and `spctl` output; please send
it, so `Fixtures/PackageSignature/pkgutil-developer-id.txt` can be checked against a
real package. If the right Team ID is refused, that output shows which line the
strict parser did not recognise.

## 7. The app

The app reads the same switches from its environment. `.pkg` updates are on unless
`PATCHED_ENABLE_PKG_UPDATES=0`; admin replacement is only on when started from
Terminal with its switch set:

    swift build --product PatchedApp
    .build/debug/PatchedApp                                  # .pkg updates are on by default
    PATCHED_ENABLE_ADMIN_UPDATES=1 .build/debug/PatchedApp   # replacement; fails with EIO on ad-hoc builds

A `.pkg` update shows "Update (installer)". With the admin switch on, an app that
needs admin rights shows "Update (admin)" after its first Update attempt (or after
Update All skips it). Started from Finder or at login, admin replacement is off.

## 8. Clean up

    sudo rm -rf /private/tmp/patched-admin-probe /private/tmp/patched-auth-probe

## What not to do yet

- Do not set `PATCHED_ENABLE_ADMIN_UPDATES=1` for everyday use until steps 3 to 5
  have passed and been reviewed.
- Do not run the probe over SSH; it should refuse with `needs_interactive_admin`
  (trying that once is a useful extra check).
