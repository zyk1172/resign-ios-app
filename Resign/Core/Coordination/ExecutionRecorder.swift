import Foundation

/// Applies one finished execution to the persisted state: appends the log
/// entry (externalizing large output), updates the project's UI status fields
/// and upserts the authoritative ProjectExecutionState. Shared by the GUI and
/// the scheduled worker so both write exactly the same shape of state.
enum ExecutionRecorder {
    struct Input: Sendable {
        let projectID: UUID
        let projectName: String
        let result: BuildResult
        let source: ExecutionSource
        let startedAt: Date
        let durationSeconds: TimeInterval
        /// udid → friendly device name for failure display
        let deviceNames: [String: String]

        init(
            projectID: UUID,
            projectName: String,
            result: BuildResult,
            source: ExecutionSource,
            startedAt: Date,
            durationSeconds: TimeInterval,
            deviceNames: [String: String] = [:]
        ) {
            self.projectID = projectID
            self.projectName = projectName
            self.result = result
            self.source = source
            self.startedAt = startedAt
            self.durationSeconds = durationSeconds
            self.deviceNames = deviceNames
        }
    }

    /// Externalizer for oversized output; returns (externalFileName, storedText).
    typealias OutputExternalizer = (_ raw: String, _ date: Date) -> (logFile: String?, stored: String)

    static func apply(
        _ input: Input,
        to state: inout PersistedState,
        externalize: OutputExternalizer = { raw, _ in (nil, raw) }
    ) {
        let status: BuildStatus = input.result.cancelled
            ? .cancelled
            : (input.result.success ? .success : .failed)

        let failedNames = input.result.failedDeviceUDIDs.map { udid in
            input.deviceNames[udid] ?? String(udid.prefix(8))
        }

        let (logFile, storedOutput) = externalize(input.result.output, input.startedAt)
        let entry = BuildLogEntry(
            date: input.startedAt,
            projectName: input.projectName,
            status: status,
            output: storedOutput,
            durationSeconds: input.durationSeconds,
            failedDevices: failedNames.isEmpty ? nil : failedNames,
            logFile: logFile,
            source: input.source,
            builtAppPath: input.result.builtAppPath,
            deviceInstallSummaries: input.result.deviceOutcomes.isEmpty ? nil : input.result.deviceOutcomes.map { outcome in
                DeviceInstallSummary(
                    udid: outcome.udid,
                    deviceName: input.deviceNames[outcome.udid] ?? String(outcome.udid.prefix(8)),
                    success: outcome.success,
                    attempts: outcome.attempts
                )
            },
            buildMode: input.result.buildMode
        )
        state.logs.insert(entry, at: 0)

        // 统一计算失败摘要：新建与更新执行状态都必须带上，
        // 否则项目第一次失败时 lastFailureSummary 会是 nil。
        let failureSummary: String? = status == .failed ? entry.errorSummary?.reason : nil

        upsertExecutionState(
            projectID: input.projectID,
            status: status,
            source: input.source,
            failureSummary: failureSummary,
            at: input.startedAt,
            into: &state
        )

        if let index = state.projects.firstIndex(where: { $0.id == input.projectID }) {
            state.projects[index].lastBuildDate = input.startedAt
            state.projects[index].lastBuildStatus = status
        }
    }

    private static func upsertExecutionState(
        projectID: UUID,
        status: BuildStatus,
        source: ExecutionSource,
        failureSummary: String?,
        at date: Date,
        into state: inout PersistedState
    ) {
        if let index = state.executionStates.firstIndex(where: { $0.projectID == projectID }) {
            var updated = state.executionStates[index]
            updated.lastAttemptDate = date
            if status == .success {
                updated.lastSuccessfulInstallDate = date
                updated.lastFailureSummary = nil
            }
            updated.lastStatus = status
            updated.lastSource = source
            if status == .failed {
                updated.lastFailureSummary = failureSummary
            }
            state.executionStates[index] = updated
        } else {
            state.executionStates.append(ProjectExecutionState(
                projectID: projectID,
                lastAttemptDate: date,
                lastSuccessfulInstallDate: status == .success ? date : nil,
                lastStatus: status,
                lastSource: source,
                lastFailureSummary: failureSummary
            ))
        }
    }
}
