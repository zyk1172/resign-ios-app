import Foundation
import Darwin

/// Captures a process run with stdout and stderr kept separate.
///
/// JSON-producing commands (`xcodebuild -list -json`, `-showBuildSettings -json`,
/// `devicectl --json-output`) must only parse `stdout`; `xcodebuild` routinely
/// writes warnings/notes to stderr that would otherwise corrupt the JSON payload.
struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var timedOut: Bool = false

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
    func run(
        _ executable: String, arguments: [String], environment: [String: String],
        currentDirectory: String?, timeout: TimeInterval
    ) async -> ProcessResult
}

enum ProcessTimeouts {
    static let command: TimeInterval = 120
    static let discovery: TimeInterval = 30
}

extension ProcessRunning {
    func run(
        _ executable: String, arguments: [String],
        environment: [String: String] = [:], timeout: TimeInterval
    ) async -> ProcessResult {
        await run(executable, arguments: arguments, environment: environment,
                  currentDirectory: nil, timeout: timeout)
    }

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
    func run(_ executable: String, arguments: [String], environment: [String: String], currentDirectory: String?) async -> ProcessResult {
        await run(executable, arguments: arguments, environment: environment,
                  currentDirectory: currentDirectory, timeout: ProcessTimeouts.command)
    }

    func run(
        _ executable: String, arguments: [String], environment extra: [String: String],
        currentDirectory: String?, timeout: TimeInterval
    ) async -> ProcessResult {
        let running = RunningProcess()
        let limit = timeout.isFinite ? max(0.01, timeout) : ProcessTimeouts.command
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.environment = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
                    if let currentDirectory {
                        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
                    }
                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr
                    do {
                        guard try running.start(process) else {
                            continuation.resume(returning: ProcessResult(exitCode: 130, stdout: "", stderr: "任务已取消"))
                            return
                        }
                        let timer = DispatchWorkItem { running.stop(.timeout) }
                        DispatchQueue.global().asyncAfter(wallDeadline: .now() + limit, execute: timer)
                        let out = ProcessOutput()
                        let err = ProcessOutput()
                        let readers = DispatchGroup()
                        DispatchQueue.global().async(group: readers) {
                            out.data = stdout.fileHandleForReading.readDataToEndOfFile()
                        }
                        DispatchQueue.global().async(group: readers) {
                            err.data = stderr.fileHandleForReading.readDataToEndOfFile()
                        }
                        readers.wait()
                        process.waitUntilExit()
                        timer.cancel()
                        let reason = running.finish()
                        let timeoutMessage = reason == .timeout
                            ? "\nProcess timed out after \(limit)s：执行超时，已终止本次命令及其进程组。" : ""
                        continuation.resume(returning: ProcessResult(
                            exitCode: reason == .timeout ? 124 : (reason == .cancelled ? 130 : process.terminationStatus),
                            stdout: String(decoding: out.data, as: UTF8.self),
                            stderr: String(decoding: err.data, as: UTF8.self) + timeoutMessage,
                            timedOut: reason == .timeout
                        ))
                    } catch {
                        _ = running.finish()
                        continuation.resume(returning: ProcessResult(exitCode: 1, stdout: "", stderr: "启动进程失败: \(error.localizedDescription)"))
                    }
                }
            }
        } onCancel: {
            running.stop(.cancelled)
        }
    }
}

/// Each buffer has one writer; readers are joined before accessing its data.
private final class ProcessOutput: @unchecked Sendable {
    var data = Data()
}

private final class RunningProcess: @unchecked Sendable {
    enum StopReason { case cancelled, timeout }
    private let lock = NSLock()
    private let termination = DispatchGroup()
    private var process: Process?
    private var reason: StopReason?
    private var cancelledBeforeStart = false
    private var ownedGroup: pid_t?

    func start(_ process: Process) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelledBeforeStart else { return false }
        // Launch under the same lock as cancellation: cancellation cannot fall
        // between registration and Process.run(), leaving an uncancelled child.
        try process.run()
        self.process = process
        let pid = process.processIdentifier
        // Darwin Foundation launches Process in its own group. Never signal a
        // group unless ownership was verified; especially never our own group.
        let group = getpgid(pid)
        // A very short-lived parent may already have been reaped while its
        // children still hold the pipes. Its surviving group still has pid as
        // its identifier; never fall back to signalling our caller's group.
        if pid > 0 && pid != getpgrp()
            && (group == pid || (group == -1 && kill(-pid, 0) == 0)) {
            ownedGroup = pid
        }
        return true
    }

    func stop(_ reason: StopReason) {
        lock.lock()
        defer { lock.unlock() }
        guard let process else {
            if reason == .cancelled { cancelledBeforeStart = true }
            return
        }
        guard self.reason == nil else { return }
        self.reason = reason
        termination.enter()
        signal(process, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.75) {
            self.lock.lock()
            if let process = self.process { self.signal(process, SIGKILL) }
            self.lock.unlock()
            self.termination.leave()
        }
    }

    private func signal(_ process: Process, _ signal: Int32) {
        if let ownedGroup { _ = kill(-ownedGroup, signal) }
        else if process.isRunning { _ = kill(process.processIdentifier, signal) }
    }

    func finish() -> StopReason? {
        lock.lock()
        let result = reason
        if result == nil {
            process = nil
            lock.unlock()
            return nil
        }
        lock.unlock()
        // A descendant may close its output pipes yet ignore TERM. Complete
        // the group escalation before returning and releasing the build lock.
        termination.wait()
        lock.lock()
        process = nil
        lock.unlock()
        return result
    }
}
