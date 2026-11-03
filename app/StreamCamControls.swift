// StreamCam Controls: native preview with direct USB camera controls.
import AppKit
import AVFoundation
import Combine
import CoreMedia
import SwiftUI

struct ControlState: Decodable, Sendable {
    let value: Int
    let min: Int
    let max: Int
    let step: Int
    let defaultValue: Int?
    let writable: Bool
    let disabledByAuto: Bool
}

struct CameraStatus: Decodable, Sendable {
    let protocolVersion: Int
    let device: String
    let deviceId: String
    let controls: [String: ControlState]
}

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol CameraCommandRunning: Sendable {
    func run(_ arguments: [String], expectedDeviceID: String?) async throws -> CameraStatus
}

actor CameraBackend: CameraCommandRunning {
    func run(_ arguments: [String], expectedDeviceID: String? = nil) async throws -> CameraStatus {
        // A cancelled queued write must not start. An already-running helper
        // finishes its bounded transaction rather than being cancelled mid-write.
        try Task.checkCancellation()
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("streamcam") else {
            throw AppError(message: "The bundled camera helper is missing.")
        }
        let args = expectedDeviceID.map { ["--device-id", $0] + arguments } ?? arguments
        let data = try HelperProcess.run(executable: executable, arguments: args)
        let status = try JSONDecoder().decode(CameraStatus.self, from: data)
        guard status.protocolVersion == 1 else { throw AppError(message: "Unsupported helper protocol.") }
        if let expectedDeviceID, status.deviceId != expectedDeviceID {
            throw AppError(message: "Camera connection changed during the command.")
        }
        return status
    }
}

struct CapturePolicy {
    static func mayConfigure(current: Bool, connected: Bool) -> Bool {
        current && connected
    }
}

struct PreviewHealth {
    let running: Bool
    let connected: Bool
}

