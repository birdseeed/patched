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

Create a local release archive, checksum and signature with:

```sh
/bin/bash scripts/release.sh
(cd dist && shasum -a 256 -c Patched-0.2.2.zip.sha256)
(cd dist && shasum -a 256 -c Patched-0.2.2.dmg.sha256)
```

This produces `dist/Patched-<version>.zip`, `.zip.sha256` and `.zip.sig`, and a
disk image `dist/Patched-<version>.dmg` with `.dmg.sha256`. It does not publish
anything. The archive keeps the outer `Patched.app` directory.

The disk image is for first installs and Homebrew: a compressed read-only (UDZO)
image, volume name "Patched", holding the same final `Patched.app` as the zip (the
stapled app, when notarised) and an `Applications` link to `/Applications`, so the
app can be dragged across. There is no background image or window layout. It is
made with `hdiutil` from a folder in the release stage under `.build`. With
`SIGNING_IDENTITY` the image itself is signed with that identity and a timestamp,
its certificate team must equal `RELEASE_TEAM_ID` and its Authority must be
Developer ID Application, and with `NOTARY_PROFILE` it is notarised (status
`Accepted` required, as for the zip), stapled and validated. Every image is then
attached read-only in the stage: the app on it must verify strictly, be version
`VERSION` and, when a Team ID is pinned, satisfy the same release requirement as
the zip's app. It is always detached again, also when a step fails. An ad-hoc
build gets an unsigned, unnotarised image. Self-update never uses the disk image;
it accepts only the Ed25519-signed zip. Every step happens in the stage before
anything is moved into the output folder, and a `.sig`, `.dmg` or `.dmg.sha256`
left by an earlier build is removed before the new files are moved in.

The `.sig` is Patched's self-update anchor: an Ed25519 signature over the final zip
bytes, as one line of base64 (64 bytes). The private key is a generic password in
the login Keychain, service `im.patched.release-signing`, account `ed25519`, holding
the base64 raw 32-byte `Curve25519.Signing` private key. Before building, the script
checks only that the item exists, and refuses to produce release artifacts if it is
missing. After the zip is final it compiles `scripts/release-signing.swift`, pipes the
key from `security find-generic-password -w` straight into it (the key is never in a
variable, argument, file or log), writes the `.sig`, and verifies it against the
public key built into Patched (`PatchedReleaseKey.publicKeyBase64` in
`Sources/UpdateInstaller/SelfUpdate.swift`). A signature that does not verify
against that key stops the release. macOS may ask to allow `security` to read the
item.

`--unsigned-for-testing` builds the zip, the disk image and their checksums without
the Keychain, without a `.sig` and with an unsigned image; Patched never installs
such a zip. For the packaging checks only,
`PATCHED_RELEASE_KEY_SERVICE` and `PATCHED_RELEASE_KEYCHAIN` point at a throwaway key
in a throwaway keychain, and `PATCHED_RELEASE_PUBLIC_KEY_OVERRIDE` names its public
key; the override is refused for the real service. Upload all five files to the
GitHub release: the app accepts only assets named exactly `Patched-<version>.zip`
and `Patched-<version>.zip.sig` on that release, and the disk image is for people
installing by hand or through Homebrew. Later, with an
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
existing keychain profile. Notarised or not, every release zip is also signed with
the release key as above.

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
fails before creating output artifacts. They also check release signing with a
throwaway key in a throwaway keychain: a missing key is refused before building, a
key that is not the one built into Patched is refused after signing with no zip
left behind, the public-key override is refused for the real service, a signed
release's `.sig` verifies with the throwaway key and not with the real one or over
a changed zip, and `--unsigned-for-testing` produces no `.sig`. For both the
throwaway-key and unsigned releases they check the disk image: its checksum, UDZO
format, volume name, exactly `Patched.app` and an `Applications` link to
`/Applications` when mounted, the app's version and `codesign --verify --strict
--deep`; a stale image and a checksum symlink from an earlier build are replaced,
and a refused release leaves no image behind. The owner's real
Keychain item is never read. Verification never uses notarisation
credentials or installs the app or a real LaunchAgent.
