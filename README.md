# StreamCam Controls

<img src="docs/assets/app-icon.png" alt="StreamCam Controls icon" width="96" align="right">

Native camera controls for your Logitech StreamCam, without Logitech software.

Adjust framing and color from a floating window opened through your Mac's menu
bar. See changes in a live preview, or keep the preview off and use Zoom's own
image as your reference. The bundled `streamcam` CLI provides the same controls
from your terminal.

## Features

- Zoom, pan and tilt for framing your shot.
- Saturation and automatic/manual white balance for color tuning.
- A movable live-preview window that stays open while you use other apps.
- Restore the camera's supported control defaults.
- Read and adjust settings from the bundled CLI.

No video recording, microphone access or background camera service. Closing
the panel stops its preview; settings you've applied remain on the camera.

## Requirements

- Apple Silicon Mac running macOS 14 Sonoma or newer.
- Logitech StreamCam connected over USB.
- Camera permission for the live preview.

Supports the tested StreamCam model `046d:0893`, with one connected camera at a
time. Other webcam models are not supported.

## Install

Homebrew installation will be available after the first `v1.0.0` release is
published:

```sh
brew install --cask dreamorosi/tap/streamcam-controls
```

The cask installs **StreamCam Controls.app** and links the bundled `streamcam`
command. Release downloads will also be available on the
[releases page](https://github.com/dreamorosi/streamcam-controls/releases).

The app is ad-hoc signed, not notarized. macOS may require you to approve the
download through **System Settings → Privacy & Security → Open Anyway** before
launching it. Allow Camera access when you open the preview. The app does not
disable macOS security protections.

## Use

Launch StreamCam Controls and click the aperture icon in the menu bar.

Choose **Framing** for zoom and position, or **Color** for saturation and white
balance. Turn off automatic white balance to choose a temperature manually.
Changes apply directly to the camera.

Drag the title bar to move the window. Use **Stop preview** to keep the controls
available without a live image. Close the panel with the menu-bar icon, Escape
or the window's close button. The power button quits the app.

**Defaults** restores defaults reported by the camera for supported controls;
it is not a whole-device factory reset. Settings may reset after unplugging or
be changed by other software.

### With Zoom and other camera apps

Zoom and StreamCam Controls can preview the same camera simultaneously on the
tested Mac. There is no automatic camera handoff. Stop our preview explicitly
when you want another app to be the only capture client.

The small preview uses a tested 640×360 camera format for the full zoom range.
It does not set the resolution Zoom sends to meeting participants. Use Zoom's
own image as the final reference for meeting framing and color.

## Command line

```sh
streamcam status
streamcam set zoom 200
streamcam set pan 3600
streamcam set saturation 128
streamcam set white-balance 4500
streamcam set auto-white-balance 1
streamcam defaults
```

`status` prints current settings and supported ranges as JSON. Zoom and
saturation use camera units; pan/tilt use arc-seconds, so `3600` is one degree.
White balance uses Kelvin. Setting its temperature switches to manual mode.
Run `streamcam --help` for the full interface.

## Build and contribute

See [DEVELOPMENT.md](DEVELOPMENT.md) for local builds and tests. Full Xcode and
an Apple Developer membership are not required to build locally.
[RELEASING.md](RELEASING.md) covers packaging and publication.

## License

[MIT](LICENSE). This is an unofficial utility, not a Logitech product.
