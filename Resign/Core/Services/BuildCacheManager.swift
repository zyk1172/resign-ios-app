import Foundation

/// 缓存决策。`reuseArtifact` 目前**不会**被产出：
/// 免费账号的 provisioning profile 有效期是"创建时刻 + 7 天"，
/// 重装旧的已签名 .app 不会刷新有效期，而codesign 手工重签
/// 无法向 Apple 申请新 profile（申请只能由 xcodebuild
/// -allowProvisioningUpdates 在构建中完成）。因此续签必须走
/// xcodebuild——增量构建使未变化项目只重跑签名阶段（秒级），
/// 该签名流程与全量构建完全一致，续签有效性不受影响。
enum BuildCacheError: LocalizedError {
    case lockUnavailable
    case invalidClearPath

    var errorDescription: String? {
        switch self {
        case .lockUnavailable:
            return "构建锁被占用（可能正在构建），已拒绝清理缓存"
        case .invalidClearPath:
            return "拒绝清理管理目录之外的路径"
        }
    }
}

/// 缓存决策。语义与实际执行严格对应：
/// - coldBuild：无工作区（首次或工作区缺失），从零构建；
/// - incrementalChangedBuild：保留工作区，项目有更新，Xcode 只编译变化部分；
/// - incrementalUnchangedBuild：保留工作区，项目未变化，仅重组产物并重新签名；
/// - cleanBuild：工作区必须清除后重建（Xcode 版本/项目路径变化等）。
///
/// 没有"直接复用旧产物"的分支：免费签名 profile 有效期 = 创建 + 7 天，
/// 重装旧签名 .app 不会刷新有效期，签名阶段必须每次重跑。
enum BuildCacheDecision: Equatable, Sendable {
    case coldBuild(reason: String)
    case incrementalChangedBuild(reason: String)
    case incrementalUnchangedBuild(reason: String)
    case cleanBuild(reason: String)

    var reason: String {
        switch self {
        case .coldBuild(let reason), .incrementalChangedBuild(let reason),
             .incrementalUnchangedBuild(let reason), .cleanBuild(let reason):
            return reason
        }
    }

    var mode: BuildMode {
        switch self {
        case .coldBuild: return .cold
        case .incrementalChangedBuild: return .incrementalChanged
        case .incrementalUnchangedBuild: return .incrementalUnchanged
        case .cleanBuild: return .cold
        }
    }

    /// 该决策是否要求先清除工作区。
    var clearsWorkspace: Bool {
        if case .cleanBuild = self { return true }
        return false
    }

    var logDescription: String {
        switch self {
        case .coldBuild(let reason):
            return "模式：冷启动构建（原因：\(reason)）"
        case .incrementalChangedBuild(let reason):
            return "模式：增量构建（原因：\(reason)）——Xcode 将只编译变化部分"
        case .incrementalUnchangedBuild(let reason):
            return "模式：增量复用（原因：\(reason)）——跳过无变化编译，签名阶段重新执行以刷新有效期"
        case .cleanBuild(let reason):
            return "模式：清除工作区重建（原因：\(reason)）"
        }
    }
}

/// 每个项目的构建缓存元数据（当前可复用的构建状态）。
/// 与 BuildLogEntry（历史记录）是两个不同概念；存储于
/// `Application Support/Resign/BuildCache/<projectID>.json`，
/// 不放入 /tmp，不随 DerivedData 清理而丢失。
struct BuildArtifactMetadata: Codable, Equatable, Sendable {
    var projectID: UUID
    var fingerprint: String
    var xcodeVersion: String
    var builtAt: Date
    var scheme: String
    var configuration: String
    var platform: ProjectPlatform
    var teamID: String?
    var projectPath: String
    var productName: String?
    var bundleIdentifier: String?
    var buildSucceeded: Bool

    init(
        projectID: UUID,
        fingerprint: String,
        xcodeVersion: String,
        builtAt: Date,
        scheme: String,
        configuration: String,
        platform: ProjectPlatform,
        teamID: String?,
        projectPath: String,
        productName: String? = nil,
        bundleIdentifier: String? = nil,
        buildSucceeded: Bool
    ) {
        self.projectID = projectID
        self.fingerprint = fingerprint
        self.xcodeVersion = xcodeVersion
        self.builtAt = builtAt
        self.scheme = scheme
        self.configuration = configuration
        self.platform = platform
        self.teamID = teamID
        self.projectPath = projectPath
        self.productName = productName
        self.bundleIdentifier = bundleIdentifier
        self.buildSucceeded = buildSucceeded
    }
}

