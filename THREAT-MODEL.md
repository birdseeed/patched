# Patched threat model

This covers `patched update`, `rollback` and `recover` for apps the current
user can replace without admin rights, from zip and dmg downloads. `.pkg`
updates handed to Apple's Installer are on by default; replacing root-owned apps
is experimental and off by default. Both are described at the end.

## What is checked for every update

1. **The installed app is the identity pin.** It must be signed with a Team ID
   (ten capital letters or digits). Unsigned and ad-hoc apps are refused, because
   there is nothing to pin the update to.
2. **The download.** https only, including every redirect. It is streamed to a
   private folder, capped at 4 GiB, and must match the feed's length, SHA-256 and
   SHA-512 whenever the feed gives them.
3. **Sparkle EdDSA.** If the installed app has `SUPublicEDKey`, the update must
   carry an EdDSA signature that verifies over the downloaded bytes.
4. **Unpacking.** Only Apple's `ditto` and `hdiutil` are used, called by full
   path with no shell. Disk images are attached read-only, never shown in Finder,
   and a password or licence prompt fails instead of waiting. Unpacking needs free
   space in advance and is stopped if it grows past a size or file-count budget.
5. **The new app.** Exactly one app with the same bundle ID, and no symlinks that
   point outside it. Its code signature must be valid (strict, every architecture,
   nested code, revocation checked) and signed by the installed app's Team ID.
   Gatekeeper must accept it as notarised Developer ID software. Its version must
   be the one the feed offered and strictly newer than the installed one.
6. **After the swap.** The installed app is checked again (signature, Team ID,
   bundle ID, version and Gatekeeper) before the update counts as done, and again
   before the previous backup is deleted.

Rollback uses the same signature and Gatekeeper rules, so a backup that is not
notarised is refused.

Rollback restores the app bundle only. The app's data (Application Support, its
container, preferences, caches) is never copied or restored, so data a newer version
migrated on first launch stays migrated, and the older version may not be able to read
it. The app, the CLI result and the README say so; Time Machine remains the way to
restore data.

## What the tool trusts

- TLS and the system's certificate store, for downloads.
- Apple's code signing, revocation and notarisation services, through the
  Security framework and `spctl`.
- The Team ID in the installed app's signature, as the publisher's identity.
- Sparkle EdDSA public keys shipped inside installed apps.
- The update feeds (Sparkle, Electron, Homebrew), but only to say where to
  download from. Everything they say is checked against the above.
- The built-in feed list (a few Sparkle feeds compiled into Patched, for apps that
  pin a Sparkle key but set their feed at runtime). An entry only locates a feed:
  the Team ID and the app's EdDSA key are still enforced, so a wrong or hostile
  entry cannot install anything the app's own pins reject.
- Apple's public App Store lookup (https, size-capped, strictly parsed), only to
  report a newer version of a Mac App Store app. It sends those apps' bundle IDs to
  Apple and nobody else, and its answer can never install anything (`app_store_managed`).
- GitHub's latest-release record for this repository (https, 256 KB cap), to say
  that a newer Patched exists and where its signed zip is. It is untrusted metadata:
  only `tag_name`, `html_url`, `draft`, `prerelease` and each asset's `name` and
  `browser_download_url` are read; the tag must be digits and dots, `html_url` must
  be exactly this repository's release page for that same tag, and drafts and
  prereleases are ignored. An asset counts only if it is named exactly
  `Patched-<version>.zip` or `Patched-<version>.zip.sig`, appears once, and its URL
  is exactly `https://github.com/birdseeed/patched/releases/download/<tag>/<name>`;
  otherwise the release stays notify-only. The request is a single anonymous GET
  with a plain `Patched/<version>` User-Agent and no user data. The result is shown
  as "Patched X is available"; a direct click on Download opens that validated page
  in the browser, and a direct, confirmed click on Update installs the release as
  described in "Patched updating itself" below. Nothing is downloaded, installed or
  opened automatically, and Patched's own row is never part of Update All.
- Patched's own Ed25519 release key, for Patched's own updates only (below).

## Patched updating itself

Releases up to and including 0.1.6 are ad-hoc signed, with no Team ID to pin and
nothing for Gatekeeper to accept as notarised; from 0.1.7 releases are signed with a
Developer ID Application certificate and notarised. The rules in "What is checked
for every update" would refuse Patched itself, and still do (the normal installer
never touches Patched). Self-update is a separate path with two trust anchors:
Patched's own Ed25519 release key, always, and the release Team ID pinned in the
running app, when it has one.

