# Security Policy

## Reporting a Vulnerability

If you find a security vulnerability in SoundMix, please report it privately
rather than opening a public GitHub issue.

- **Email:** oleg@ohlz.me
- **Or:** [open a private security advisory](https://github.com/oleggohman/SoundAPP/security/advisories/new) on this repository

Please include as much of the following as you can: a description of the issue,
steps to reproduce, the version/build affected (from the app's About panel or the
DMG filename, e.g. `v1.2.0-build-39`), and any crash logs or console output.

You can expect an initial response within a few days. This is a personal,
unfunded project, so fixes are best-effort — thank you for your patience.

## Scope

In scope:

- The SoundMix macOS application and its bundled renderer
- The build and packaging scripts (`SoundMix/build.sh`, `SoundMix/build-dmg.sh`,
  `SoundMix/Tools/`)
- Anything that could lead to arbitrary code execution, unauthorized file
  access, or network activity the user did not initiate

Out of scope:

- Vulnerabilities in macOS itself, BlackHole, or other third-party components
- The [peqdb.com](https://peqdb.com) website and its data service — report those
  to the PEQdB project, not here
- Social engineering, phishing, or physical attacks

## Known Design Notes

SoundMix is a local desktop application with no network server component. Two
things are worth knowing when assessing it:

- **No sandbox entitlement** — the app is not App Sandbox-ed because Core Audio
  device routing requires it. It only reads/writes its own Application Support
  folder, user-chosen audio files, and profile exports.
- **Ad-hoc signing** — local builds are ad-hoc signed, not Developer ID signed
  or notarized. Gatekeeper will warn on first launch of a downloaded DMG;
  right-click → Open, or re-verify the build from source.

## Supported Versions

Only the latest tagged release receives security fixes.

| Version | Supported |
|---------|-----------|
| 1.2.x   | yes       |
| < 1.2   | no        |
