import XCTest
@testable import Resign

final class ProductResolverTests: XCTestCase {
    private func jsonData(_ payload: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: payload)
    }

    private func buildSettings(targets: [(name: String, wrapper: String)]) -> Data {
        jsonData(targets.map { target in
            [
                "target": target.name,
                "buildSettings": [
                    "TARGET_BUILD_DIR": "/tmp/fake-products",
                    "WRAPPER_NAME": target.wrapper
                ]
            ]
        })
    }

    func testSingleAppCandidateIsAccepted() {
        let data = buildSettings(targets: [("App", "App.app")])
        XCTAssertEqual(
            ProductResolver.expectedProductPath(fromBuildSettingsJSON: data, preferredNames: ["App"]),
            "/tmp/fake-products/App.app"
        )
    }

    func testPreferredNameMatchesTargetThenWrapper() {
        // Two .app candidates: Widget-like sibling plus the main app. Only the
        // scheme/target match may be installed.
        let data = buildSettings(targets: [
            ("MyAppWidget", "MyAppWidget.app"),
            ("MyApp", "MyApp.app")
        ])
        let resolved = ProductResolver.expectedProductPath(
            fromBuildSettingsJSON: data,
            preferredNames: ["MyApp"]
        )
        XCTAssertEqual(resolved, "/tmp/fake-products/MyApp.app")
    }

    func testAmbiguousCandidatesWithoutNameMatchFail() {
        let data = buildSettings(targets: [
            ("One", "One.app"),
            ("Two", "Two.app")
        ])
        XCTAssertNil(
            ProductResolver.expectedProductPath(fromBuildSettingsJSON: data, preferredNames: ["Main"])
        )
    }

    func testNonAppWrappersAreIgnored() {
        let data = jsonData([
            [
                "target": "Framework",
                "buildSettings": ["TARGET_BUILD_DIR": "/tmp/fake-products", "WRAPPER_NAME": "Framework.framework"]
            ],
            [
                "target": "App",
                "buildSettings": ["TARGET_BUILD_DIR": "/tmp/fake-products", "WRAPPER_NAME": "App.app"]
            ]
        ])
        XCTAssertEqual(
            ProductResolver.expectedProductPath(fromBuildSettingsJSON: data, preferredNames: ["Nope"]),
            "/tmp/fake-products/App.app" // single .app candidate → unambiguous
        )
    }

    func testInvalidJSONYieldsNoCandidates() {
        XCTAssertNil(ProductResolver.expectedProductPath(
            fromBuildSettingsJSON: Data("not json".utf8),
            preferredNames: ["App"]
        ))
    }

    func testProductsDirectoryScan() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("productresolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // No apps → nil
        XCTAssertNil(ProductResolver.mainApp(in: dir, preferredNames: ["App"]))

        // Single app → accepted (compare by name; macOS resolves /var → /private/var)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Solo.app"), withIntermediateDirectories: true)
        XCTAssertEqual(
            (ProductResolver.mainApp(in: dir, preferredNames: ["App"]) as NSString?)?.lastPathComponent,
            "Solo.app"
        )

        // Name match beats ambiguity
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("App.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Other.app"), withIntermediateDirectories: true)
        XCTAssertEqual(
            (ProductResolver.mainApp(in: dir, preferredNames: ["App"]) as NSString?)?.lastPathComponent,
            "App.app"
        )

        // Two apps and no name match → refuses
        XCTAssertNil(ProductResolver.mainApp(in: dir, preferredNames: ["Nothing"]))
    }
}
