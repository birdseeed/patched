# Local app packaging

Run these commands from the repository root on macOS 13 or later with Apple's
command line developer tools installed. The package uses only the Apple SDK and
has no external Swift package dependencies.

```sh
swift build
/bin/bash scripts/build-app.sh
open dist/Patched.app
```

The default configuration is release, with optimized binaries and no separate
dSYM debug-symbol artifacts (`-debug-info-format none`). `--configuration debug`
provides a faster, debuggable local build. `--universal` builds both arm64 and x86_64 with SwiftPM's `--arch`
options. `--output-dir .build/packaging-example` changes the output directory;
output directories must be inside this repository. The app contains the
`PatchedApp` product as `Contents/MacOS/Patched` and the `patched` product as
`Contents/Helpers/patched`. `VERSION` supplies the display version and
`git rev-list --count HEAD` supplies the bundle build number. The copyright notice
is "Copyright © 2026 Andy Bridson".
Compiler module caches and tool temporary files, including universal debug-symbol
generation, stay under `.build/packaging-module-cache` and `.build/packaging-tmp`.

If an already confined agent environment cannot start SwiftPM's nested manifest
sandbox (`sandbox_apply: Operation not permitted`), prefix a build or verification
command with `PACKAGING_DISABLE_SWIFTPM_SANDBOX=1`. This passes the fixed
`--disable-sandbox` build option for that invocation only. Normal builds retain
SwiftPM's sandbox; the override does not change package dependencies or settings.

With no `SIGNING_IDENTITY`, the build uses an ad-hoc signature with hardened
runtime and no signing timestamp. This is a locally signed build, without an
Apple Developer ID certificate or notarisation. To open a downloaded archive,
unzip it and try opening Patched first. If macOS blocks it, go to System Settings
> Privacy & Security > Open Anyway, then confirm Open. Only do this for a copy
whose source you trust. Apple's current instructions are at
[Open a Mac app from an unknown developer](https://support.apple.com/en-gb/102445).

`Patched.entitlements` is deliberately an empty dictionary. There are no
entitlements to grant: the app uses normal user permissions to read and replace
apps the user can manage. App Sandbox is omitted because the updater must write
to `/Applications` using the current user's permissions. It does not request JIT,
unsigned executable
memory, disabled library validation or debugging permissions. Hardened runtime
is enabled by the `codesign --options runtime` flag on both the nested CLI and
the app; it is not an entitlement. The nested CLI is signed before its containing
app with the identifier `im.patched.cli`, and both signatures are verified strictly.
The runtime flag is `0x10000`; an ad-hoc signature also requires the `0x2` ad-hoc
bit, so its exact displayed flags are `0x10002(adhoc,runtime)`. The verifier accepts
only that combination or the certificate-signed `0x10000(runtime)` combination.

Create a local release archive and checksum with:

```sh
/bin/bash scripts/release.sh
(cd dist && shasum -a 256 -c Patched-0.1.1.zip.sha256)
```

This produces `dist/Patched-<version>.zip` and `.zip.sha256`. It does not publish
anything. The archive keeps the outer `Patched.app` directory. Later, with an
existing Developer ID Application identity and an existing notarytool keychain
profile, use exactly these environment variables:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-existing-notarytool-profile' \
  /bin/bash scripts/release.sh
```

`SIGNING_IDENTITY` can also be the certificate hash. The build signs with hardened
runtime and a timestamp whenever a signing identity is supplied. The release
script rejects a nonempty `NOTARY_PROFILE` without `SIGNING_IDENTITY` before
building. When notarisation is requested it also requires the resulting
signature's Authority to be Developer ID Application, then submits with
`xcrun notarytool submit --keychain-profile ... --wait --output-format json`.
Only a parsed status of `Accepted` permits stapling, validation, rebuilding the
zip and writing the checksum. A missing or rejected status aborts the release;
it never falls back to an unnotarised archive. Without `NOTARY_PROFILE`, it
creates a local zip without notarisation. Credentials stay in the
existing keychain profile. This packaging work does not enable self-update.

The command-line check schedule is optional and requires an explicit command:

```sh
/bin/bash scripts/schedule.sh install --app /Applications/Patched.app
/bin/bash scripts/schedule.sh status
/bin/bash scripts/schedule.sh remove
```

Install first verifies the app's code signature strictly and requires its bundle
identifier to be `im.patched.app`, before creating any LaunchAgent directories or
files. It then writes `~/Library/LaunchAgents/im.patched.check.plist` and bootstraps
it for the current login session. Every 3 hours (`StartInterval` 10800 seconds) it runs the packaged CLI with `check
--json`; it does not install updates. The app has its own in-app schedule (on open and every 3
hours while it runs) with notifications, so this agent is only for checks without the app open. Output and errors go to
`~/Library/Logs/Patched/check.log` and `check-error.log`. Launchd appends each
run's JSON output to `check.log`, so it contains multiple JSON documents over
time, not a single JSON document or a separate notification system. Removal
unloads the agent and removes its plist, leaving the logs available.

To keep these logs bounded, periodically (for example monthly) unload the
schedule, truncate the two existing regular log files, then reinstall it:

```sh
/bin/bash scripts/schedule.sh remove
for log_file in "$HOME/Library/Logs/Patched/check.log" "$HOME/Library/Logs/Patched/check-error.log"; do
  if [ -f "$log_file" ] && [ ! -L "$log_file" ]; then : > "$log_file"; fi
done
/bin/bash scripts/schedule.sh install --app /Applications/Patched.app
```

This discards previous log contents; afterwards the files retain only output
since truncation. Copy them elsewhere first if that history is needed. No
automatic rotation is installed.

To inspect a schedule safely, use `--target-dir .build/packaging-schedule` with
any of the three actions. This repository-only test mode renders, lints, reports
or removes that custom plist. It never runs launchctl or creates real log folders.
An arbitrary `--app` path is XML escaped, including spaces and special characters.
The automated gate uses this mode, checks the ad-hoc bundle and nested CLI,
checks usage without scanning applications, and verifies a local zip round trip:

```sh
/bin/bash scripts/verify-packaging.sh
```

The default gate builds for the host architecture. Add `--universal` to forward
the universal build option to both the app and release scripts and require
arm64 and x86_64 slices in both packaged executables and the extracted archive:

```sh
/bin/bash scripts/verify-packaging.sh --universal
```

Both modes require empty signed entitlements and the expected signing
identifiers, and check that a notarisation request without a signing identity
fails before creating output artifacts. Verification never uses notarisation
credentials or installs the app or a real LaunchAgent.
