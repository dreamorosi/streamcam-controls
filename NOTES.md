# Prototype question

Can a locally built SwiftUI/AppKit menu-bar app preview the StreamCam and apply
the proven Rust USB controls without full Xcode or Logitech software?

## Acceptance observations to collect

- Camera permission is attributed to StreamCam Prototype.
- The movable panel shows the intended camera, not another attached camera.
- Preview stops on panel close, Escape, explicit stop, and Quit. Clicking
  outside keeps the panel visible and therefore keeps its preview running.
- Zoom, pan, saturation, and manual white balance visibly apply.
- Supported-control defaults behave as labelled. Snapshot/revert was removed
  after the first user feedback.
- Preview failure does not prevent supported USB controls from working.
- QuickTime/meeting-app coexistence is observed rather than assumed.

## First build

- Built SwiftUI/AppKit/AVFoundation using the installed Command Line Tools,
  without full Xcode. The SDK's newer `@State` macro requires an unavailable
  plugin, so this prototype keeps state in its observable model instead.
- Built the Rust helper; Clippy passes without warnings.
- Verified the app signature, nested helper signature, and camera entitlement.
- The bundled helper reads all seven supported scalar/axis controls from the
  connected StreamCam. No setting writes were performed as part of building.
- Launched the app and confirmed its process is running. Camera preview starts
  only when the user opens the menu-bar panel. Visual acceptance is pending.

## First-run layout correction

The first popover was positioned with its preview above the usable screen.
The camera session was already running. A self-inspection check reproduced
both clipping and the absence of a draggable title/background. The initially
automatic hosting size was not a reliable input to popover positioning.

Replaced it with a fixed-size, draggable native panel. Size is established
before presentation, origin is clamped to the menu-bar display's usable area,
and short displays can scroll the content. The panel stays visible across
outside clicks, so capture runs only while its window remains visibly open.

`python3 scripts/check-window.py --launch` now passes with the whole panel and
preview on-screen, a nonzero preview layer and an active video connection.
`python3 scripts/check-window.py --launch --close` passes with capture stopped
and zero retained inputs. No setting writes were performed by these checks.
The user confirmed that the live image and title-bar dragging work well.

## UI cleanup and zoom findings

Removed the Controls label, slider instructions, snapshot/revert features,
reload button, and normal applied-value messages. Centered the segmented
Framing/Color switch and shortened the panel from 685 to 610 content points.
Only actual errors remain as footer text.

The letterbox regression check initially failed. Its 404×214 preview contained
a 380.44×214 full image with 11.78-point bands on both sides. Matching the
active capture aspect ratio now displays a full 404×227.25 image without extra
cropping, and the `--letterbox` check passes.

The 1080p zoom loop read back 100, 138, 200 and 400, then restored original 119.
The user observed no further visible change beyond approximately 150. The
human-in-the-loop check was recorded as a failure, not falsely passed from
USB readback.

Changing only the session preset to 720p left active capture at 1920×1080.
Setting activeFormat before session start was also overridden. Selecting the
advertised 1280×720 device format after start produced a verified 720p capture.
Its comparison read back all four values and restored original 140. The user
observed visibly more zoom at 720p. Normal 1080p preview was then restored and
verified with zoom 140.

This supports a capture-mode-dependent effective zoom limit. It does not
establish Zoom's capture mode or prove every value up to 400 is useful in 720p.
Do not silently lower preview resolution or restrict zoom based only on our
own preview: the user wants to tune their Zoom meeting output.

Zoom's official [HD settings](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0066166)
and [statistics guide](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0070504)
describe varying meeting output resolution. Sent-video statistics are not
proof of the raw webcam capture format. The next useful comparison is against
Zoom's own preview while this prototype's preview is stopped.

The user then opened Zoom's own preview with the prototype preview stopped and
confirmed that the zoom slider works all the way through its range. The
control engine is therefore working for the target application. Our 1080p
capture session was not a reliable representation of Zoom's image. Keep the
full reported zoom range and do not add a quality selector based on the earlier
assumption. Zoom's exact raw capture format remains unknown.

## Native preview zoom fix