// Capture work stays off the main thread. A generation invalidates pending
// starts when the panel closes, including while a permission prompt is open.
final class PreviewController: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "StreamCamControls.capture")
    private let lock = NSLock()
    private var generation = 0

    func invalidate() -> Int {
        lock.lock()
        generation += 1
        let value = generation
        lock.unlock()
        return value
    }

    func isCurrent(_ value: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == generation
    }

    func start(deviceID: String, generation: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.isCurrent(generation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
                    guard let device = discovery.devices.first(where: { $0.uniqueID == deviceID }) else {
                        throw AppError(message: "The selected StreamCam disconnected before preview started.")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    self.session.beginConfiguration()
                    for old in self.session.inputs { self.session.removeInput(old) }
                    self.session.sessionPreset = .high
                    guard self.session.canAddInput(input) else {
                        self.session.commitConfiguration()
                        throw AppError(message: "StreamCam preview cannot start. Try closing QuickTime or another camera app.")
                    }
                    self.session.addInput(input)
                    self.session.commitConfiguration()
                    guard self.isCurrent(generation) else {
                        self.session.beginConfiguration()
                        self.session.removeInput(input)
                        self.session.commitConfiguration()
                        throw CancellationError()
                    }
                    self.session.startRunning()
                    // The panel can close or the device can disconnect while
                    // startRunning blocks. Shared capture is permitted; usage
                    // flags are not a reliable shared-client detector here.
                    guard CapturePolicy.mayConfigure(current: self.isCurrent(generation),
                        connected: device.isConnected) else {
                        throw CancellationError()
                    }
                    // A high-resolution capture limited this StreamCam's visible
                    // hardware zoom. The user verified the complete 100...400
                    // range with this native 640×360 preview format. Select it
                    // after startup, since session startup overwrote earlier
                    // activeFormat assignments. No preview-only crop is added.
                    guard let format = device.formats.first(where: {
                        let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                        return size.width == 640 && size.height == 360
                    }) else {
                        throw AppError(message: "Camera has no supported 640×360 preview format.")
                    }
                    try device.lockForConfiguration()
                    device.activeFormat = format
                    device.unlockForConfiguration()
                    let selected = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    guard selected.width == 640 && selected.height == 360 else {
                        throw AppError(message: "Camera did not retain the requested preview format.")
                    }
                    guard self.session.isRunning else {
                        throw AppError(message: "Preview did not start. Camera controls are still available.")
                    }
                    continuation.resume()
                } catch {
                    self.stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        _ = invalidate()
        queue.async { self.stopOnQueue() }
    }

    private func stopOnQueue() {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
    }

    func health() async -> PreviewHealth {
        await withCheckedContinuation { continuation in
            queue.async {
                let device = (self.session.inputs.first as? AVCaptureDeviceInput)?.device
                continuation.resume(returning: PreviewHealth(running: self.session.isRunning,
                    connected: device?.isConnected == true))
            }
        }
    }

    func aspectRatio() async -> Double {
        await withCheckedContinuation { continuation in
            queue.async {
                if let input = self.session.inputs.first as? AVCaptureDeviceInput {
                    let size = CMVideoFormatDescriptionGetDimensions(input.device.activeFormat.formatDescription)
                    if size.width > 0, size.height > 0 {
                        continuation.resume(returning: Double(size.width) / Double(size.height))
                        return
                    }
                }
                continuation.resume(returning: 16.0 / 9.0)
            }
        }
    }
}

@MainActor
final class CameraModel: ObservableObject {
    @Published var status: CameraStatus?
    @Published var drafts: [String: Int] = [:]
    @Published var busy = false
    @Published var previewRunning = false
    @Published var previewAspectRatio = 16.0 / 9.0
    @Published var error: String?
    @Published var tab = "Framing"
    @Published var confirmDefaults = false

    let preview = PreviewController()
    private let backend: any CameraCommandRunning
    private var visible = false
    private var panelGeneration = 0
    private var previewGeneration = 0
    private var openTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var previewWanted = false
    private var editingControl: String?
    private var pendingSets: [(name: String, value: Int, deviceID: String)] = []
    private var commandRevision = 0
    private let monitorInterval: UInt64
    private(set) var monitorTicks = 0
    private(set) var lastPreviewHealth: PreviewHealth?

    init(backend: any CameraCommandRunning = CameraBackend(), monitorInterval: UInt64 = 2_000_000_000) {
        self.backend = backend
        self.monitorInterval = monitorInterval
    }

    var autoWhiteBalance: Bool { (drafts["auto-white-balance"] ?? 1) != 0 }

    private func accept(_ status: CameraStatus) {
        let editingValue = editingControl.flatMap { drafts[$0] }
        self.status = status
        drafts = status.controls.mapValues(\.value)
        if let editingControl, let editingValue { drafts[editingControl] = editingValue }
        for pending in pendingSets where pending.deviceID == status.deviceId { drafts[pending.name] = pending.value }
    }

    func opened(startPreview: Bool = true) {
        openTask?.cancel()
        monitorTask?.cancel()
        visible = true
        panelGeneration += 1
        let generation = panelGeneration
        error = nil
        status = nil
        drafts = [:]
        busy = true
        previewWanted = startPreview
        openTask = Task {
            defer { if generation == panelGeneration { busy = false } }
            do {
                let current = try await backend.run(["status"], expectedDeviceID: nil)
                guard visible, generation == panelGeneration else { return }
                accept(current)
            } catch {
                guard visible, generation == panelGeneration else { return }
                self.error = error.localizedDescription
            }
            guard visible, generation == panelGeneration, status != nil else { return }
            if startPreview { await self.startPreview() }
            // Capture startup can affect device values. Display a fresh read.
            if startPreview, visible, generation == panelGeneration, let current = try? await backend.run(["status"], expectedDeviceID: status?.deviceId) {
                accept(current)
            }
        }
        startMonitoring()
    }

    func closed() {
        visible = false
        panelGeneration += 1
        previewGeneration += 1
        openTask?.cancel()
        commandTask?.cancel()
        monitorTask?.cancel()
        pendingSets.removeAll()
        editingControl = nil
        previewWanted = false
        busy = false
        previewRunning = false
        preview.stop()
    }

    private func startMonitoring() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.monitorInterval else { return }
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard let self, self.visible else { return }
                self.monitorTicks += 1
                let generation = self.panelGeneration
                if self.previewRunning {
                    let health = await self.preview.health()
                    self.lastPreviewHealth = health
                    guard self.visible, generation == self.panelGeneration else { continue }
                    if !health.connected || !health.running
                        || AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                        self.previewGeneration += 1
                        self.previewRunning = false
                        self.preview.stop()
                        if !health.connected {
                            self.status = nil
                            self.drafts = [:]
                            self.error = "StreamCam disconnected. Waiting for it to reconnect."
                        } else {
                            self.previewWanted = false
                            self.error = "Preview stopped. Check Camera permission, then start preview to retry."
                        }
                    }
                }
                guard !self.busy, self.editingControl == nil else { continue }
                let revision = self.commandRevision
                do {
                    let current = try await self.backend.run(["status"], expectedDeviceID: nil)
                    guard self.visible, generation == self.panelGeneration, revision == self.commandRevision,
                        !self.busy, self.editingControl == nil else { continue }
                    let reconnected = self.status == nil || self.status?.deviceId != current.deviceId
                    if self.status?.deviceId != current.deviceId && self.previewRunning {
                        self.previewRunning = false
                        self.preview.stop()
                    }
                    self.accept(current)
                    if reconnected {
                        self.error = nil
                        if self.previewWanted { await self.startPreview() }
                    }
                } catch {
                    guard self.visible, generation == self.panelGeneration, revision == self.commandRevision, !self.busy else { continue }
                    // A busy lock is temporary. Don't replace working controls
                    // with an error while a cooperating CLI command runs.
                    if !error.localizedDescription.contains("command is running") {
                        self.status = nil
                        self.drafts = [:]
                        self.previewRunning = false
                        self.preview.stop()
                        self.error = error.localizedDescription
                    }
                }
            }
        }
    }

    func startPreview() async {
        previewGeneration += 1
        let request = previewGeneration
        let captureGeneration = preview.invalidate()
        do {
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorized = true
            case .notDetermined:
                authorized = await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
                }
            default: authorized = false
            }
            guard visible, request == previewGeneration else { return }
            guard authorized else {
                throw AppError(message: "Allow StreamCam Controls in System Settings > Privacy & Security > Camera to see the preview.")
            }
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            let devices = discovery.devices.filter { $0.localizedName.lowercased().contains("streamcam") }
            guard devices.count == 1, let device = devices.first else {
                throw AppError(message: "Preview needs exactly one StreamCam. It will not use a different camera.")
            }
            try await preview.start(deviceID: device.uniqueID, generation: captureGeneration)
            let ratio = await preview.aspectRatio()
            guard visible, request == previewGeneration else { return }
            previewAspectRatio = ratio
            previewRunning = true
        } catch is CancellationError {
            // Closing the panel cancels pending preview startup.
        } catch {
            guard visible, request == previewGeneration else { return }
            self.error = error.localizedDescription
            previewWanted = false
            preview.stop()
        }
    }

    func togglePreview() {
        if previewRunning {
            previewWanted = false
            previewGeneration += 1
            previewRunning = false
            preview.stop()
        } else {
            previewWanted = true
            let generation = panelGeneration
            busy = true
            Task {
                defer { if generation == panelGeneration { busy = false } }
                await startPreview()
            }
        }
    }

    func command(_ arguments: [String]) {
        guard visible, !busy, let deviceID = status?.deviceId else { return }
        let generation = panelGeneration
        commandRevision += 1
        busy = true
        error = nil
        commandTask = Task {
            defer {
                if generation == panelGeneration {
                    busy = false
                    if !pendingSets.isEmpty {
                        let pending = pendingSets.removeFirst()
                        if pending.deviceID == status?.deviceId {
                            command(["set", pending.name, String(pending.value)])
                        } else { pendingSets.removeAll() }
                    }
                }
            }
            do {
                let current = try await backend.run(arguments, expectedDeviceID: deviceID)
                guard visible, generation == panelGeneration, status?.deviceId == deviceID else { return }
                accept(current)
            } catch {
                guard visible, generation == panelGeneration else { return }
                self.error = error.localizedDescription
                pendingSets.removeAll()
                // An operation can partly succeed. Display real state afterward.
                if let current = try? await backend.run(["status"], expectedDeviceID: deviceID) {
                    guard visible, generation == panelGeneration else { return }
                    accept(current)
                } else if visible, generation == panelGeneration {
                    status = nil
                    drafts = [:]
                }
            }
        }
    }

    func set(_ name: String) {
        guard visible, let value = drafts[name], let deviceID = status?.deviceId else { return }
        if busy {
            if let index = pendingSets.firstIndex(where: { $0.name == name && $0.deviceID == deviceID }) {
                pendingSets[index].value = value
            } else { pendingSets.append((name, value, deviceID)) }
            return
        }
        command(["set", name, String(value)])
    }

    func editing(_ name: String, began: Bool) {
        editingControl = began ? name : nil
        if !began { set(name) }
    }

    func setAutomatic(_ enabled: Bool) {
        command(["set", "auto-white-balance", enabled ? "1" : "0"])
    }
}

