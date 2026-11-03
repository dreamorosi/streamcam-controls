import Foundation

/// The helper is bounded independently of per-transfer USB timeouts. Normal
/// cancellation never interrupts a write; a genuinely stuck process times out.
enum HelperProcess {
    private final class Deadline: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var fired = false
        init(_ process: Process) { self.process = process }
        func expire() {
            lock.lock()
            defer { lock.unlock() }
            if process.isRunning {
                fired = true
                process.terminate()
            }
        }
        var timedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
    }

    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 15) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Deadline(process)
        let timer = DispatchWorkItem { deadline.expire() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if deadline.timedOut {
            throw AppError(message: "Camera helper timed out. A setting may have changed; reopen the panel to read the actual state.")
        }
        guard process.terminationStatus == 0 else {
            let text = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError(message: text?.isEmpty == false ? text! : "Camera command failed.")
        }
        return data
    }
}
