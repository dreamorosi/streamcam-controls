# Build and release

All public binaries are built on GitHub's standard Apple Silicon macOS runner.
Local packaging below is a verification step, not the artifact we upload.
There is no Developer ID or notarization in this first distribution path.

## Before the first release

The agreed baseline checks in `HARDENING.md` were confirmed on 2026-11-04.
For later capture or control changes, repeat the relevant physical checks:

- Unplug/replug while the panel is visible. Controls should become unavailable,
  then read the reconnected camera rather than applying stale queued values.
- Sleep/wake. Capture must not remain stuck; Start preview should recover it.
- Deny/revoke Camera access for this app, then grant it again. Preview should
  stop or explain the permission state without breaking the control UI.
- Try Defaults with a known starting state. It should use supported reported
  defaults, not an undocumented whole-device reset. A bounded restore test can
  be run separately if the current framing/color settings should be retained.

These are human checks, not assertions a GitHub runner can perform. A real
release requires a checkbox attesting they are complete and publication is
approved. Shared Zoom/StreamCam previews are deliberately allowed.

Add `HOMEBREW_TAP_TOKEN` in this repository's Actions secrets. It needs Contents
read/write access to `dreamorosi/homebrew-tap`, not broader repositories. The
default `GITHUB_TOKEN` handles this repository's release and tag. Never put a
token in source, chat or an artifact.

## Local packaging check

```sh
./test.sh
python3 scripts/package-release.py
```

Packaging builds a separate bundle under `.build/release-build/`, so it does not
overwrite or launch the running app. It copies the project MIT license and the
upstream license texts for the selected Rust dependency graph before signing.

Outputs under `.build/releases/`:

- `StreamCam-Controls-1.0.0-arm64.dmg`, containing the app and an Applications link
- The DMG's `.sha256` file
- `streamcam-controls.rb`, generated with that exact checksum
- `release.json`, used by the workflow

The app, helper and final DMG are ad-hoc signed. Version checks require the
Cargo package version, app bundle version and bundled CLI version to agree.
The DMG is read-only distribution media; no preview or hardware-setting command
is run during packaging.

## Review the workflow changes first

Push and merge the release-workflow PR only after approval. Neither a source
push nor a PR merge publishes anything. Both workflows are manual dispatches.

### Dry run

Run **Release** on `main` with `tag=dry-run` and leave the acceptance checkbox
unchecked. It tests and packages on GitHub and uploads a seven-day workflow
artifact. It creates no tag, release or tap commit and does not use the tap
credential. Inspect/download that artifact before the first publication.

Standard runner time is free for this public repository. Dry-run artifact
storage has GitHub's separate allowance; keep retention short and do not upload
large caches.

### Publish

Obtain approval before either of these remote-writing steps:

1. Run **Tag current version** on `main`. It tests the project, checks the
   app/Cargo version match, and pushes only `v1.0.0`. It changes no source version
   and publishes no release. Existing tags are rejected.
2. Run **Release** with workflow ref `v1.0.0`, input `tag=v1.0.0`, and the
   acceptance/publication checkbox checked. Ref and version mismatches, missing
   approval attestation and a missing token fail before publishing.

The workflow builds/tests/packages on GitHub, publishes the final DMG/checksum
and generated cask as release assets, then directly commits only
`Casks/streamcam-controls.rb` to `dreamorosi/homebrew-tap`. This is a tap push,
not a tap PR, and must be included in release approval. It leaves existing
formulae, including Litra, alone.

If the release succeeds but the tap push fails, the release remains published.
Do not recreate or replace its assets casually. Fix the token/access and finish
the tap update against the already-published DMG checksum after approval.

For a later version, update `backend/Cargo.toml`, `backend/Cargo.lock` and
`app/Info.plist` through a reviewed source change, then repeat the process.

## Install and verify after publication

```sh
brew install --cask dreamorosi/tap/streamcam-controls
open -a "StreamCam Controls"
streamcam --version
```

The cask installs the app in the configured Applications directory and links
its bundled `streamcam` executable. Gatekeeper may block the first launch
because this download is not notarized. Use macOS's explicit Open Anyway flow
in System Settings > Privacy & Security if you choose to trust it, then grant
Camera permission for preview. Neither Homebrew nor the app disables quarantine
or other macOS protections. Trust/permission behavior needs testing on a
receiving Mac; local execution is not proof of a smooth downloaded install.

Updates use `brew upgrade --cask dreamorosi/tap/streamcam-controls`. Homebrew
uninstall quits this app and removes its CLI link. The cask does not broadly
erase user data or reset camera permissions.
