# Releasing

How to build a DMG and publish it as a GitHub release. The whole flow is two
commands; the details below explain what each step does and what can go wrong.

## Prerequisites

- `gh` CLI authenticated: `gh auth status` must show `oleggohman` active.
  If plain `git push` complains about credentials, run `gh auth setup-git`
  once — it wires git's credential helper to gh's stored auth.
- A clean, committed checkout: the release tag must point at the exact commit
  the app was built from (`AGENTS.md` requirement).

## The standard flow

From `SoundMix/`:

```bash
./build-dmg.sh                      # build + verify the DMG
UPLOAD_RELEASE=1 ./build-dmg.sh --skip-build   # tag + publish the release
```

`build-dmg.sh` with `UPLOAD_RELEASE=1` does, in order:

1. Reads `VERSION` and `BUILD` from the built app's `Info.plist`
   (`CFBundleShortVersionString` / `CFBundleVersion`).
2. Validates them against the on-disk `VERSION` and `BUILD_NUMBER` files —
   the DMG, the tag, and the source state must all agree.
3. Re-verifies the app's code signature (`codesign --verify --deep --strict`).
4. Builds and verifies the DMG (`hdiutil verify`).
5. Creates an **annotated Git tag** `v<VERSION>-build-<BUILD>` (e.g.
   `v1.2.0-build-39`) at the current commit — the commit you built from.
   Never moves an existing tag; if it already exists and points elsewhere,
   the script's tag step conflicts and you should stop and investigate.
6. Publishes the DMG: `gh release create <tag> <dmg>` with title
   `SoundMix <VERSION> build <BUILD>` and default install notes.
7. Pushes nothing by itself — push the tag (`git push origin <tag>`) so the
   tag exists on GitHub too (the release itself is created on GitHub by `gh`).

## Options

| Variable / flag | Effect |
|---|---|
| `UPLOAD_RELEASE=1` | Actually publish to GitHub (default off — local-only builds skip this). |
| `DRAFT=1` | Create the release as a draft first (review, then publish on GitHub). |
| `RELEASE_NOTES="..."` | Override the default release notes text. |
| `--skip-build` | Skip `build.sh`; package the existing `build/SoundMix.app` without bumping the build counter. Required when the app is already built (e.g. re-packaging after a failed upload). |

## Manual fallback

If the script's upload step fails (network, auth, classifier hiccups), do it
by hand — the pieces are:

```bash
# 1. Tag the exact commit the app was built from
git tag -a v1.2.0-build-39 -m "SoundMix 1.2.0 build 39" <commit-sha>

# 2. Create the release with the DMG attached
gh release create v1.2.0-build-39 \
    dist/SoundMix-1.2.0-build-39.dmg \
    --repo oleggohman/SoundAPP \
    --title "SoundMix 1.2.0 build 39" \
    --notes "Ad-hoc signed; macOS 14 or later. Right-click → Open on first launch."

# 3. Push the tag so it shows in the repo's tag list
git push origin v1.2.0-build-39
```

`DRAFT=1` corresponds to adding `--draft` to the `gh release create` call.

## Rules (from AGENTS.md, enforced here)

- Tag format is always `v<VERSION>-build-<BUILD>`, read from the packaged
  app's plist — never hand-invented.
- Build release DMGs from a clean committed checkout and tag the exact commit
  used. With `--skip-build`, verify the existing app's source commit before
  tagging; do not assume it is `HEAD`.
- Never move or overwrite an existing release tag. If `v<VERSION>-build-<N>`
  already identifies the same release commit, keep it; otherwise stop and
  report the conflict.
- Report the DMG path and tag when finished. Do not push tags unless asked.

## Verifying a release

```bash
gh release view v1.2.0-build-39 --repo oleggohman/SoundAPP
```

Check: the DMG asset is attached, the title matches the tag, and the release
points at the commit that was built.
