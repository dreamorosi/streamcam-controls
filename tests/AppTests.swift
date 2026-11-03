import Foundation

struct TestFailure: Error { let message: String }

actor FakeBackend: CameraCommandRunning {
    struct Request: Sendable { let arguments: [String]; let deviceID: String? }
    private(set) var requests: [Request] = []
    private var waiting: [Int: CheckedContinuation<CameraStatus, Error>] = [:]

    func run(_ arguments: [String], expectedDeviceID: String?) async throws -> CameraStatus {
        let index = requests.count
        requests.append(Request(arguments: arguments, deviceID: expectedDeviceID))
        return try await withCheckedThrowingContinuation { waiting[index] = $0 }
    }

    func reply(_ index: Int, _ status: CameraStatus) { waiting.removeValue(forKey: index)!.resume(returning: status) }
    func fail(_ index: Int) { waiting.removeValue(forKey: index)!.resume(throwing: AppError(message: "Simulated USB failure")) }
}

@MainActor
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(message: message) }
}

@MainActor
func waitFor(_ condition: @escaping @MainActor () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !(await condition()) {
        if Date() > deadline { throw TestFailure(message: "Timed out waiting for a deterministic test event") }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

func cameraStatus(_ zoom: Int = 138, id: String = "connection-1") -> CameraStatus {
    CameraStatus(protocolVersion: 1, device: "Fake StreamCam", deviceId: id,
        controls: ["zoom": ControlState(value: zoom, min: 100, max: 400, step: 1,
            defaultValue: 100, writable: true, disabledByAuto: false)])
}

@MainActor
func openedModel(_ backend: FakeBackend) async throws -> CameraModel {
    let model = CameraModel(backend: backend)
    model.opened(startPreview: false)
    try await waitFor { await backend.requests.count == 1 }
    await backend.reply(0, cameraStatus())
    try await waitFor { !model.busy && model.status != nil }
    return model
}

@main
enum AppTests {
    @MainActor static func main() async {
        var passed = 0
        func run(_ name: String, _ body: @MainActor () async throws -> Void) async throws {
            try await body()
            passed += 1
            print("PASS: \(name)")
        }
        do {
            try await run("capture policy rejects stale/disconnected devices and permits shared preview") {
                for current in [false, true] {
                    for connected in [false, true] {
                        try require(CapturePolicy.mayConfigure(current: current, connected: connected)
                            == (current && connected), "Unsafe format configuration")
                    }
                }
            }
            try await run("closing invalidates pending capture and releases empty sessions") {
                let preview = PreviewController()
                let first = preview.invalidate()
                try require(preview.isCurrent(first), "New generation not current")
                let second = preview.invalidate()
                try require(!preview.isCurrent(first), "Old generation remained current")
                preview.stop()
                try require(!preview.isCurrent(second), "Stop did not invalidate generation")
                let health = await preview.health()
                try require(!health.running && !health.connected, "Stopped session retained an input")
            }
            try await run("late write result cannot overwrite a reopened panel") {
                let backend = FakeBackend()
                let model = try await openedModel(backend)
                model.command(["set", "zoom", "200"])
                try await waitFor { await backend.requests.count == 2 }
                model.closed()
                model.opened(startPreview: false)
                try await waitFor { await backend.requests.count == 3 }
                await backend.reply(2, cameraStatus(101, id: "connection-2"))
                try await waitFor { !model.busy && model.status?.deviceId == "connection-2" }
                await backend.reply(1, cameraStatus(200))
                for _ in 0..<10 { await Task.yield() }
                try require(model.status?.controls["zoom"]?.value == 101, "Stale write repainted the new panel")
                let requests = await backend.requests
                try require(requests[1].deviceID == "connection-1", "Write was not bound to its original camera")
                model.closed()
            }
            try await run("closing cancels coalesced settings and ignores stale errors") {
                let backend = FakeBackend()
                let model = try await openedModel(backend)
                model.drafts["zoom"] = 180
                model.set("zoom")
                try await waitFor { await backend.requests.count == 2 }
                model.drafts["zoom"] = 240
                model.set("zoom")
                model.closed()
                await backend.fail(1)
                for _ in 0..<10 { await Task.yield() }
                let count = await backend.requests.count
                try require(count == 2 && model.error == nil && !model.busy, "Closed panel issued a queued write or stale error")
            }
            try await run("rapid settings coalesce to the last requested value") {
                let backend = FakeBackend()
                let model = try await openedModel(backend)
                model.drafts["zoom"] = 180
                model.set("zoom")
                try await waitFor { await backend.requests.count == 2 }
                model.drafts["zoom"] = 200
                model.set("zoom")
                model.drafts["zoom"] = 240
                model.set("zoom")
                await backend.reply(1, cameraStatus(180))
                try await waitFor { await backend.requests.count == 3 }
                let requests = await backend.requests
                try require(requests[2].arguments == ["set", "zoom", "240"], "Intermediate slider value was not coalesced")
                await backend.reply(2, cameraStatus(240))
                try await waitFor { !model.busy }
                try require(model.status?.controls["zoom"]?.value == 240, "Last value was dropped")
                model.closed()
            }
            try await run("partial write errors reread real camera values") {
                let backend = FakeBackend()
                let model = try await openedModel(backend)
                model.command(["set", "zoom", "200"])
                try await waitFor { await backend.requests.count == 2 }
                await backend.fail(1)
                try await waitFor { await backend.requests.count == 3 }
                await backend.reply(2, cameraStatus(150))
                try await waitFor { !model.busy }
                try require(model.status?.controls["zoom"]?.value == 150, "UI retained an unconfirmed target")
                try require(model.error == "Simulated USB failure", "Write failure was hidden")
                model.closed()
            }
            try await run("older background refresh cannot repaint a completed write") {
                let backend = FakeBackend()
                let model = CameraModel(backend: backend, monitorInterval: 20_000_000)
                model.opened(startPreview: false)
                try await waitFor { await backend.requests.count == 1 }
                await backend.reply(0, cameraStatus())
                try await waitFor { await backend.requests.count == 2 }
                model.command(["set", "zoom", "240"])
                try await waitFor { await backend.requests.count == 3 }
                await backend.reply(2, cameraStatus(240))
                try await waitFor { !model.busy }
                await backend.reply(1, cameraStatus(138))
                // The next poll proves the previous callback was processed.
                try await waitFor { await backend.requests.count == 4 }
                try require(model.status?.controls["zoom"]?.value == 240, "An old refresh repainted the completed write")
                model.closed()
                await backend.reply(3, cameraStatus(240))
            }
            try await run("closed panel cannot send commands") {
                let backend = FakeBackend()
                let model = CameraModel(backend: backend)
                model.command(["defaults"])
                await Task.yield()
                let count = await backend.requests.count
                try require(count == 0, "Hidden panel sent a command")
            }
            try await run("unknown camera defaults decode as unavailable") {
                let data = Data("""
                {"protocolVersion":1,"device":"Fake","deviceId":"id","controls":{"zoom":{"value":138,"min":100,"max":400,"step":1,"defaultValue":null,"writable":true,"disabledByAuto":false}}}
                """.utf8)
                let status = try JSONDecoder().decode(CameraStatus.self, from: data)
                try require(status.controls["zoom"]?.defaultValue == nil, "Missing default was guessed")
            }
            try await run("helper subprocess returns data and propagates stderr") {
                let data = try HelperProcess.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["hello"])
                try require(String(data: data, encoding: .utf8) == "hello", "Subprocess output lost")
                do {
                    _ = try HelperProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'expected failure' >&2; exit 1"])
                    throw TestFailure(message: "Failed process was treated as success")
                } catch let error as AppError { try require(error.message == "expected failure", "stderr missing") }
            }
            try await run("stuck helper is terminated within its deadline") {
                let start = Date()
                do {
                    _ = try HelperProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], timeout: 0.05)
                    throw TestFailure(message: "Helper did not time out")
                } catch let error as AppError { try require(error.message.contains("timed out"), "Wrong deadline error") }
                try require(Date().timeIntervalSince(start) < 1.5, "Helper deadline was not effective")
            }
            print("\(passed) Swift checks passed. No camera accessed or settings changed.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
