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
    private var sideEffects: [(Call) -> Void] = []
    private var calls: [Call] = []
    private let defaultResponse: ProcessResult

    init(defaultResponse: ProcessResult = ProcessResult(exitCode: 0, stdout: "", stderr: "")) {
        self.defaultResponse = defaultResponse
    }

    func enqueue(_ response: ProcessResult, sideEffect: ((Call) -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        responses.append(response)
        sideEffects.append(sideEffect ?? { _ in })
    }

    /// `xcodebuild -version` 响应（缓存决策每个 execute 都会调用一次）。
    func enqueueVersion(_ version: String = "Xcode 27.0\nBuild version 27A5209h") {
        enqueue(makeProcessResult(exitCode: 0, stdout: version))
    }

    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String?
    ) async -> ProcessResult {
        lock.lock()
        let call = Call(executable: executable, arguments: arguments)
        calls.append(call)
        let response = responses.isEmpty ? defaultResponse : responses.removeFirst()
        let sideEffect = sideEffects.isEmpty ? nil : sideEffects.removeFirst()
        lock.unlock()
        sideEffect?(call)
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
