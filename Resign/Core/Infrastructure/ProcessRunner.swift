import Foundation

/// Captures a process run with stdout and stderr kept separate.
///
/// JSON-producing commands (`xcodebuild -list -json`, `-showBuildSettings -json`,
/// `devicectl --json-output`) must only parse `stdout`; `xcodebuild` routinely
/// writes warnings/notes to stderr that would otherwise corrupt the JSON payload.
struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    /// Combined output for human-readable logs and error diagnosis.
    var combined: String {
        if stderr.isEmpty { return stdout }
        if stdout.isEmpty { return stderr }
        return stdout + "\n" + stderr
    }
}

/// Abstraction over external process execution so the build pipeline can be
/// unit-tested with scripted responses instead of real Apple toolchains.
protocol ProcessRunning: Sendable {
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String?
    ) async -> ProcessResult
}

extension ProcessRunning {
    func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) async -> ProcessResult {
        await run(executable, arguments: arguments, environment: environment, currentDirectory: nil)
    }
}

/// Real Foundation.Process implementation. Arguments are passed as an array —
/// interactive user input is never concatenated into a shell string.
struct FoundationProcessRunner: ProcessRunning {
    func run(
        _ executable: String,
        arguments: [String],
        environment extra: [String: String],
        currentDirectory: String?
    ) async -> ProcessResult {
        let runningProcess = RunningProcess()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    var environment = ProcessInfo.processInfo.environment
                    environment.merge(extra) { _, new in new }
                    process.environment = environment

                    if let currentDirectory {
                        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
                    }

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    guard runningProcess.register(process) else {
                        continuation.resume(returning: ProcessResult(exitCode: 130, stdout: "", stderr: "任务已取消"))
                        return
                    }
                    defer { runningProcess.clear() }

                    do {
                        try process.run()
                        // Drain stdout and stderr in parallel so a large volume on one
                        // stream cannot deadlock the other, then join.
                        var stdoutData = Data()
                        var stderrData = Data()
                        let group = DispatchGroup()
                        DispatchQueue.global().async(group: group) {
                            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        }
                        DispatchQueue.global().async(group: group) {
                            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        }
                        group.wait()
                        process.waitUntilExit()
                        continuation.resume(returning: ProcessResult(
                            exitCode: process.terminationStatus,
                            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                            stderr: String(data: stderrData, encoding: .utf8) ?? ""
                        ))
                    } catch {
                        continuation.resume(returning: ProcessResult(exitCode: 1, stdout: "", stderr: "启动进程失败: \(error.localizedDescription)"))
                    }
                }
            }
        } onCancel: {
            runningProcess.cancel()
        }
    }
}

/// Tracks the live Process so task cancellation can terminate it.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.process = process
        return true
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true {
            running?.terminate()
        }
    }
}