**The release Team ID pin.** `scripts/build-app.sh` writes `RELEASE_TEAM_ID` into the
app's Info.plist as `PatchedReleaseTeamID` (empty when unset), where the app's code
signature covers it. Self-update reads the pin from the running app's own bundle
(`Bundle.main`), never from the download.

- Empty (ad-hoc and development builds, and every release up to 0.1.6): self-update
  relies on the release key alone, as before. This is how 0.1.6 accepts 0.1.7.
- Ten capital letters or digits (Developer ID releases, from 0.1.7): the new app must
  also satisfy, through the Security framework (strict, every architecture, nested
  code, revocation checked), the requirement `identifier "im.patched.app" and anchor
  apple generic and certificate leaf[subject.OU] = "<TEAM>" and certificate
  1[field.1.2.840.113635.100.6.2.6] exists and certificate
  leaf[field.1.2.840.113635.100.6.1.13] exists and notarized`, that is Apple's
  anchor, the Developer ID intermediate, a Developer ID Application leaf for exactly
  that team and a notarisation ticket, and its signing information must name the
  same team and identifier. Its own Info.plist must pin the same team, so a release
  cannot drop or change the pin. An ad-hoc, other-team, non-Developer-ID or
  unnotarised download is refused (`release_team_mismatch`) even when its zip carries
  a valid release signature, so from 0.1.7 the release key alone is no longer enough.
  A revoked certificate or notarisation is refused as revoked; when the revocation
  check cannot reach Apple (OCSP or network unavailable) the update is refused with
  a "check your connection and try again" message. The requirement string has one
  source, `ReleaseTeamPin.requirementTemplate`.
- Anything else (lower case, wrong length, quotes, not text): every self-update is
  refused (`cannot_pin_identity`) before anything is downloaded. A damaged pin is never
  treated as "no pin", and the Team ID is validated before it is put in the requirement,
  so nothing can be injected.

`scripts/release.sh` refuses a pin on an ad-hoc build (such an app could never accept
its own next update), and with `SIGNING_IDENTITY` requires `NOTARY_PROFILE` and
`RELEASE_TEAM_ID` (ten capital letters or digits), the built Info.plist to carry it,
`TeamIdentifier=` in `codesign -dv` of the built app (the certificate actually used,
even when the identity is given by hash) to equal it, and, after stapling and before
any zip or signature is written, `codesign --verify --strict --deep` against the same
requirement string, read from `SelfUpdate.swift`, so a certificate of the right team
that is not Developer ID Application (Apple Development, say) is refused. `build-app.sh` makes the same format, ad-hoc and
certificate checks.

**Signing.** `scripts/release.sh` signs the final zip bytes with the private key,
which lives only in the owner's login Keychain (generic password, service
`im.patched.release-signing`, account `ed25519`). The key goes from `security` straight
into the signer's stdin; it is never in an argument, a file or the log. The script
then verifies the `.sig` against the public key built into Patched
(`PatchedReleaseKey` in `Sources/UpdateInstaller/SelfUpdate.swift`) and refuses to
produce release files if the key is missing or the signature does not verify. The
packaging checks use a throwaway key in a throwaway keychain.

**The disk image.** Each release also has `Patched-<version>.dmg`, for first installs
and Homebrew. It holds the same stapled app as the zip, and the image itself is
signed with the Developer ID Application certificate, notarised and stapled;
`release.sh` checks the image's team and the app on it against the same requirement
before publishing. Self-update never uses it: it still requires the Ed25519-signed
zip and, when pinned, the release Team ID.

