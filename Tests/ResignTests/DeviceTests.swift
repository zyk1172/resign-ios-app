import XCTest
@testable import Resign

final class DeviceTests: XCTestCase {
    private func device(_ udid: String, name: String = "iPhone", available: Bool) -> iOSDevice {
        iOSDevice(udid: udid, name: name, osVersion: "18.0", connectionType: "USB", isAvailable: available)
    }

    // MARK: - Selection

    func testExplicitProjectSelectionWins() {
        let devices = [device("A", available: true), device("B", available: true)]
        XCTAssertEqual(
            DeviceSelection.resolveDeviceUDIDs(projectUDIDs: ["B"], availableDevices: devices),
            ["B"]
        )
    }

    func testEmptySelectionFallsBackToFirstAvailableDevice() {
        let devices = [device("Offline", available: false), device("Online", available: true)]
        XCTAssertEqual(
            DeviceSelection.resolveDeviceUDIDs(projectUDIDs: [], availableDevices: devices),
            ["Online"]
        )
    }

    func testNoAvailableDeviceYieldsEmptySelection() {
        let devices = [device("Offline", available: false)]
        XCTAssertTrue(DeviceSelection.resolveDeviceUDIDs(projectUDIDs: [], availableDevices: devices).isEmpty)
    }

    // MARK: - devicectl JSON parsing

    func testParseDevicesFiltersToPhysicalAndSortsAvailableFirst() throws {
        let json = """
        {"result":{"devices":[
          {"hardwareProperties":{"udid":"SIM1","reality":"simulator"},
           "deviceProperties":{"name":"Simulator"}},
          {"hardwareProperties":{"udid":"00008140-000A6D6A2143801C","reality":"physical"},
           "deviceProperties":{"name":"Offline iPhone","osVersionNumber":"18.0","bootState":"booted"},
           "connectionProperties":{"transportType":"wired","pairingState":"notpaired"}},
          {"hardwareProperties":{"udid":"OLDFORMAT","reality":"physical"},
           "deviceProperties":{"name":"Online iPhone","osVersionNumber":"17.5","bootState":"booted"},
           "connectionProperties":{"transportType":"localNetwork","pairingState":"paired"}}
        ]}}
        """
        let devices = DeviceService.parseDevices(json: Data(json.utf8))

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first?.udid, "OLDFORMAT") // available sorts first
        XCTAssertEqual(devices.first?.isAvailable, true)
        XCTAssertEqual(devices.first?.connectionType, "WiFi")
        XCTAssertEqual(devices.last?.udid, "00008140-000A6D6A2143801C")
        XCTAssertEqual(devices.last?.isAvailable, false, "未配对/未就绪的设备不应标记可用")
    }
}
