# Package signature fixtures

Text that `pkgutil --check-signature` and `spctl --assess --type install -vv` print, for the strict
parsers in `Sources/UpdateInstaller/AdminUpdates.swift` (experimental admin path, off by default).

- `pkgutil-apple-signed.txt`, `pkgutil-unsigned.txt`, `spctl-apple-installer.txt`: captured on this
  Mac from an Apple Command Line Tools package and a Homebrew test fixture. Only the package name was
  changed to `artifact.pkg`, and trailing spaces were trimmed.
- `pkgutil-developer-id.txt`: the documented Developer ID Installer layout with an invented Team ID
  (`AAAAAAAAAA`) and fingerprints. Run `patched admin-probe --enable-admin-updates --package <pkg> --team <ID>`
  on a real vendor package to compare (see `scripts/admin-probe-runbook.md`).
- Every other file is a one-line edit of that one, each a reason to refuse: another team, a Team ID
  hidden in the name, an application (not installer) certificate, an untrusted certificate, a short or
  out-of-order chain, an unknown line, two status lines, no chain.
- `spctl-*.txt`: `{PATH}` stands for the package path, filled in by the checks.
