# Development

Build, test and diagnose StreamCam Controls locally. Product usage and
installation are in `README.md`; release procedures are in `RELEASING.md`.

Apple Silicon and macOS 14 or newer. No full Xcode app or Apple Developer
membership is required. This uses the installed Command Line Tools, SwiftUI,
AppKit, AVFoundation, and a Rust USB helper. The app is locally ad-hoc signed,
not notarized. No app release or cask has been published yet.

Source: [dreamorosi/streamcam-controls](https://github.com/dreamorosi/streamcam-controls).

## Run

```sh
./run.sh
```

Click the camera-aperture icon in the menu bar. Grant Camera permission when
prompted. Drag the title bar to move the floating panel. It stays open when you
click another app. Close it with the red close button, Escape, or the menu-bar
icon; closing stops the preview. Quit through the power button before rebuilding.

If preview cannot start, close QuickTime or another app using the StreamCam,
then retry. Only one StreamCam may be connected. The USB backend
supports the tested Logitech model `046d:0893`; it does not control other models.
The preview selects exactly one camera named StreamCam, not the built-in camera.
Shared capture is allowed. Zoom and this app can preview the same StreamCam
simultaneously on the tested Mac, and both images respond to camera controls.
There is no automatic handoff promise: macOS's foreign-use signal stayed false
during verified shared capture. Stop this app's preview explicitly when you
want another app to be the sole capture client. Controls remain available.

## Try

- Framing tab: zoom and pan/tilt. Pan/tilt display degrees but retain raw UVC
  arc-second values internally. Zoom is shown in camera units, not a verified
  percentage or optical magnification.
- Color tab: saturation and automatic/manual white balance. Disable automatic
  white balance before moving its temperature slider.
- Release a slider to apply. Writes are range/step-validated and read back.
- Defaults: confirm before applying defaults reported by the camera for these
  supported controls only. This is not a whole-device factory reset.

Closing the panel stops and releases the preview. Settings already applied
remain on the camera; closing is not an automatic revert. Opening a new panel
session reads the current camera values. There is no snapshot/revert feature,
recording, audio capture, launch-at-login, or background camera
service. Settings may be overwritten by other software or reset on reconnect.

The app uses transient CLI calls. A short OS file lock coordinates its
app/helper operations, not unrelated camera software. The lock lives in
`~/Library/Caches/com.dreamorosi.streamcam-controls/controls.lock`; it contains
no presets or images. Control batches are not atomic at the camera. Errors may
leave a partial change, which the UI attempts to reread rather than hide.

## Build without opening the app

```sh
./run.sh --build-only
```

The bundle is `.build/StreamCam Controls.app`. Its standalone CLI can be
used directly:

```sh
".build/StreamCam Controls.app/Contents/MacOS/streamcam" status
".build/StreamCam Controls.app/Contents/MacOS/streamcam" --help
```

The helper also supports `set NAME VALUE`, `apply JSON`, and `defaults`. Those
commands change hardware. Builds never execute them automatically. Status is
JSON and includes a connection-scoped `deviceId`. The app passes that ID to
every write so a disconnected/replaced camera cannot receive stale settings.
Interactive CLI calls can use `--device-id ID` for the same protection.

## Tests without hardware

```sh
./test.sh
```

This runs Rust formatting, Clippy, 16 fake-transport tests, 13 Swift checks
using controlled backend replies, and seven release-validation/cask tests. It
does not access a camera or alter settings.
Coverage includes range validation, pan/tilt preservation, defaults, white-
balance mode ordering/failure recovery, stale callbacks, coalesced writes,
camera identity, capture policy, and helper-process deadlines.

When the panel is visible, a two-second monitor refreshes real controls, skips
active slider edits, and checks disconnect/permission/capture state. Reads
started before a newer write cannot overwrite that write's result. Closing
cancels queued work; an in-flight helper transaction finishes instead of being
interrupted midway. A stuck helper has a separate deadline and reports that
the camera may have been partially changed.

## Check panel geometry and capture lifecycle

```sh
python3 scripts/check-window.py --launch
python3 scripts/check-window.py --launch --letterbox
python3 scripts/check-window.py --launch --close
```

These commands quit and rebuild this app, open its panel, and inspect its
own window/preview geometry. They do not take screenshots or write camera
settings. The first check requires Camera permission and verifies an active,
visible preview connection. The second checks that closing releases capture.
Diagnostic files live in the ignored `.build` directory.

Repeated-open regression:

```sh
python3 scripts/check-preview-reopens.py --cycles 20
```

The inspection build repeatedly closes/reopens its own panel without recording
frames or changing control settings. Each open must create a new renderer and
keep stable video geometry. The user also checks that the actual image does not
shrink: public video rectangles can look correct even when rendered pixels do
not. `scripts/reopen-visual-check.sh` records that visual verdict as metadata.

The preview uses the active video format's aspect ratio, retaining the whole
frame rather than adding a preview-only crop. The Framing/Color switch has no
visible label, and the footer contains only Defaults. Normal applied-value
messages, snapshot/revert, reload and slider instructions were removed from
the interface. Genuine camera errors remain visible.

## Zoom investigation

This StreamCam advertises zoom 100 to 400 in both tested capture modes, but the
user observed effective zoom stopping around 150 during this app's 1080p
capture. A verified 1280×720 comparison allowed more visible zoom. Camera
readback alone does not establish magnification.

With this app's preview stopped and Zoom's own preview open, the user confirmed
that the slider works throughout its range. A subsequent native 640×360 test
also confirmed every zoom stage in our own preview, including 200 to 400.
The normal preview now selects that tested camera format after session startup
and retains the full 100 to 400 control range. No preview-only crop or resolution
selector was added. Zoom's exact raw capture format remains unknown.

The 640×360 choice is for this small standalone preview, not a promise about
the quality or resolution another app will capture/send. For Zoom tuning,
Zoom's own image remains the final reference. Both previews may stay open;
stopping ours is an explicit option, not an automatic handoff.

An explicitly authorized bounded visual test is available with:

```sh
bash scripts/zoom-visual-check.sh
```

It cycles zoom 100, 138, 200 and 400 for three seconds each, then restores the
original zoom. Only control metadata and the user's visual verdict are saved,
not images/video. The window regression check verifies the native 640×360
format as well as geometry, preview connection and absence of letterbox bands.
The temporary 720p/360p comparison flags have been removed.

## Release readiness

The agreed baseline checks are complete: sleep/wake, unplug/replug, reported
defaults, permission denial/re-enable, and repeated panel opening. See
`HARDENING.md` for evidence and scope limits. Shared previews are supported;
automatic yielding is not simulated with process/focus guesses.

GitHub CI runs the hardware-free checks and builds/verifies an Apple Silicon
app bundle without opening a camera. It does not publish a release or update
a Homebrew tap. See `RELEASING.md` for the separately dispatched packaging,
tagging and release process.

Local packaging generates a DMG and personal-tap cask. They have not been
published. There are no persisted presets or notarization yet. This project
remains separate from the working Litra CLI.

## License

MIT. See `LICENSE`. This is an unofficial utility, not a Logitech product.
