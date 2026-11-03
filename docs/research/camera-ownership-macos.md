# Detecting another camera client on macOS

Research date: 2026-11-03. Target: Logitech StreamCam USB `046d:0893`, Apple Silicon, native macOS 26. StreamCamControls already runs an AVFoundation 640×360 preview and separately sends Rust/nusb UVC controls.

This is documentation research, not a hardware test. The user reported that opening Zoom's camera preview after ours starts leaves both previews running and does not trigger our intended yield. That does **not** establish the property's actual value, a broken monitor, or a driver defect. The main agent is investigating those separately. No app code, camera, screen, processes, Zoom settings, or logs were inspected.

## Decision

`AVCaptureDevice.isInUseByAnotherApplication` is the public Apple API expressly intended to report another app's use. Apple documents KVO for starts and stops. Neither its documentation nor the inspected SDK header states an exclusive-access-only limitation, an exception while our session runs, or a UVC sharing exception. Do not invent one to explain the reported behavior. [1][2]

If the main agent confirms that this property stays false during verified simultaneous capture of this exact camera, the sources below provide **no guaranteed drop-in replacement for foreign-session detection while our preview remains active**. CoreMediaIO exposes aggregate running state and exclusive ownership, not a generic shared-client count or client list. A truthful product fallback is an explicit Preview toggle, with any automatic pause described as best effort. This is a limit of the verified public contracts, not a claim that all possible implementations have been disproved. [3][4][7]

## What the APIs actually tell us

| API | Verified contract | Use while our preview runs |
| --- | --- | --- |
| `AVCaptureDevice.isInUseByAnotherApplication` | Boolean indicating another application's use; KVO supported. Available on macOS 10.7+, also Mac Catalyst 14+. Not an iOS camera API. [1][2] | The correct documented signal. It supplies no PID, client count, deadline, reservation, or handoff operation. A read cannot prevent a later client from starting. |
| `kCMIODevicePropertyDeviceIsRunning`, `'goin'` | `UInt32`, 0 means the CMIODevice is not performing IO, 1 means it is. [3] | An IO-state flag, not an another-app flag. The header does not explicitly define this as "current process only"; do not present that stronger claim as established for Apple's current UVC extension. |
| `kCMIODevicePropertyDeviceIsRunningSomewhere`, `'gone'` | `UInt32`, 1 means running in **at least one process on the system**, 0 means not running at all. [3] | Our own running capture already satisfies "at least one." One versus two clients yields the same documented value. Cannot subtract our Boolean from this Boolean to recover another client's presence. |
| `kCMIODevicePropertyHogMode`, `'oink'` | `pid_t`, exclusive-access owner's PID; `-1` means available to all processes. [3] | A foreign PID identifies exclusive ownership, not ordinary shared capture. `-1` does not mean idle. Do not set hog mode as a detector; that changes access policy. |
| `kCMIODevicePropertyDeviceControl`, `'pmnh'` | `pid_t`, exclusive rights to change operating properties; `-1` means not controlled by a client. Old `DeviceMaster` is deprecated in favor of this name. [3] | Configuration control is not a list of streaming consumers. Not a reliable substitute for camera-use detection. |
| `kCMIOObjectPropertyOwner` / `OwnedObjects` | CMIO object ownership and contained objects, expressed as CMIOObjectIDs. [4] | Not process ownership or a camera-client enumeration API. |
| `CMIOExtensionProvider.connectedClients` / `CMIOExtensionStream.streamingClients` | Public, KVO-observable client arrays on extension-provider/stream objects, available on macOS 12.3+. `CMIOExtensionClient.pid` exists. [7] | These belong to the camera extension that publishes the device/stream. They are not getters for the clients of an arbitrary system USB camera. |

### "Global" scope is not "all applications"

`kCMIOObjectPropertyScopeGlobal` means properties applying to **the object as a whole**, as opposed to its input/output sections. `kCMIOObjectPropertyElementMain` is element 0. These are address components, not PID selectors. Neither switching scope nor supplying an undocumented PID qualifier turns `'goin'` into a query for another app. Only `'gone'` explicitly promises system-wide aggregate running state in this header. [3][4]

