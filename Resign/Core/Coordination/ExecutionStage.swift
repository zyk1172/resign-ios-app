import Foundation

/// Stage times are wall-clock times and can include system sleep. Progress is
/// emitted before awaiting a command, including in the standalone worker.
struct ExecutionStage {
    let name: String
    private let startedAt: Date
    private let onProgress: @Sendable (String) -> Void

    init(_ name: String, onProgress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.name = name
        self.startedAt = Date()
        self.onProgress = onProgress
        onProgress("正在执行：\(name)")
    }

    var startedLog: String {
        "\n=== 阶段开始：\(name) | \(Self.timestamp(startedAt)) ===\n"
    }

    func finish() -> String {
        let finishedAt = Date()
        let elapsed = max(0, finishedAt.timeIntervalSince(startedAt))
        let duration = String(format: "%.2f", elapsed)
        onProgress("\(name)结束，耗时 \(duration) 秒")
        return "\n=== 阶段结束：\(name) | \(Self.timestamp(finishedAt)) | 墙钟耗时 \(duration) 秒 ===\n"
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
