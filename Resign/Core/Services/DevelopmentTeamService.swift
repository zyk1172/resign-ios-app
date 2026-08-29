import Foundation

/// Developer teams usable for automatic signing.
struct DevelopmentTeamService: Sendable {
    let runner: ProcessRunning

    /// Returns the teams of the Apple IDs currently signed into Xcode, which is
    /// the authoritative set of teams that can actually sign apps. Falls back to
    /// codesigning certificates / local provisioning profiles if the Xcode
    /// account list cannot be read (e.g. Xcode has never been opened).
    func listTeams() async -> [DevelopmentTeam] {
        var teams: [DevelopmentTeam] = []
        var seen = Set<String>()

        func append(_ teamID: String, _ displayName: String) {
            guard !seen.contains(teamID) else { return }
            seen.insert(teamID)
            teams.append(DevelopmentTeam(teamID: teamID, displayName: displayName))
        }

        // 1) Teams of the Apple IDs signed into Xcode (authoritative).
        let xcodePrefs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dt.Xcode.plist")
        let plistResult = await runner.run(
            "/usr/bin/plutil",
            arguments: [
                "-extract", "IDEProvisioningTeamByIdentifier", "json",
                "-o", "-", xcodePrefs.path
            ]
        )
        if plistResult.exitCode == 0,
           let data = plistResult.stdout.data(using: .utf8),
           let accounts = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (_, value) in accounts {
                guard let teamList = value as? [[String: Any]] else { continue }
                for team in teamList {
                    guard let teamID = team["teamID"] as? String, !teamID.isEmpty else { continue }
                    let teamName = team["teamName"] as? String ?? "Team \(teamID)"
                    append(teamID, teamName)
                }
            }
        }

        // 2) Fallback when Xcode's account list is unavailable: teams whose
        //    codesigning certificates are installed in the keychain, plus teams
        //    found in local provisioning profiles.
        if teams.isEmpty {
            let identityResult = await runner.run(
                "/usr/bin/security",
                arguments: ["find-identity", "-v", "-p", "codesigning"]
            )
            for line in identityResult.stdout.components(separatedBy: .newlines) {
                guard let openQuote = line.range(of: "\""),
                      let closeQuote = line.range(of: "\"", range: openQuote.upperBound..<line.endIndex)
                else { continue }
                let certificateName = String(line[openQuote.upperBound..<closeQuote.lowerBound])
                if let teamID = Self.extractTeamID(from: certificateName) {
                    append(teamID, certificateName)
                }
            }

            let profilesDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(
                at: profilesDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for url in files where url.pathExtension == "mobileprovision" {
                    let profileResult = await runner.run(
                        "/usr/bin/security",
                        arguments: ["cms", "-D", "-i", url.path]
                    )
                    guard let data = profileResult.stdout.data(using: .utf8),
                          let plist = try? PropertyListSerialization.propertyList(
                            from: data,
                            options: [],
                            format: nil
                          ) as? [String: Any],
                          let teamID = (plist["TeamIdentifier"] as? [String])?.first,
                          !teamID.isEmpty
                    else { continue }
                    append(teamID, "Team \(teamID)（本机 Profile）")
                }
            }
        }

        return teams.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// Extracts the trailing "(TEAMID)" group from a codesigning certificate name,
    /// e.g. `Apple Development: John Appleseed (ABCDE12345)` -> `ABCDE12345`.
    static func extractTeamID(from certificateName: String) -> String? {
        guard let open = certificateName.lastIndex(of: "("),
              let close = certificateName.lastIndex(of: ")"),
              close > open
        else { return nil }

        let candidate = certificateName[certificateName.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
        guard candidate.count == 10,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        return candidate
    }
}
