import Foundation

/// Owns the log directory: externalizing large outputs, loading full logs,
/// trimming entries together with their disk artifacts, clearing the log
/// directory and importing legacy scheduled-run status files.
///
/// Deletion safety: every removal targets a plain, non-hidden file name that
/// matches a known prefix/suffix pattern inside the managed log directory.
/// config.json, the schedule state directory and unrelated files are never
/// touched.
struct LogRepository: Sendable {
    let directory: URL

    /// Logs larger than this are written to a separate file under the log
    /// directory and only a head+tail summary is kept in config.json. The tail
    /// is kept because that is where build/install errors appear.
    static let inlineThreshold = 64 * 1024
    static let maxEntries = 200

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    // MARK: - Write

    /// Writes `raw` to a standalone file when it exceeds the inline threshold;
    /// otherwise returns it unchanged. Returns (fileName, storedText).
    func externalize(_ raw: String, date: Date) -> (logFile: String?, stored: String) {
        guard raw.count > Self.inlineThreshold else { return (nil, raw) }
        let name = "build_\(Self.timestampFormatter.string(from: date))_\(UUID().uuidString.prefix(8)).log"
        let url = directory.appendingPathComponent(name)
        do {
            try raw.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return (nil, raw)
        }
        return (name, Self.summary(of: raw, fileName: name))
    }

    /// Head+tail summary kept inline in config.json for externalized logs.
    static func summary(of raw: String, fileName: String) -> String {
        let head = String(raw.prefix(4_000))
        if raw.count > 8_000 {
            let tail = String(raw.suffix(4_000))
            return head + "\n…（中部省略，完整日志见 logs/\(fileName)）\n" + tail
        }
        return head + "\n…（完整日志见 logs/\(fileName)）"
    }

    // MARK: - Read

    /// Full log text for an entry whose output was externalized.
    func fullLogText(for entry: BuildLogEntry) -> String? {
        guard let name = entry.logFile, !name.isEmpty, Self.isSafeFileName(name) else { return nil }
        return try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - Trim & Clear

    /// Caps the log list at `maxEntries`, deleting the disk artifacts of the
    /// dropped entries (externalized build logs and legacy scheduled-run
    /// status/log file pairs) so nothing grows unboundedly.
    func trim(_ logs: inout [BuildLogEntry]) {
        guard logs.count > Self.maxEntries else { return }
        let dropped = logs.dropFirst(Self.maxEntries)
        for entry in dropped {
            deleteArtifacts(for: entry)
        }
        logs = Array(logs.prefix(Self.maxEntries))
    }

    /// Deletes every managed log artifact in the log directory. The schedule
    /// state subdirectory and anything outside the known patterns are kept.
    func clearAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in files where Self.isClearableName(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes externalized build_*.log files that no surviving entry
    /// references (e.g. entries trimmed by an older version).
    func deleteOrphans(referencedLogFileNames: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("build_"), name.hasSuffix(".log"),
                  !referencedLogFileNames.contains(name) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func deleteArtifacts(for entry: BuildLogEntry) {
        if let logFile = entry.logFile {
            deleteFile(named: logFile)
        }
        if let sourceIdentifier = entry.sourceIdentifier {
            // Legacy scheduled runs: "run_<timestamp>.status" + "resign_<timestamp>.log"
            deleteFile(named: sourceIdentifier)
            let stem = (sourceIdentifier as NSString).deletingPathExtension
            if stem.hasPrefix("run_") {
                deleteFile(named: "resign_\(stem.dropFirst("run_".count)).log")
            }
        }
    }

    private func deleteFile(named name: String) {
        guard Self.isSafeFileName(name) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".")
    }

    static func isClearableName(_ name: String) -> Bool {
        guard isSafeFileName(name) else { return false }
        return (name.hasPrefix("build_") && name.hasSuffix(".log"))
            || (name.hasPrefix("resign_") && name.hasSuffix(".log"))
            || (name.hasPrefix("run_") && name.hasSuffix(".status"))
            || name == "stdout.log" || name == "stderr.log"
            || name == "launchd_stdout.log" || name == "launchd_stderr.log"
    }

    // MARK: - Legacy scheduled-run import (pre-1.5 bash engine)

    /// Imports `run_<timestamp>.status` / `resign_<timestamp>.log` pairs written
    /// by the legacy bash LaunchAgent. Imported entries reuse the resign_*.log
    /// file as their external logFile, so no data is duplicated on disk.
    func importLegacyScheduledRuns(knownIdentifiers: Set<String>) -> [BuildLogEntry] {
        guard let statusFiles = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var imported: [BuildLogEntry] = []
        for statusURL in statusFiles where statusURL.pathExtension == "status"
            && !knownIdentifiers.contains(statusURL.lastPathComponent) {

            guard let rawStatus = try? String(contentsOf: statusURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  rawStatus == "success" || rawStatus == "failed"
            else { continue }

            let timestamp = statusURL.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "run_", with: "")
            let date = Self.timestampFormatter.date(from: timestamp)
                ?? (try? statusURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date()

            let logFileName = "resign_\(timestamp).log"
            let logURL = directory.appendingPathComponent(logFileName)
            let rawOutput = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "定时任务日志文件不可用"

            var output: String
            var logFile: String?
            if rawOutput.count > Self.inlineThreshold {
                output = Self.summary(of: rawOutput, fileName: logFileName)
                logFile = logFileName
            } else {
                output = rawOutput
            }

            imported.append(BuildLogEntry(
                date: date,
                projectName: "自动任务",
                status: rawStatus == "success" ? .success : .failed,
                output: output,
                durationSeconds: 0,
                sourceIdentifier: statusURL.lastPathComponent,
                logFile: logFile,
                source: .scheduled
            ))
        }
        return imported
    }
}
