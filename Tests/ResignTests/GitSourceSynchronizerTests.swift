import XCTest
@testable import Resign

final class GitSourceSynchronizerTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let remote: URL
        let seed: URL
        let local: URL
        let projectPath: URL
    }

    func testRepositoryRootFindsNearestGitMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let project = root
            .appendingPathComponent("Apps/Demo/Demo.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        XCTAssertEqual(
            GitSourceSynchronizer.repositoryRoot(for: project.path)?.standardizedFileURL.path,
            root.standardizedFileURL.path
        )
    }

    func testSynchronizeFastForwardsCleanBehindRepository() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try Data("let version = 2\n".utf8)
            .write(to: fixture.seed.appendingPathComponent("Source.swift"))
        _ = try git(fixture.seed, ["add", "Source.swift"])
        _ = try git(fixture.seed, ["commit", "-m", "remote v2"])
        _ = try git(fixture.seed, ["push", "origin", "main"])
        let remoteHead = try git(fixture.seed, ["rev-parse", "HEAD"]).trimmed

        let result = await GitSourceSynchronizer(runner: FoundationProcessRunner())
            .synchronize(projectPath: fixture.projectPath.path)

        XCTAssertTrue(result.success, result.log)
        XCTAssertTrue(result.didUpdate, result.log)
        XCTAssertTrue(result.log.contains("安全快进"))
        XCTAssertEqual(try git(fixture.local, ["rev-parse", "HEAD"]).trimmed, remoteHead)
        XCTAssertEqual(
            try String(contentsOf: fixture.local.appendingPathComponent("Source.swift"), encoding: .utf8),
            "let version = 2\n"
        )
    }

    func testSynchronizeRefusesToUpdateBehindDirtyRepository() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let localHeadBefore = try git(fixture.local, ["rev-parse", "HEAD"]).trimmed
        try Data("let version = 999 // local edit\n".utf8)
            .write(to: fixture.local.appendingPathComponent("Source.swift"))

        try Data("let remoteFeature = true\n".utf8)
            .write(to: fixture.seed.appendingPathComponent("RemoteOnly.swift"))
        _ = try git(fixture.seed, ["add", "RemoteOnly.swift"])
        _ = try git(fixture.seed, ["commit", "-m", "remote update"])
        _ = try git(fixture.seed, ["push", "origin", "main"])

        let result = await GitSourceSynchronizer(runner: FoundationProcessRunner())
            .synchronize(projectPath: fixture.projectPath.path)

        XCTAssertFalse(result.success)
        XCTAssertFalse(result.didUpdate)
        XCTAssertTrue(result.log.contains("未提交修改"), result.log)
        XCTAssertEqual(try git(fixture.local, ["rev-parse", "HEAD"]).trimmed, localHeadBefore)
        XCTAssertEqual(
            try String(contentsOf: fixture.local.appendingPathComponent("Source.swift"), encoding: .utf8),
            "let version = 999 // local edit\n"
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-sync-\(UUID().uuidString)", isDirectory: true)
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        let seed = root.appendingPathComponent("seed", isDirectory: true)
        let local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try git(nil, ["init", "--bare", remote.path])
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        _ = try git(seed, ["init"])
        _ = try git(seed, ["checkout", "-b", "main"])
        _ = try git(seed, ["config", "user.name", "Resign Tests"])
        _ = try git(seed, ["config", "user.email", "resign-tests@example.invalid"])

        let project = seed.appendingPathComponent("Demo.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("// test project\n".utf8)
            .write(to: project.appendingPathComponent("project.pbxproj"))
        try Data("let version = 1\n".utf8)
            .write(to: seed.appendingPathComponent("Source.swift"))

        _ = try git(seed, ["add", "."])
        _ = try git(seed, ["commit", "-m", "initial"])
        _ = try git(seed, ["remote", "add", "origin", remote.path])
        _ = try git(seed, ["push", "-u", "origin", "main"])
        _ = try git(remote, ["symbolic-ref", "HEAD", "refs/heads/main"])
        _ = try git(nil, ["clone", remote.path, local.path])

        return Fixture(
            root: root,
            remote: remote,
            seed: seed,
            local: local,
            projectPath: local.appendingPathComponent("Demo.xcodeproj", isDirectory: true)
        )
    }

    @discardableResult
    private func git(_ currentDirectory: URL?, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let err = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitSourceSynchronizerTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(err)"]
            )
        }
        return out
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