**When it runs.** Only from a click on Update beside "Patched X is available" (menu
or Updates screen) or on the self-update notification's Update… button, and then
only after a second click on the confirmation ("Update Patched to X? Patched will
quit and reopen."). The notification button only brings up that confirmation.
Scheduled checks, Update All and the command line (including `--all`) have no path
to it. It is offered only in an installed `Patched.app` whose bundle ID is
`im.patched.app`, and only while nothing else is checking or installing.

**What is checked, in order.** Any failure stops the update and leaves the
installed Patched exactly as it was:

1. The asset URLs are the exact GitHub release URLs above, and the release version
   is strictly newer than the running version.
2. The running bundle is a real, non-symlinked `Patched.app` that the user can
   replace (owned by the user, writable, folder writable, no immutable flags, not
   App Translocated). Otherwise it is refused as needing admin rights and the
   release page is opened instead.
3. Download, https only. The first URL and every redirect must be on
   `github.com`, `release-assets.githubusercontent.com` (where GitHub redirected
   release assets on 9 November 2026) or `objects.githubusercontent.com` (where it
   redirected them before). The zip is capped at 64 MiB and the signature at 1 KB,
   both streamed into a private 0700 folder beside the app.
4. The Ed25519 signature over the zip bytes must verify against the key built into
   Patched. A missing, malformed or wrong signature, a wrong key or a changed zip is
   refused before anything is unpacked.
5. The zip is unpacked with `ditto` under a small disk budget, and exactly one
   `.app` with bundle ID `im.patched.app`, with no symlink leaving it, is chosen.
6. The staged app's `CFBundleShortVersionString` must equal the release version
   exactly and be strictly newer than the running and installed versions, so an
   older, genuinely signed zip cannot be replayed under a newer tag.
7. `codesign --verify --strict --deep` with the requirement `identifier
   "im.patched.app"` must pass. When the running app pins a release Team ID, the
   Developer ID requirement above (which includes notarisation) must pass too, and
   the new app must pin the same team; with no pin there is no Team ID check, and
   the release signature is what vouches for the build. There is no `spctl`
   Gatekeeper assessment on this path.
8. Any quarantine flag is removed from the staged app (it has already been
   verified), so macOS opens the new build.
9. One atomic `renamex_np` swap with the running bundle. The installed app is
   checked again (identity, bundle ID, version, codesign and, when pinned, the
   Developer ID team); if that fails, the old app is swapped back. The previous version is moved to
   `~/Library/Application Support/Patched/Updater/backups/im.patched.app` and kept
   until the next self-update.
10. The new Patched is opened with `/usr/bin/open -n` and waits (at most 15 seconds)
    for the old process to exit before it touches any state; the old one then quits.
    If it cannot be opened, Patched says the update is installed and keeps running.

There is no journal for this path: before the swap nothing is changed, the swap is a
single rename, and after it the worst case is the previous version left in a hidden
`.patched-self-update-*` folder beside the app.

**What a stolen key or GitHub account means.** For an unpinned Patched (0.1.6 and
earlier) the release key is the whole trust anchor. Someone with the private key and
a way to serve a newer release (the GitHub account, or the repository) can make every
such copy of Patched that clicks Update install their code as the user, with the
user's rights. A pinned Patched (0.1.7 and later) also needs the code to be signed
with the owner's Developer ID Application certificate, so the attacker needs that
certificate's private key (or Apple to issue one for the team) as well as the release key. That is the same as the
compromise of any vendor's signing key, which this tool already accepts for other
apps. A GitHub account compromise alone is not enough: without the key, a
replaced zip fails the signature check, and the attacker can only withhold
releases, offer an old version (refused as not newer), or point the release page
somewhere (Download opens only the exact release page URL). If the key is lost or
leaked, the only fix is a release with a new key built in, installed by hand.
TLS to GitHub is relied on only for availability, not for integrity.

**Later.** A full Gatekeeper (`spctl`) assessment of the new app on this path, as the
normal installer does for every other app (the requirement already demands a
notarisation ticket).

## Automatic updates

Off by default, set by the user in Settings or by an organisation through managed preferences
(`AutomaticUpdatesEnabled`, `AutomaticUpdatesTime`, for `im.patched.app`). It is the one
deliberate exception to "nothing installs until you choose Update". The only code that can
start it is the scheduler's `runAutomaticIfDue`, after a successful check, when the setting
is on, the chosen time has passed by no more than 6 hours and it is still the same day (the window never crosses midnight, so a late time has a shorter window), and no run is recorded for today.
It calls the same `updateAll` as the Update All button, in a narrower `automatic` form, so
every check in "What is checked for every update" applies, and each app is rechecked just
before its install.

Exclusions, enforced twice (in Update All's selection and again in the automatic form):
installer packages (Apple's Installer needs a password), root-owned or admin apps (consent is
never passed), Patched itself (self-update stays an explicit confirmed click), hidden apps and
Mac App Store apps (the App Store is not even opened). Open apps are skipped and never quit,
and recovery never runs. It waits while an install, roll back or recovery is running, and is
skipped after a check that mostly failed offline. It does not wake the Mac or hold power
assertions. Roll back works as for any update.

Managed values are read with `CFPreferencesAppValueIsForced`: only a forced value counts, so a
user default is never mistaken for policy. A forced value locks the control. A forced
`AutomaticUpdatesEnabled` of the wrong type fails closed (off and locked, reported in Settings),
so a bad profile cannot leave installs running that the organisation meant to stop. A time that
is not exactly `HH:mm` is ignored and reported, and the user's time or 02:00 applies. It waits
while installing is blocked or a confirmation is open, and it does not dismiss one. An attacker who can write managed preferences already
runs as root or controls the Mac's MDM, and gains nothing here that they could not do
directly.

## Self Service

An organisation can give people a catalogue of approved apps that they install for
themselves. The catalogue is the managed preference `SelfServiceCatalogue` for
`im.patched.app`, read with `CFPreferencesAppValueIsForced` like the automatic-updates keys:
only a forced value counts, so a user cannot supply or extend a catalogue. The "Available"
screen that lists it is coming in the same release; the installer, recovery and
`patched catalogue list` are in place now.

**What is trusted.** MDM is trusted to deliver the catalogue: whoever controls the
configuration profile decides which apps can be installed and which developer each one is
pinned to. An attacker who can write forced managed preferences already runs as root or
controls the Mac's MDM. The trust anchor for a fresh install is the **Team ID pinned in the
catalogue entry**: with no app installed there is nothing else to compare against, so a
download signed by any other team is refused, however it was served.

**Without a `BundleID` the Team ID is the whole anchor.** An entry that omits `BundleID`
accepts any app that its developer has signed and notarised, not only the app the
administrator meant: a large developer ships many apps under one Team ID. `BundleID` is the
normal case and is strongly recommended; `patched catalogue list` warns about every entry
without one.

**The feed chooses the build.** The update source (Sparkle feed or Homebrew cask) decides
which download is offered, and Patched only checks that the download is the version the feed
names. A feed, or whoever controls it, can therefore offer any build that team has signed and
notarised, including an older one with known flaws: with nothing installed there is no
"must be newer" rule. A possible later hardening is an optional `MinVersion` per entry that
refuses anything older; it is not in version one.

**Parsing.** Strict and per entry, with no network. At most 500 entries (more makes the whole
catalogue invalid) and bounded string lengths. Every key must be known, so a misspelt key such
as `BundleId` cannot silently drop a check. `TeamID` must be ten capital letters or digits.
Exactly one source: an https `SparkleFeedURL` with a host and no user name or password, or a
`HomebrewCask` token in Homebrew's character set. A value of the wrong type or form makes that
entry invalid, with a plain reason, and the others still work. A top-level value that is not an
array makes the whole catalogue invalid. The feed is looked up only when the user chooses
Install for that entry.

**Where it installs.** `~/Applications` only, so no admin rights and no privileged code are
involved. The folder is created (mode 0700) if it is missing; a symlink anywhere in its path, a
folder owned by someone else, or one the user cannot write is refused. Entries marked
`NeedsAdmin` are shown and never installed. Anything already at the destination is never
overwritten: the move into place is `renamex_np` with `RENAME_EXCL`, so an app that appears at
the last moment still wins, and the user is pointed to Updates.

**The checks.** A fresh install is the update pipeline with no app to replace:

- Applied as for updates: https-only download and redirects, the 4 GiB cap, length, SHA-256 and
  SHA-512 when the feed gives them, the unpack budget, `ditto` and `hdiutil` with the same
  options, exactly one matching app in the download, no symlinks leaving the bundle, a strict
  code signature pinned to the entry's Team ID, Gatekeeper's notarised Developer ID assessment,
  the version the feed offered, the per-app lock, refusal while a journal is unreadable or
  unfinished, and verification again after the move (signature, Team ID, bundle ID, version and
  Gatekeeper). Only zip and dmg; installer packages are refused.
- Compared with the catalogue entry instead of the installed app: the Team ID, and the bundle ID
  when the entry gives one. Without a bundle ID the download must hold exactly one app.
- Not applicable: "strictly newer than the installed one" (nothing is installed), the Sparkle
  EdDSA check (the public key would come from the same download it is meant to check, so it
  adds nothing over the Team ID pin), the App Store receipt check and backups (there is no old
  app). Quarantine is handled as for updates: Patched neither adds nor removes it.

**Journal and Recover.** A fresh install writes a `freshInstall` journal before every step, and
the existing `recover` (at launch, from Recover, and `patched recover`) finishes or undoes it:

- Interrupted before the move (`staging`, or `prepared` with nothing of ours at the
  destination): the staging folder and download are removed; the destination is not touched.
- Interrupted after the move but before success was recorded (`prepared` or `swapped`), with
  the very folder the journal recorded (same device and inode) at the destination: it is
  checked again (signature, Team ID, bundle ID, version and Gatekeeper). If that passes, the
  install is finished and the app kept. Otherwise it is removed, but only if it still has the
  journal's bundle ID and nothing runs from it. Anything else at the destination is left alone
  and reported.
- Once a fresh install is finished or undone and cleaned up, its journal is deleted rather
  than kept: there is no backup to roll back to, and an older Patched that does not know the
  `freshInstall` kind would otherwise pause all updates over a journal it cannot read.
- A fresh-install journal names the Self Service folder it was started in. Recovery refuses
  one whose target is not directly in that folder, or whose folder is not this user's
  `~/Applications`, so an edited journal cannot point recovery at an app anywhere else.
- Until the app in the download is identified, the journal carries a placeholder bundle ID
  whose lock the running install holds, so a concurrent `recover` leaves a live install alone.
- Finished: nothing to undo.

A copy that fails the check after the move is removed in the same way during the install
itself. If it cannot be removed (for example it is already running), Patched never quits or
kills it: the journal stays open and the result says that the copy at that path is unverified,
not trusted and should be deleted. An older Patched cannot read a
`freshInstall` journal; it reports it as unreadable and refuses updates until it is resolved,
which fails safe.

## Out of scope

- **Malware already running as you.** It can change your apps directly, so the
  tool does not try to defend against it, beyond cheap checks: it refuses to
  delete through symlinks or outside its own folders, and checks again just before
  the swap.
- **A developer's own signing key or update server being compromised.** An update
  signed and notarised under the right Team ID is accepted.
- **Root, admin-owned apps and `.pkg` installers.** Refused (`needs_admin`,
  `unsupported_format`) unless the experimental admin path below is switched on.

## When something goes wrong

- **Fail closed.** Any check that cannot pass refuses the update with a reason.
  The installed app is left untouched and temporary files are removed.
- **One-step swap.** The new app replaces the old one in a single atomic
  exchange. If the new app fails its checks afterwards, the old app is checked and
  put back.
- **Backups.** The old version is kept in
  `~/Library/Application Support/Patched/Updater/backups` until the next update.
  `rollback` puts it back the same way. A same-version backup is set aside while an
  update is prepared and put back if the swap does not happen (also by `recover`).
- **Journal.** A journal written before every step lets `recover` finish or undo
  an interrupted update. When it cannot prove which state is safe, it changes and
  deletes nothing, leaves the app stopped, and says so.
- **Running apps.** Updates, rollbacks and `recover` refuse to touch an app that is
  running from an affected bundle. An app is only quit if you ask (`--quit`). It is asked to
  quit, never force-killed, and is only relaunched once the result has been
  verified. The check looks at more than the app's own instances: it also lists every
  process on the Mac whose executable lives inside the bundle (login items in
  `Contents/Library/LoginItems`, XPC services, and tools in `Contents/MacOS` however
  they were launched, symlinks included), using `proc_listallpids` and `proc_pidpath`.
  The bundle path is compared with a trailing "/", so `Foo.app` never matches
  `Foo.app2`. Each such process is put in one of three classes, and nothing is ever
  killed or signalled. An *ignorable* process (anything inside an app extension, a
  `.appex`, such as a widget; or a crash reporter named `crashpad_handler` or
  `chrome_crashpad_handler`) never blocks a zip or dmg swap: macOS relaunches extensions
  from the new bundle and crash reporters hold nothing. It is not asked to quit either.
  A *quittable* process is the main executable of a nested `.app` (a login item or a sync
  service). With `--quit` (or the Updates screen's quit consent) it is asked to quit
  politely, exactly like the app (`NSRunningApplication.terminate`, never a force
  terminate), waited for up to the quit timeout, and the bundle is looked at again; without
  that consent it blocks. A nested app that Patched itself quit is reopened afterwards,
  from the new bundle once the update is verified or from the unchanged bundle if the
  update is refused or fails, and nothing Patched did not quit is ever reopened. Every *other* process (XPC services, daemons, bare tools,
  Sparkle's updater, anything inside a framework) blocks, even with `--quit`: the update is
  refused with `helper_running`, naming it and its pid, and you quit it yourself. Rollback
  and recovery treat ignorable processes the same way; recovery never asks a nested app to
  quit, and rollback does so only under the same consent it needs to quit the app. The sweep
  runs before the download (nested apps are not yet asked to quit), again before the app is
  quit, once more after the quit (helpers get a few seconds to follow the app out) and a
  last time immediately before the swap, all with the same classification. It is
  best-effort: it sees only processes the current user may inspect.
- **Helpers and `.pkg` updates.** `.pkg` updates do not refuse on helpers running from inside
  the bundle (an updater daemon, a sync service), because Apple's Installer and the package's
  own scripts replace the app and manage its background processes. The app itself must still be
  quit: a running instance is refused with `app_running`, or asked to quit with `--quit`, as
  for any update. The zip and dmg swap, rollback and recovery keep the helper classes above.
- **Cancelling.** A single update can be cancelled from its row until the commit
  point (the quit and swap). Cancelling stops the download or unpacking and removes the
  download and staging folders, leaving the app and its backups as they were. After
  the commit point there is no Cancel, and a late one is ignored, so the swap and
  its verification always run to a verified result or a verified swap back.
- **Uninstall.** `patched uninstall` and the app's Uninstall Patched… delete only Patched's
  own files: its Application Support, Caches and Logs folders (and the older `mac-updater`
  ones), its state migration files, the optional check LaunchAgent (booted out first), its
  user defaults, empty `.patched-self-update-*` and `.mac-updater-*` staging folders, and
  last the app, which goes to the Bin. It plans first and plans again before deleting, and
  refuses, deleting nothing, while any journal is unfinished or has cleanup pending, while a
  migration is unfinished, while a staging folder holds an app or is named by a journal, while
  another copy of Patched is running, or when a folder it would delete is a symlink (symlinks
  are never followed, and nothing outside the Patched folders is touched). There is no force
  option; the way forward is `patched recover`. Backups are kept in place by default so a
  reinstalled Patched can still roll back; they are deleted only with `--delete-backups`
  or the Delete Backups button. Managed preferences are never read or changed, an app
  installed by Homebrew is left for `brew uninstall --cask patched`, and the login item can
  only be removed by the app itself or by the user in System Settings.

## State migration

The current support and cache folders are `~/Library/Application Support/Patched/Updater`
and `~/Library/Caches/Patched/Updater`. First use migrates legacy `mac-updater` state
without overwriting existing destinations. An unfinished transaction keeps the
legacy folders selected and reports that `patched recover` must run first; the
selected catalogue and cache stay with that state until migration is safe. Existing
entries beside `Updater` remain untouched. A durable completion marker prevents
recreated legacy folders being merged automatically. After an interrupted rename,
recovery selects the moved support root and retains any unmoved cache until its
journals have been recovered. Quit the app before running recovery so its retained
migration lease can be released.

## Admin updates

Phase 2b is built in two parts, each with its own switch: installer packages are on
by default, root-owned app replacement is off by default. With both off, everything
above is exactly as before (root-owned apps say "needs admin, update this app
manually").

- **Root-owned apps**: `PATCHED_ENABLE_ADMIN_UPDATES=1`, or the hidden
  `--enable-admin-updates` flag on `patched update` / `rollback`. **Untested, and known
  not to work for ad-hoc-signed builds**: on macOS 27 the owner's probe got macOS's
  prompt and a granted authorization, but `FileManager(authorization:).replaceItemAt`
  then failed with NSCocoaErrorDomain 512 / POSIX EIO, for a root-owned folder and
  for a single root-owned file. Patched reports this as `admin_replace_unavailable`
  ("update this app manually") and changes nothing. It is to be revisited once there
  is Developer ID signing. There is no fallback to `osascript`, `do shell script`,
  `sudo` or any other way of running commands as root.
- **Installer packages**: on by default since 9 November 2026;
  `PATCHED_ENABLE_PKG_UPDATES=0` turns them off. This does not depend on Patched's
  own signing, because Apple's Installer does the installing and asks for the
  password. The package checks were run against a real notarised vendor package
  (DisplayLink 17.1): the right Team ID passed and a wrong one was refused.

**When either part can be used.** Only for an explicit action by the person at the Mac: a
click on one app's "Update (admin)", "Update (installer)" or "Roll back" in the app,
or a typed `patched update` / `rollback`. Update All never uses it (it skips such
apps and marks them, and it is equally unprivileged when started from the menu-bar item
or the notification's "Update All" button, which are explicit clicks on the same code),
the notification's button installs only the updates it advertised (their path, version and
build travel in the notification) that are still on offer after a fresh recheck, and
otherwise installs nothing and opens Updates, a click on a fresh launch or during a check
waits for a successful check and is dropped if that check fails or is cancelled (the
menu offers Cancel), scheduled checks install nothing unless the opt-in automatic updates setting is on (see "Automatic updates" below, which never uses admin rights or the installer package path either), and recovery never
uses admin rights. From the CLI it refuses with `needs_interactive_admin` when the
login session has no screen (for example SSH) or another user is at the screen.
macOS asks once per update; nothing runs as root in the background, and there is
no helper, daemon, `sudo`, `installer` command or shell.

**Root-owned apps (zip and dmg).** Everything in "What is checked for every
update" still applies, up to and including the verified staged app. Then:

1. The installed app is copied, as you, into the backups folder, and the copy must
   verify as the installed version (signature, Team ID, bundle ID, version) before
   anything privileged happens. If it cannot be copied or does not verify, the
   update is refused and macOS is never asked.
2. macOS's own prompt (`NSWorkspace` authorization) grants one replacement, and
   `FileManager(authorization:)` replaces the app with the verified staged copy.
   Staging is in the private downloads folder on the same volume.
3. The installed app is checked again (signature, Team ID, bundle ID, version and
   Gatekeeper), and its new owner is recorded.
4. If it fails, the verified backup copy is put back through the same grant and
   checked. If that fails too, nothing is deleted: the journal stays, and the
   message says where the backup is and how to put it back by hand.

Rollback of an admin-owned app uses the same steps. Immutable, append-only and
SIP-restricted files are refused even with admin rights.

**Installer packages (`.pkg`).** Package scripts run as root under Apple's
Installer and cannot be avoided or inspected, so the package must earn that:

1. Length and hashes as for any download, and Sparkle EdDSA when the app pins a key.
2. A flat package only (one xar file); bundle-style folders and symlinks are refused.
3. `pkgutil --check-signature` must show "signed by a developer certificate issued
   by Apple for distribution" and exactly the chain "Developer ID Installer: … (TEAM)",
   "Developer ID Certification Authority", "Apple Root CA", where TEAM is the
   installed app's Team ID. Apple-signed packages, application certificates,
   untrusted, unsigned and any output the parser does not recognise are refused.
4. `spctl --assess --type install` must accept it as notarised Developer ID with the
   same Team ID as origin; an overridden assessment is refused.
5. The package is made read-only and its hash is checked again just before it is
   handed to Apple's Installer (`open -a /System/Library/CoreServices/Installer.app`),
   which shows its own window and admin prompt.
6. Afterwards the installed app must be the offered version, strictly newer, signed
   by the same Team ID and accepted by Gatekeeper. If Installer did not change it
   (cancelled, still open, or after the 30-minute wait), nothing is verified and
   nothing more happens.

**No rollback for packages.** A package can install more than the app (launch
daemons, kernel or system extensions, files elsewhere), so putting back only the old
`.app` would leave a mismatched install. Rollback is therefore not supported after a
`.pkg` update: `patched rollback` refuses with `rollback_unsupported`, `patched
backups` marks the copy, and the app shows "Roll back isn't supported for installer
packages." A read-only copy of the previous app is still taken before Installer opens
when possible, and kept, so it can be restored by hand. If Installer installs
something that fails verification, that copy is kept for the same reason.

**What the admin path adds to what is trusted.** Apple's authorization prompt and
`FileManager(authorization:)`, Apple's Installer and `installd`, and the scripts
inside a package signed with the installed app's Developer ID Installer Team ID and
notarised by Apple.
