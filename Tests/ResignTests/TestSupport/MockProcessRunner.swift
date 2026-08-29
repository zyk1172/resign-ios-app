import Foundation
@testable import Resign

/// Scripted process runner: pops enqueued responses in order, records every
/// call. Lets BuildCoordinator/AppInstaller be tested without real toolchains.
final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var responses: [ProcessResult] = []
    private var calls: [Call] = []
    private let defaultResponse: ProcessResult

    init(defaultResponse: ProcessResult = ProcessResult(exitCode: 0, stdout: "", stderr: "")) {
        self.defaultResponse = defaultResponse
    }

    func enqueue(_ response: ProcessResult) {
        lock.lock()
        defer { lock.unlock() }
        responses.append(response)
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String?
    ) async -> ProcessResult {
        lock.lock()
        calls.append(Call(executable: executable, arguments: arguments))
        let response = responses.isEmpty ? defaultResponse : responses.removeFirst()
        lock.unlock()
        return response
    }

    var recordedCalls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func calls(to executableSuffix: String) -> [Call] {
        recordedCalls.filter { $0.executable.hasSuffix(executableSuffix) }
    }
}

func makeProcessResult(exitCode: Int32, stdout: String = "", stderr: String = "") -> ProcessResult {
    ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
}
