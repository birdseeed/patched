# Contributing

Thanks for considering a contribution. Keep changes focused, explain the user
impact, and retain the project's Apache-2.0 licensing and third-party notices.

## Build and checks

The project uses Swift 6 and targets macOS 13 or later. The local verification
gate builds the package and runs the Swift checks and reference catalogue tests:

```sh
./scripts/verify.sh
```

The gate needs Node 22 or later for one source guard. It runs with
`PATCHED_FORBID_REAL_STATE=1`, so no check can read or change your real Patched
state in `~/Library`. Only one read-only step inspects code signatures of apps
already in `/Applications`.

Clone and build somewhere private, such as a folder in your home directory, not
under `/tmp`.

There is no hosted CI. Run the local gate before submitting changes.

## Contributions

- Describe what changed and how you checked it.
- Do not include credentials, private data, or unrelated generated files.
- Keep third-party copyright and licence notices with the material they cover.
- Signed-off commits are optional; a sign-off is not required for a contribution.

For security issues, use the private reporting route in [SECURITY.md](SECURITY.md).
