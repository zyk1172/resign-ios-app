import Foundation

/// Discovers paired physical iOS/iPadOS devices via `devicectl` JSON output.
/// The human-readable table must never be parsed — it is not a stable interface.
struct DeviceService: Sendable {
    let runner: ProcessRunning

    func listDevices(xcodePath: String) async -> [iOSDevice] {
        guard XcodeToolchain.validate(xcodePath: xcodePath) == nil else { return [] }
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resign_devices_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let result = await runner.run(
            XcodeToolchain.xcrunPath,
            arguments: ["devicectl", "list", "devices", "--json-output", jsonURL.path],
            environment: XcodeToolchain.environment(xcodePath: xcodePath)
        )

        guard result.exitCode == 0,
              let data = try? Data(contentsOf: jsonURL)
        else { return [] }
        return Self.parseDevices(json: data)
    }

    /// Pure parsing of `devicectl list devices --json-output` payload.
    static func parseDevices(json: Data) -> [iOSDevice] {
        guard let json = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let deviceList = result["devices"] as? [[String: Any]]
        else { return [] }

        return deviceList.compactMap { dictionary -> iOSDevice? in
            guard let hardware = dictionary["hardwareProperties"] as? [String: Any],
                  let udid = hardware["udid"] as? String,
                  hardware["reality"] as? String == "physical",
                  let properties = dictionary["deviceProperties"] as? [String: Any],
                  let name = properties["name"] as? String
            else { return nil }

            let osVersion = properties["osVersionNumber"] as? String ?? ""
            let bootState = properties["bootState"] as? String ?? ""
            let connection = dictionary["connectionProperties"] as? [String: Any]
            let transport = connection?["transportType"] as? String ?? ""
            let pairing = connection?["pairingState"] as? String ?? ""

            let connectionType: String
            switch transport {
            case "wired", "usb": connectionType = "USB"
            case "localNetwork": connectionType = "WiFi"
            default: connectionType = transport.isEmpty ? "未连接" : transport
            }

            return iOSDevice(
                udid: udid,
                name: name,
                osVersion: osVersion,
                connectionType: connectionType,
                isAvailable: pairing == "paired" && bootState == "booted" && !transport.isEmpty
            )
        }
        .sorted {
            if $0.isAvailable != $1.isAvailable { return $0.isAvailable && !$1.isAvailable }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// Single rule for choosing which devices a project installs to.
enum DeviceSelection {
    /// Explicit project selection wins; otherwise the first available device.
    static func resolveDeviceUDIDs(projectUDIDs: [String], availableDevices: [iOSDevice]) -> [String] {
        if !projectUDIDs.isEmpty { return projectUDIDs }
        return availableDevices.first(where: \.isAvailable).map { [$0.udid] } ?? []
    }
}
