# Brand assets

Patched brand kit v3, copied unchanged from the Patched.im branding kit
(`branding/kit/favicon/app-icon-1024.png`, `branding/kit/logo/patched-mark-mono.svg`
and `patched-mark-primary.svg`).

Copyright 2026 Andy Bridson. All rights reserved. The Patched name, mark and app
icon are not covered by the repository's software licence.

- `app-icon-1024.png` is the source for `AppIcon.icns`, which `scripts/build-app.sh`
  generates at build time with `sips` and `iconutil`.
- `patched-mark-mono.svg` is the single-colour mark. The app draws the same path in
  code (`ShellBrandMark`) and uses it as the menu bar template image.
- `patched-mark-primary.svg` is the gradient mark for reference.
- The brand colour is blue `#2563EB`.
