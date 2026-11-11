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

## What the tool trusts

- TLS and the system's certificate store, for downloads.
- Apple's code signing, revocation and notarisation services, through the
  Security framework and `spctl`.
- The Team ID in the installed app's signature, as the publisher's identity.
- Sparkle EdDSA public keys shipped inside installed apps.
- The update feeds (Sparkle, Electron, Homebrew), but only to say where to
  download from. Everything they say is checked against the above.
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
  `Foo.app2`. Such a helper is not an app instance and cannot be asked to quit, so
  the update is refused with `app_running` and the message names the helper and its
  pid, even with `--quit`; you quit it yourself. The sweep runs before the download,
  again before the app is quit, once more after the quit (helpers get a few seconds
  to follow the app out) and a last time immediately before the swap. It is
  best-effort: it sees only processes the current user may inspect.
- **Cancelling.** A single update can be cancelled from its row until the commit
  point (the quit and swap). Cancelling stops the download or unpacking and removes the
  download and staging folders, leaving the app and its backups as they were. After
  the commit point there is no Cancel, and a late one is ignored, so the swap and
  its verification always run to a verified result or a verified swap back.

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
menu offers Cancel), scheduled checks never install anything or reach Update All, and recovery never
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