For a future read-only CMIO check, use the correct device, global/main address where supported, `CMIOObjectHasProperty`, `CMIOObjectGetPropertyDataSize` / `CMIOObjectGetPropertyData`, and property listeners. Check support, returned sizes, and OSStatus; unsupported or failed reads are **unknown**, not idle. The SDK warns that objects need not implement every inherited selector. Listeners report property changes, not client arrivals: aggregate state can remain 1 when a second client joins. These public C functions are available on native macOS; no Screen Recording, Accessibility, or root requirement appears in these declarations. This does not waive ordinary camera privacy requirements or guarantee every property on this camera. [4]

No generic `kCMIODevicePropertyClientCount`, shared-client PID-list property, or public "get extension provider for this AVCaptureDevice" getter was found in the inspected public hardware headers and extension APIs. The extension arrays must not be repackaged as an arbitrary-device enumeration API. [3][4][7]

## Sharing is supported, not an automatic handoff protocol

Apple explicitly warns that holding `lockForConfiguration` unnecessarily can degrade capture quality in "other applications sharing the device." It is a configuration lock, not an ownership detector. [2]

Apple's camera engineering presentation explains that the extension framework can deliver buffers to "multiple simultaneous clients," and that Apple provides a class-compliant extension for UVC cameras. It also describes AVFoundation as a client of public CMIO APIs over private translation/IPC layers. That supports sharing as an architecture, not a promise to interrupt the first consumer when a second joins, or expose private attribution records to another app. It does not establish the exact implementation or property behavior of StreamCam on macOS 26. [5]

## Notifications and privacy APIs

- `AVCaptureSession.wasInterruptedNotification` and `interruptionEndedNotification` are available on macOS 10.14+. They report an interruption of the observed session. Apple does not promise an interruption for successful concurrent sharing. `runtimeErrorNotification` is available on macOS 10.7+ and reports session failures, not a new shared consumer. [6]
- **Native macOS trap:** `AVCaptureSessionInterruptionReason`, including `videoDeviceInUseByAnotherClient`, and `AVCaptureSessionInterruptionReasonKey` are marked `API_UNAVAILABLE(macos)` in the macOS 26.5 SDK. `AVCaptureSession.isInterrupted` is also unavailable on native macOS. Mac Catalyst availability is not native AppKit availability. Do not import the iOS reason-based recipe. [6]
- Device connected/disconnected notifications report device availability, not another client's camera start/stop. `isSuspended` reports suspension, such as a closed privacy iris, not foreign usage. [2]
- `AVCaptureDevice.authorizationStatus(for:)`, macOS 10.14+, reports **our app's permission**, not live usage by Zoom or another app. System Settings' Camera list records apps that requested access, not current stream consumers. [8]
- Apple documents a green Control Center camera indicator and a user-visible privacy panel that may identify using apps. That is UI documentation, not a public programmatic client-enumeration API, and the indicator alone is already satisfied by our preview. No public getter or camera-usage notification for that privacy panel was verified. Scraping it would violate this task's screen/Accessibility constraints. [9]

## Actionable choices

1. **Keep the documented signal, verify it honestly.** KVO is documented for `isInUseByAnotherApplication`; polling can supplement it but a two-second poll is not a documented handoff guarantee. If the main agent observes a real false negative, report it as behavior on this OS/device combination, not an Apple-documented exclusive-only rule. [1][2]
2. **Make Preview on/off explicit.** Preview off should stop our capture, not merely hide the layer. Keep the control UI independent of preview. Apple documents `stopRunning` as stopping data flow; it does not promise a cross-app handoff transaction. Input construction itself attempts to open the device, so an ownership-sensitive "off" design should consider releasing unused capture inputs too. Continued Rust controls and release timing still need the main agent's separate validation. [10]
3. **Optional advisory automatic pause.** Pause on a verified positive foreign-use signal or our actual interruption/failure. A background/window-hidden pause can be an opt-in convenience policy, but is not camera-activity detection. Never label "Zoom is open/frontmost" as "Zoom is using this camera."
4. **Optional check only while our capture is off.** If `'gone'` is supported and faithfully implemented, a value of 1 after our capture has actually ceased means the device still runs somewhere. This can guide whether to restart. It cannot detect the second client while our own capture keeps that same flag at 1. Temporary stop-and-check is disruptive, racy, and not a continuous-detection guarantee. [3]
5. **Different architecture only if requirements demand it.** A camera extension we own can observe its own `streamingClients` and client PIDs. Clients must select that published camera, so this does not detect apps that bypass it and select the physical StreamCam. It entails extension installation/activation and permissions, not a small monitoring fix; do not pursue without a separate product decision. [5][7]