The user asked to fix our own preview rather than rely solely on Zoom's image.
After Zoom's preview was closed, a verified 640×360 native camera capture was
tested at zoom 100, 138, 200 and 400. Original zoom 100 was restored. The user
confirmed each stage zoomed further, including 200 to 400.

The app now selects that exact advertised format after session startup. The
full camera-reported zoom range stays intact, without preview-only cropping.
The effective range had depended on our capture profile, not on broken USB
commands. Preset requests alone were insufficient, and pre-start activeFormat
assignments were overwritten. The format is selected and verified afterward.
Future preview changes must validate visible zoom behavior, not just readback.

The app also refuses to start its preview when AVFoundation reports another
app using the camera. Controls remain available without forcing a format onto
an existing meeting. The guard compiles and the no-other-app path passes;
the actual guard behavior alongside Zoom still needs user acceptance.

Temporary comparison modes have been removed. The default preview's geometry,
active connection, native 640×360 format, absence of side bands, and closing
capture lifecycle checks pass. The final user-confirmed visual test is the
human-in-the-loop regression for this model and Mac.

Verdict: the user confirmed that the floating native interface, live preview,
and complete zoom range work. This remains a prototype, not a production app.
Absorb the validated approach into a real app or discard it when moving on.

## StreamCam Controls naming and first hardening pass

Promoted the working approach under StreamCam Controls in
`~/Codes/streamcam-controls`, with bundle ID
`com.dreamorosi.streamcam-controls`, bundled `streamcam` CLI and a locally
rendered aperture icon. The user granted the new identity Camera permission
and accepted its live preview. Builds remain local and ad-hoc signed.

Added a tested Rust engine with a fake transport, connection-scoped IDs for
writes, safe reported-default handling and failure recovery. Added Swift
tests for queued/coalesced commands, stale callbacks, helper deadlines and
capture lifecycle. A test caught an older background read repainting a newer
write; the command-revision fence fixes it. 16 Rust and 11 Swift checks pass.

Actual Zoom sharing disproved the proposed automatic-yield assumption. Both
previews were the same camera and responded to sliders, but the documented
usage signal stayed false. Primary-source findings are in
`docs/research/camera-ownership-macos.md`. The user selected **Allow both
previews**, so the unreliable handoff requirement and gate were removed.
Explicit Start/Stop preview remains, and disconnect/permission/failure checks
still release our session. No process/focus heuristics or new permissions.

See `HARDENING.md` for physical tests still needing acceptance before a release.
This naming/hardening pass created no GitHub repository, push, merge, release
or cask. Source publication follows under separate user approval.

## Repeated-open preview regression

Before the first release, the user reported a growing black envelope when
closing/reopening the panel. A screenshot and a 20-cycle live test confirmed
the camera image shrank inside a stable preview rectangle. The public video
rectangle, layer frame, and renderer sublayer geometry all stayed full-sized,
so geometry-only checks incorrectly passed the visible failure.

The first hypothesis was stale renderer state across capture-input replacement.
A failing Swift test showed that reopening reused the same renderer identity.
Each panel open now changes the SwiftUI view identity, creating a fresh native
preview layer; dismantling clears the old layer's session and removes it.
Capture format and camera controls were left unchanged for this experiment.

With that change, the user confirmed that the image stayed full-sized through
20 close/reopen cycles. This supports renderer reuse as the cause on this
setup, without claiming the private framework's exact scaling mechanism.
The hardware-free lifecycle test now passes. The geometry loop checks new
renderer generations, and its human-in-the-loop wrapper records the actual
visual verdict without saving frames. Temporary sublayer dumps were removed.

Cleanup also exposed a diagnostic-only startup crash: the preview conversion
could return a null/infinite rectangle before camera frames were ready, and
Foundation's JSON writer raised an Objective-C exception. Diagnostic rectangle
values are now sanitized, with a hardware-free JSON regression check. After
Camera permission was allowed for the rebuilt ad-hoc app, six more reopen
cycles passed with fresh renderers and stable geometry.

Future capture-lifecycle changes need repeated visual restart acceptance, not
just correct public rectangles. Release remains paused until this fix is
reviewed and integrated; no tag or public release was created.
