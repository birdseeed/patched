# Patched

Patched is a free, open-source Mac app updater. It is a community project with no
company or support behind it. The source is licensed under the
Apache License 2.0. Copyright © 2026 Andy Bridson. See [LICENSE](LICENSE) and [NOTICE](NOTICE), including the
Installomator attribution.

Patched checks installed apps for updates, obtains update information from
configured sources, verifies downloaded apps, and is designed to replace an app
with a recoverable transaction. Its Swift package requires Swift 6 and macOS 13
or later.

<!-- Raw HTML so the 2x screenshots display at their natural size; these paths are
     relative to the repository root, where the export promotes this file. -->
<p><img src="docs/images/patched-updates.png" width="760" alt="The Patched Updates screen, listing installed apps with version, update source and status, and an Update button for Google Chrome"></p>
<p>
<img src="docs/images/patched-menu.png" width="320" alt="The Patched menu bar menu, showing two updates available and an Update All button">
<img src="docs/images/patched-applications.png" width="430" alt="The Applications screen filtered to apps with updates">
</p>

## Requirements

Patched needs a Mac with Apple silicon running macOS 13 or later. Intel Macs are
not supported. Building from source needs Swift 6.

## Download

Releases are on [GitHub Releases](https://github.com/birdseeed/patched/releases).
From 0.1.7, releases are signed with my Developer ID (Team ID `Y9352JY7U8`) and
notarised by Apple, so they open normally the first time; see
[Install a release](#install-a-release).

## Build from source

On macOS with Swift 6 installed, build with:

```sh
swift build
/bin/bash scripts/build-app.sh
open dist/Patched.app
swift run patched check
```

The app bundle includes the `patched` CLI. The final command runs a read-only
check directly from the source tree. See [packaging/README.md](packaging/README.md)
for local packaging options.

For contributors, `./scripts/verify.sh` runs the complete local build and checks.
The gate requires Node 22 or later for an independent source guard. Private
reference catalogue checks run only when their reference tree is present; the
public source tree contains everything needed for its own gate.

## Using the app

The Updates screen provides **Update**, **Update All**, **Roll back** and
**Recover**. Roll back puts the previous version of the app bundle back; it does not
touch the app's data (Application Support, its container, preferences), so if the
newer version migrated that data on first launch, the older one may not read it.
Roll back is most reliable straight after an update; for data, use Time Machine. Patched checks when it opens and every three hours while it runs
(a recent check within ten minutes suppresses the opening check). Scheduled
checks only report available updates and notify you; they do not install them, unless you switch on
**Install updates automatically** in Settings (off by default, once a day at a time you choose, within 6 hours of it and not past midnight; see [Automatic updates at a set time](#automatic-updates-at-a-set-time)).
Use **Open at login** in Settings to have the installed app start when you log in.
Settings also shows whether notifications are on, with a button to open macOS
Notification Settings.

Mac App Store apps are reported but never installed by Patched: it asks Apple's public App Store lookup for the latest version (only the bundle IDs of your App Store apps are sent, and only to Apple; hide an app on the Applications screen, or ignore it in the catalogue, to stop that) and tells you to update it in the App Store.

Patched includes update feeds for a few apps that don't publish their own (ChatGPT and Ghostty); an entry in your own `catalogue.json` for the same app overrides them.

Patched also tells you when a newer Patched release exists. On the same schedule (when it opens, every three hours and on Check Now) it makes a single anonymous request to GitHub for the latest release of this repository (`api.github.com/repos/birdseeed/patched/releases/latest`). The request carries no identifying data beyond a plain `Patched/<version>` User-Agent. If the release is newer than the app you are running, the menu and the Updates screen show "Patched 0.2.0 is available" with a **Download** button, and you get one notification per new version. Download opens that release's page on GitHub in your browser, only when you click it.

Patched can also update itself, but only when you ask. Next to **Download** there is an **Update** button (and an **Update…** button on the notification). It asks "Update Patched to 0.2.0? Patched will quit and reopen." and does nothing until you confirm. Then it downloads that release's ZIP from GitHub, checks it against an Ed25519 signature made with my release key (the public half is built into Patched), checks the new app's bundle ID, version and code signature, swaps it in for the running Patched, keeps the previous version as a backup, and reopens. If any check fails, the installed Patched is left as it was. If replacing Patched would need administrator rights, it opens the release page instead. Scheduled checks, Update All and the command line never install Patched.

If you have Patched 0.1.2 or earlier, install 0.1.3 by hand once (see [Install a release](#install-a-release)); from then on Patched offers in-app updates.

Patched keeps its update state and backups in
`~/Library/Application Support/Patched/Updater`, and its cache in
`~/Library/Caches/Patched/Updater`. First use migrates legacy `mac-updater`
state without overwriting an existing destination. An unfinished transaction
must be recovered before migration can finish. See
[THREAT-MODEL.md](THREAT-MODEL.md) for migration and recovery details.

## Automatic updates at a set time

Off by default. "Install updates automatically", in first-run setup and in Settings (the
same setting), installs updates once a day at a time you choose (02:00 unless you change it). It is the one exception to "nothing installs
until you choose Update", and it only happens if you switch it on.

It installs what Update All installs: updates to apps you can replace without admin rights,
rechecked just before each install with every usual check. It never installs installer
packages, apps that need admin rights, Patched itself, hidden apps or Mac App Store apps. It
never quits an app: open apps are skipped, listed in the summary and still offered on the
Updates screen. It runs at the first check at or after the chosen time, at most once a day.
If the Mac was asleep or Patched was not running, it still runs at the first check within
6 hours of that time, and not past midnight (a 23:00 setting has one hour), otherwise it waits
for the next day. It does not wake the Mac. It waits while an install, roll back or recovery
is running, while installing is blocked or a question is open, and skips a check that mostly
failed offline. Updates it leaves out are announced in the usual "updates available"
notification. You get one summary notification, only when something was updated, failed or
was skipped because the app was open. Roll back works as for any update.

An organisation sets this with a configuration profile that manages the `im.patched.app`
preference domain (managed preferences). A minimal payload, with a placeholder UUID to replace:

    <dict>
      <key>PayloadType</key><string>com.apple.ManagedClient.preferences</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadIdentifier</key><string>com.example.patched.automatic-updates</string>
      <key>PayloadUUID</key><string>00000000-0000-0000-0000-000000000000</string>
      <key>PayloadContent</key>
      <dict>
        <key>im.patched.app</key>
        <dict>
          <key>Forced</key>
          <array><dict>
            <key>mcx_preference_settings</key>
            <dict>
              <key>AutomaticUpdatesEnabled</key><true/>
              <key>AutomaticUpdatesTime</key><string>02:00</string>
            </dict>
          </dict></array>
        </dict>
      </dict>
    </dict>

Writing to `/Library/Managed Preferences` by hand is for testing only.

| Key | Type | Meaning |
| --- | --- | --- |
| `AutomaticUpdatesEnabled` | Boolean | `true` turns it on, `false` turns it off. |
| `AutomaticUpdatesTime` | String | Time of day as `HH:mm`, 24-hour, for example `02:00`. |

A managed value locks that control in Settings with "Set by your organisation". A value of the
wrong type is not used. For `AutomaticUpdatesEnabled` that fails closed: automatic updates
are off and locked, and Settings says so. A time that is not exactly `HH:mm` (`2:00`, `24:00`
and `02:00:00` are all refused) is ignored: the user's own time, or 02:00, applies and Settings
says a managed value was ignored. Only values that are forced count, so a plain user default never locks anything.
See `THREAT-MODEL.md`, "Automatic updates".

## Self Service

For organisations: a catalogue of approved apps that people can install for themselves, without
admin rights, into `~/Applications`. When a catalogue is set on a Mac, an **Available** screen
appears in the sidebar. It lists the apps not yet installed, with a search field and a category
filter, and an Install button on each row that can be installed. Installing shows the same
progress, Cancel and result text as Updates. The catalogue is read when the window opens or
Available is shown. An entry that needs admin rights is greyed out with its reason, and an invalid entry says
why it is invalid. With no catalogue, the screen is not shown. Once installed, an app appears in
Updates like any other. `patched catalogue list` shows the catalogue on this Mac and whether each
entry is valid.

The catalogue is a managed preference, `SelfServiceCatalogue` for `im.patched.app`, set by a
configuration profile from your MDM. Only a forced value counts, so a user cannot add to it. It
is an array of dictionaries, at most 500 entries:

| Key | Type | Meaning |
| --- | --- | --- |
| `Name` | String | Required. The name people see, up to 128 characters. |
| `TeamID` | String | Required. The developer's Apple Team ID (ten capital letters or digits). The download must be signed by this team. |
| `SparkleFeedURL` | String | The app's Sparkle appcast, https only, with no user name or password in it. |
| `HomebrewCask` | String | A Homebrew cask token, for example `firefox`. Give exactly one of `SparkleFeedURL` and `HomebrewCask`. |
| `BundleID` | String | Optional, but give it for every entry. The installed app must have exactly this bundle ID. Without it, any app signed and notarised by the entry's Team ID is accepted, and the download must hold exactly one app. `patched catalogue list` warns about entries without one. |
| `Description` | String | Optional, up to 512 characters. |
| `Category` | String | Optional, up to 64 characters, for filtering. |
| `NeedsAdmin` | Boolean | Optional. `true` shows the app greyed out ("needs admin rights") and never installs it. |

Each entry is checked on its own. One with a missing or misspelt key, a value of the wrong type, a
Team ID that is not valid, an `http` feed or a bad cask token is shown as invalid with the reason,
and the rest still work. A value that is not an array, or more than 500 entries, means no catalogue
at all. Nothing is fetched until someone chooses Install. Only zip and dmg downloads are supported;
installer packages are refused. Patched never overwrites anything already in `~/Applications`.

The feed or cask decides which build is offered, and nothing is installed yet to compare it with,
so a feed can offer any build the developer signed and notarised, including an older one. Use
feeds you trust as much as the developer. See `THREAT-MODEL.md`, "Self Service".

A minimal payload, with placeholder UUIDs and a placeholder Team ID to replace:

    <dict>
      <key>PayloadType</key><string>com.apple.ManagedClient.preferences</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadIdentifier</key><string>com.example.patched.self-service</string>
      <key>PayloadUUID</key><string>00000000-0000-0000-0000-000000000001</string>
      <key>PayloadContent</key>
      <dict>
        <key>im.patched.app</key>
        <dict>
          <key>Forced</key>
          <array><dict>
            <key>mcx_preference_settings</key>
            <dict>
              <key>SelfServiceCatalogue</key>
              <array>
                <dict>
                  <key>Name</key><string>Example Notes</string>
                  <key>Description</key><string>Shared team notes</string>
                  <key>Category</key><string>Productivity</string>
                  <key>TeamID</key><string>ABCDE12345</string>
                  <key>BundleID</key><string>com.example.notes</string>
                  <key>SparkleFeedURL</key><string>https://example.com/notes/appcast.xml</string>
                </dict>
                <dict>
                  <key>Name</key><string>Example Browser</string>
                  <key>TeamID</key><string>ABCDE12345</string>
                  <key>BundleID</key><string>com.example.browser</string>
                  <key>HomebrewCask</key><string>example-browser</string>
                </dict>
              </array>
            </dict>
          </dict></array>
        </dict>
      </dict>
    </dict>

The payload goes inside a configuration profile (top-level `PayloadType` `Configuration`, with its
own placeholder UUID, for example `00000000-0000-0000-0000-000000000002`). After installing the
profile, run `patched catalogue list` to check it. See `THREAT-MODEL.md`, "Self Service".

## Install a release

Releases are for Apple silicon. From 0.1.7 they are signed with my Developer ID
Application certificate (Team ID `Y9352JY7U8`), notarised by Apple and stapled.

The easiest install is the disk image: download `Patched-<version>.dmg` from
[GitHub Releases](https://github.com/birdseeed/patched/releases), open it and drag
Patched to Applications. Check its SHA-256 against the one in the release notes
first if you like (`shasum -a 256 Patched-0.1.7.dmg`).

With Homebrew:

```sh
brew trust birdseeed/patched
brew install --cask birdseeed/patched/patched
```

Homebrew only loads casks from taps you have chosen to trust, so the first command is needed once.

The ZIP is still there for manual installs, and it is what Patched uses to update
itself: download it, check its SHA-256 (`shasum -a 256 Patched-0.1.7.zip`), extract
it, then move the included Patched app to your Applications folder. Either way it
opens without any Gatekeeper prompt beyond the usual "downloaded from the internet"
question.

Releases up to 0.1.6 were ad-hoc signed and not notarised. If you install one of
those, macOS may block it: check that you trust the source, then use System
Settings → Privacy & Security → Open Anyway for that specific app. Do not disable
Gatekeeper or lower system security globally.

Each release also has a `Patched-<version>.zip.sig` file: the Ed25519 signature
Patched checks before it updates itself, made with my release key. From 0.1.7,
Patched also requires its own updates to be signed by Team ID `Y9352JY7U8` and
notarised, so a release needs both the release key and the Developer ID. Patched
never updates itself from the disk image.

## Command-line interface

The command is `patched`. The supported command shapes are:

```text
patched check [--json] [--app <path>] [--explain <app path | bundle ID>]
patched update <app path | bundle ID> [--quit] [--dry-run] [--json]
patched update --all [--quit] [--dry-run] [--json]
patched rollback <app path | bundle ID> [--quit]
patched recover [--quit]
patched backups
patched catalogue list
```

`check` is read-only. `catalogue list` shows the Self Service catalogue set on this Mac
and whether each entry is valid. `--dry-run` downloads and verifies an update in a staging
folder, then cleans it up without installing. `--quit` asks a running app to
quit; it is not force-killed. The updater refuses to replace apps that require
administrator privileges; use the app's own updater for those. A `.pkg` update
is verified (hash, the installed app's Developer ID Installer Team ID and
notarisation) and then opened in Apple's Installer, where you finish it with
your own password. Roll back isn't supported after a `.pkg` update, because a
package can install more than the app. Set `PATCHED_ENABLE_PKG_UPDATES=0` to
turn `.pkg` updates off.

## What update verification checks

For an update, Patched uses the installed app's signed Team ID as its identity
pin. It requires HTTPS, including redirects, streams downloads into a private
folder, applies a size limit, and checks available feed length and SHA-256 or
SHA-512 hashes. When an installed app supplies a Sparkle EdDSA public key, the
download must also have a valid EdDSA signature.

The candidate app must have the same bundle ID, contain no symlinks escaping the
app, pass strict code-signature checks, use the pinned Team ID, pass Apple's
notarisation assessment, and have the offered version newer than the installed
version. After replacement, Patched checks the installed app again. It keeps a
backup, supports rollback, and records a journal for crash recovery. Rollback
applies the same signature, Team ID, and notarisation checks before restoring a
backup. Checks fail closed when a safe state cannot be established.

These checks do not protect against malware already running as your user, or a
developer's compromised signing key or update server. A valid update signed by
the expected Team ID can still be malicious.

## Support

This is a community project without company-backed support. If you find a
problem, see [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
If Patched saves you time, you can [buy me a coffee](https://buymeacoffee.com/andybridson).
Donations help pay for the Apple Developer membership that signs and notarises releases.
