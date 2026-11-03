# Hardening status

## Passed

- StreamCam Controls builds using Command Line Tools, without full Xcode.
- Bundled CLI is named `streamcam`; app and helper are locally ad-hoc signed.
- Native 640×360 preview, full zoom range, panel movement and full-frame display
  were visually accepted in the prototype. The named app's preview was also
  accepted, and its native-format/geometry checks pass.
- Live geometry/letterbox checks pass. Closing stops capture and removes inputs.
- CLI help/version and real read-only status checks pass. A matching connection
  ID is accepted; a stale ID is rejected before the camera is opened.
- 16 hardware-free Rust tests cover descriptors, ambiguity, malformed data,
  ranges/steps, signed extremes, pan/tilt, white balance, partial failures,
  defaults and identity.
- 11 hardware-free Swift checks cover capture-policy decisions, stale starts,
  late results/errors, coalesced settings, closed-panel behavior, partial-state
  rereads, decoding and helper deadlines.
- A regression first reproduced an older periodic read repainting a newer
  completed write. A command revision now invalidates such reads; it passes.

## Resolved by product choice: shared previews

The user opened Zoom's StreamCam preview while our preview was running. Both
continued, contrary to the intended yield policy. Relaunching while Zoom's
preview remained open also started our own preview.

The former `python3 scripts/check-window.py --refresh --expect-yield` check reproduced the failure
while the user has Zoom's preview open. It inspects only our app's metadata.
The monitor was active, the camera connected, and the sampled/direct
`AVCaptureDevice.isInUseByAnotherApplication` signal remained false. The model
cannot yield from a signal it does not receive.

Do not describe the boolean policy tests as proof of real macOS handoff. They
verify our handling of a supplied signal, not that this device/driver supplies
one. Do not substitute process existence, read Zoom's private files, or request
screen/accessibility/root permissions to guess camera activity.

The user confirmed Zoom selected the same StreamCam and a slider change
affected both live images. The usage signal nevertheless remained false.
Primary-source research found no guaranteed foreign-client replacement while
our capture is active; see `docs/research/camera-ownership-macos.md`.

The user selected **Allow both previews**. Shared capture is supported, the
incorrect automatic-handoff promise is removed, and the obsolete yield check
was retired. Start/Stop preview is the reliable explicit control. No process
existence, focus heuristic, private API or extra permission was added. A real
capture failure, disconnection or revoked permission still stops our session.

## Needs physical acceptance

- Unplug/replug while the panel is visible and while a write is pending.
- Sleep/wake with preview active, stopped and another camera app open.
- Deny/revoke Camera permission for this app, then allow it again.
- Actual defaults round trip under the new name. Engine behavior is tested with
  fakes; earlier hardware controls were validated individually.

No zoom, pan or color writes were executed by the naming/hardening tests.
Preview startup selects its already-tested native capture format as usual.
No repository was created, pushed, merged, or published during that hardening
pass. Source publication and CI setup follow under separate user approval.