## Later runtime evidence and product decision

The main session subsequently inspected the running app while the user had
Zoom's preview open. The usage monitor was active, the camera connected, and
both its sampled signal and a direct `isInUseByAnotherApplication` read were
false. The user verified that Zoom selected the same Logitech StreamCam and
that a slider adjustment affected both live images. This establishes the
observed false negative on this setup; it does not change Apple's documented
contract or prove a universal UVC exception.

The user chose to allow both previews. The app no longer promises automatic
yielding or treats this property as a mandatory sharing gate. Explicit preview
stop remains available. No heuristics, private APIs or extra permissions were
introduced. The original research above remains distinct from these later
runtime observations.

## Primary sources

SDK citations below refer to Apple's installed `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/`. The default SDK is 27.0, so target-sensitive declarations were checked against the explicit 26.5 SDK. SDK inspection is not a runtime test on the user's macOS minor release.

1. Apple, [`AVCaptureDevice.isInUseByAnotherApplication`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isinusebyanotherapplication). Verified text and availability through [Apple's documentation JSON](https://developer.apple.com/tutorials/data/documentation/avfoundation/avcapturedevice/isinusebyanotherapplication.json).
2. Apple SDK, [`AVFoundation.framework/Headers/AVCaptureDevice.h`](file:///Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/AVFoundation.framework/Headers/AVCaptureDevice.h), especially lines 208–272 and device notification declarations. [`lockForConfiguration`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lockforconfiguration()).
3. Apple SDK, [`CoreMediaIO.framework/Headers/CMIOHardwareDevice.h`](file:///Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Headers/CMIOHardwareDevice.h), lines 372–505. Public symbols: [`DeviceIsRunning`](https://developer.apple.com/documentation/coremediaio/kcmiodevicepropertydeviceisrunning), [`DeviceIsRunningSomewhere`](https://developer.apple.com/documentation/coremediaio/kcmiodevicepropertydeviceisrunningsomewhere), [`HogMode`](https://developer.apple.com/documentation/coremediaio/kcmiodevicepropertyhogmode). Online symbol pages omit the detailed semantics; the SDK comments supply them.
4. Apple SDK, [`CoreMediaIO.framework/Headers/CMIOHardwareObject.h`](file:///Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/CoreMediaIO.framework/Headers/CMIOHardwareObject.h), selector/scope definitions, global/main definitions at lines 175–198, object ownership definitions, property-read/listener functions and availability. Also `CMIOHardwareStream.h` for stream selectors.
5. Apple Camera Software Engineering, [WWDC22 session 10022, Create camera extensions with Core Media IO](https://developer.apple.com/videos/play/wwdc2022/10022/), transcript sections on technology overview, UVC extension, API architecture, attribution and providers.
6. Apple SDK, [`AVFoundation.framework/Headers/AVCaptureSession.h`](file:///Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/AVFoundation.framework/Headers/AVCaptureSession.h), lines 19–116 and `interrupted` declaration at line 519.
7. Apple, [`connectedClients`](https://developer.apple.com/documentation/coremediaio/cmioextensionprovider/connectedclients), [`streamingClients`](https://developer.apple.com/documentation/coremediaio/cmioextensionstream/streamingclients), [`CMIOExtensionClient`](https://developer.apple.com/documentation/coremediaio/cmioextensionclient), and [Creating a camera extension with Core Media I/O](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o). These describe extension-owned objects, construction, publication, installation and activation.
8. Apple, [`authorizationStatus(for:)`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:)) and [Control access to the camera on Mac](https://support.apple.com/guide/mac-help/control-access-to-the-camera-mchlf6d108da/mac).
9. Apple, [Use Control Center on Mac](https://support.apple.com/guide/mac-help/use-control-center-mchl50f94f8f/mac), privacy-indicator and Privacy-window description. The live support page currently renders the latest macOS guide; it is cited for UI behavior, not macOS 26 API availability.
10. Apple SDK, `AVCaptureSession.h`, `stopRunning` discussion, and [`AVCaptureInput.h`](file:///Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/AVFoundation.framework/Headers/AVCaptureInput.h), lines 188–203, `deviceInputWithDevice:error:` discussion. Apple, [`stopRunning()`](https://developer.apple.com/documentation/avfoundation/avcapturesession/stoprunning()).
