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
- GitHub's latest-release record for this repository (https, 256 KB cap), only to
  say that a newer Patched exists. It is untrusted metadata: only `tag_name`,
  `html_url`, `draft` and `prerelease` are read; the tag must be digits and dots,
  `html_url` must be exactly this repository's release page for that same tag, and
  drafts and prereleases are ignored. Assets are never read. The request is a single
  anonymous GET with a plain `Patched/<version>` User-Agent and no user data. The
  only thing ever done with the result is to show "Patched X is available" and, on
  a direct click on Download, open that validated page in the browser. Nothing is
  downloaded, installed or opened automatically, and Patched's own row is never
  part of Update All.

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
  `rollback` puts it back the same way.
- **Journal.** A journal written before every step lets `recover` finish or undo
  an interrupted update. When it cannot prove which state is safe, it changes and
  deletes nothing, leaves the app stopped, and says so.
- **Running apps.** Updates, rollbacks and `recover` refuse to touch an app that is
  running from an affected bundle. An app is only quit if you ask (`--quit`). It is asked to
  quit, never force-killed, and is only relaunched once the result has been
  verified.

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