extension BuildArtifactMetadata {
    private enum CodingKeys: String, CodingKey {
        case projectID, fingerprint, xcodeVersion, builtAt, scheme, configuration
        case platform, teamID, projectPath, productName, bundleIdentifier, buildSucceeded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        xcodeVersion = try c.decodeIfPresent(String.self, forKey: .xcodeVersion) ?? ""
        builtAt = try c.decodeIfPresent(Date.self, forKey: .builtAt) ?? .distantPast
        scheme = try c.decodeIfPresent(String.self, forKey: .scheme) ?? ""
        configuration = try c.decodeIfPresent(String.self, forKey: .configuration) ?? "Debug"
        platform = try c.decodeIfPresent(ProjectPlatform.self, forKey: .platform) ?? .ios
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath) ?? ""
        productName = try c.decodeIfPresent(String.self, forKey: .productName)
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        buildSucceeded = try c.decodeIfPresent(Bool.self, forKey: .buildSucceeded) ?? false
    }
}

/// 构建缓存的存储、决策与清理。GUI 与 Worker 通过同一个
/// BuildCoordinator 调用这里，因此决策逻辑只有一份。
enum BuildCacheManager {

    static func metadataURL(for projectID: UUID, directory: URL = AppPaths.buildCacheDirectory) -> URL {
        directory.appendingPathComponent("\(projectID.uuidString).json")
    }

    static func loadMetadata(for projectID: UUID, directory: URL = AppPaths.buildCacheDirectory) -> BuildArtifactMetadata? {
        let url = metadataURL(for: projectID, directory: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(BuildArtifactMetadata.self, from: data)
        } catch {
            return nil // 元数据损坏 → 视为无缓存，回退完整构建
        }
    }

    static func saveMetadata(_ metadata: BuildArtifactMetadata, directory: URL = AppPaths.buildCacheDirectory) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: metadataURL(for: metadata.projectID, directory: directory), options: [.atomic])
    }

    /// 唯一的决策入口（GUI 与 Worker 共享）。
    static func decide(
        project: iOSProject,
        currentFingerprint: String,
        xcodeVersion: String,
        workspaceExists: Bool,
        directory: URL = AppPaths.buildCacheDirectory
    ) -> BuildCacheDecision {
        guard let metadata = loadMetadata(for: project.id, directory: directory) else {
            // 无元数据：工作区仍在就信任 Xcode 的增量状态，否则冷启动。
            if workspaceExists {
                return .incrementalChangedBuild(reason: "无缓存元数据，按增量处理")
            }
            return .coldBuild(reason: "首次构建（无缓存元数据与构建工作区）")
        }
        guard metadata.buildSucceeded else {
            return .incrementalChangedBuild(reason: "上一次构建未成功，重新执行")
        }
        guard metadata.xcodeVersion == xcodeVersion else {
            return .cleanBuild(reason: "Xcode 版本变化（\(metadata.xcodeVersion) → \(xcodeVersion)），清除旧工具链产物")
        }
        guard metadata.projectPath == project.projectPath else {
            return .cleanBuild(reason: "项目路径变化（\(metadata.projectPath) → \(project.projectPath)），DerivedData 内含旧路径引用")
        }
        guard metadata.scheme == project.scheme,
              metadata.configuration == project.configuration,
              metadata.platform == project.platform,
              metadata.teamID == project.teamID else {
            return .incrementalChangedBuild(reason: "Scheme/Configuration/平台/Team 配置变化")
        }
        guard metadata.fingerprint == currentFingerprint else {
            return .incrementalChangedBuild(reason: "项目有更新（源码/工程/依赖自上次成功构建后有变化）")
        }
        guard workspaceExists else {
            return .coldBuild(reason: "项目未变化但工作区缺失，重建工作区")
        }
        return .incrementalUnchangedBuild(reason: "项目未变化，复用增量构建工作区（编译阶段将被 Xcode 跳过）")
    }

    /// 手动/自动清理某项目的构建工作区与元数据。
    /// 只删除 Resign 管理目录内的路径；构建锁被占用时拒绝执行，
    /// 防止清掉正在被 GUI/Worker 使用的 DerivedData。
    static func clear(
        projectID: UUID,
        buildLockPath: String,
        workspacesDirectory: URL = AppPaths.buildWorkspacesDirectory,
        directory: URL = AppPaths.buildCacheDirectory
    ) throws {
        let lock = FileLock(path: buildLockPath)
        guard lock.acquire() else {
            throw BuildCacheError.lockUnavailable
        }
        defer { lock.release() }

        let workspace = workspacesDirectory.appendingPathComponent(projectID.uuidString, isDirectory: true)
        let workspaceRoot = workspacesDirectory.standardizedFileURL.path + "/"
        let target = workspace.standardizedFileURL.path
        guard target.hasPrefix(workspaceRoot), target.count > workspaceRoot.count else {
            throw BuildCacheError.invalidClearPath
        }
        if FileManager.default.fileExists(atPath: target) {
            try FileManager.default.removeItem(atPath: target)
        }
        try? FileManager.default.removeItem(at: metadataURL(for: projectID, directory: directory))
    }
}