final class PreviewView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    var connectionActive: Bool { previewLayer.connection?.isActive == true }
    var videoFrame: CGRect { previewLayer.frame }
    var videoRect: CGRect {
        previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ nsView: PreviewView, context: Context) {}
}

struct CameraPanel: View {
    @ObservedObject var model: CameraModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "camera.aperture").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("StreamCam Controls").font(.headline)
                    Text("Native camera controls").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help("Quit and stop preview")
            }

            ZStack {
                CameraPreview(session: model.preview.session)
                if !model.previewRunning {
                    Color.black
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash").font(.largeTitle)
                        Text("Preview off").font(.headline)
                        Text("No recording. No microphone.").font(.caption)
                    }.foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(height: 404 / model.previewAspectRatio).clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                Circle().fill(model.previewRunning ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text(model.previewRunning ? "Live preview" : "Camera preview stopped").font(.caption)
                Spacer()
                Button(model.previewRunning ? "Stop preview" : "Start preview") { model.togglePreview() }
                    .disabled(model.status == nil || model.busy)
            }

            Picker("Controls", selection: $model.tab) {
                Text("Framing").tag("Framing")
                Text("Color").tag("Color")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                .frame(maxWidth: .infinity)

            VStack(spacing: 14) {
                if model.tab == "Framing" {
                    control("zoom", label: "Zoom")
                    control("pan", label: "Pan", degrees: true)
                    control("tilt", label: "Tilt", degrees: true)
                } else {
                    control("saturation", label: "Saturation")
                    Toggle("Automatic white balance", isOn: Binding(
                        get: { model.autoWhiteBalance }, set: { model.setAutomatic($0) }))
                        .disabled(model.busy || model.status?.controls["auto-white-balance"]?.writable != true)
                    control("white-balance", label: "White balance", kelvin: true)
                }
            }.frame(height: 150, alignment: .top)

            Divider()
            HStack {
                Spacer()
                Button("Defaults…") { model.confirmDefaults = true }.disabled(model.status == nil || model.busy)
            }
            .confirmationDialog("Restore the supported camera-control defaults?", isPresented: $model.confirmDefaults) {
                Button("Restore defaults", role: .destructive) {
                    model.command(["defaults"])
                }
            } message: { Text("This changes zoom, pan/tilt, saturation, and white balance. It is not a whole-device factory reset.") }

            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
            }
        }
        .padding(18).frame(width: 440)
    }

    @ViewBuilder
    private func control(_ name: String, label: String, degrees: Bool = false, kelvin: Bool = false) -> some View {
        if let state = model.status?.controls[name], state.min < state.max, state.step > 0 {
            let value = model.drafts[name] ?? state.value
            VStack(spacing: 4) {
                HStack {
                    Text(label).font(.subheadline)
                    Spacer()
                    Text(degrees ? String(format: "%.0f°", Double(value) / 3600) : "\(value)\(kelvin ? " K" : "")")
                        .font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(min(max(model.drafts[name] ?? state.value, state.min), state.max)) },
                    set: { model.drafts[name] = Int($0.rounded()) }),
                    in: Double(state.min)...Double(state.max), step: Double(state.step),
                    onEditingChanged: { model.editing(name, began: $0) })
                    .disabled(model.busy || !state.writable || (kelvin && model.autoWhiteBalance))
            }
        } else {
            HStack { Text(label); Spacer(); Text("Unavailable").foregroundStyle(.secondary) }
        }
    }
}

final class CameraWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: CameraWindow!
    private let model = CameraModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "StreamCam Controls")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePanel)
        }
        let smallestScreenHeight = NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 800
        let height = min(610, smallestScreenHeight - 60)
        panel = CameraWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: height),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "StreamCam Controls"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.delegate = self
        // Size before positioning. Letting the hosting view grow an already
        // presented popover placed its preview above the menu-bar screen.
        panel.contentViewController = NSHostingController(rootView:
            ScrollView { CameraPanel(model: model) }.frame(width: 440, height: height))
        panel.setContentSize(NSSize(width: 440, height: height))
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(inspectionRequested),
            name: Notification.Name("com.dreamorosi.streamcam-controls.inspect"), object: nil)
        if CommandLine.arguments.contains("--inspect-open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.togglePanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    self.inspectWindow()
                    if CommandLine.arguments.contains("--inspect-close") {
                        self.panel.performClose(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.inspectWindow(closed: true) }
                    }
                }
            }
        }
    }

    @objc private func inspectionRequested(_ notification: Notification) { inspectWindow() }

    private func inspectWindow(closed: Bool = false) {
        func rect(_ value: NSRect) -> [String: Double] {
            ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
        }
        func findPreview(_ view: NSView) -> PreviewView? {
            if let preview = view as? PreviewView { return preview }
            for child in view.subviews { if let found = findPreview(child) { return found } }
            return nil
        }
        var output: [String: Any] = ["previewRunning": model.previewRunning,
            "sessionRunning": model.preview.session.isRunning,
            "captureInputs": model.preview.session.inputs.count,
            "busy": model.busy, "error": model.error ?? "",
            "cameraPermission": AVCaptureDevice.authorizationStatus(for: .video).rawValue,
            "panelShown": panel.isVisible,
            "previewPolicy": "shared",
            "monitorTicks": model.monitorTicks,
            "controlsAvailable": model.status?.controls.count ?? 0]
        if let health = model.lastPreviewHealth {
            output["polledCameraConnected"] = health.connected
        }
        if panel.isVisible, let root = panel.contentViewController?.view {
            let window = panel!
            output["window"] = rect(window.frame)
            output["screen"] = rect((window.screen ?? NSScreen.main)!.visibleFrame)
            output["movable"] = window.isMovable
            output["movableByBackground"] = window.isMovableByWindowBackground
            output["hasTitleBar"] = window.styleMask.contains(.titled)
            output["rootFrame"] = rect(root.frame)
            if let preview = findPreview(root) {
                output["preview"] = rect(window.convertToScreen(preview.convert(preview.bounds, to: nil)))
                output["previewVisibleRect"] = rect(preview.visibleRect)
                output["previewLayer"] = rect(preview.videoFrame)
                output["previewVideoRect"] = rect(preview.videoRect)
                output["previewConnectionActive"] = preview.connectionActive
            }
        }
        if let input = model.preview.session.inputs.first as? AVCaptureDeviceInput {
            let device = input.device
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            output["videoDimensions"] = ["width": dimensions.width, "height": dimensions.height]
            output["capturePreset"] = model.preview.session.sessionPreset.rawValue
            output["otherAppUsingCamera"] = device.isInUseByAnotherApplication
            output["availableDimensions"] = Array(Set(device.formats.map {
                let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return "\(size.width)x\(size.height)"
            })).sorted()
            output["zoomValue"] = model.status?.controls["zoom"]?.value
        }
        let filename = closed ? "window-closed-diagnostic.json" : "window-diagnostic.json"
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(filename)
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.performClose(nil); return }
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let point = NSPoint(x: anchor.midX, y: anchor.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? buttonWindow.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = panel.frame.size
        let x = min(max(anchor.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(anchor.minY - size.height - 8, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.opened()
    }

    func windowWillClose(_ notification: Notification) { model.closed() }
    func applicationWillTerminate(_ notification: Notification) { model.closed() }
}

#if !TESTING
@main
enum StreamCamControls {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
