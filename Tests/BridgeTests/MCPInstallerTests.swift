import XCTest
@testable import PasteMemo

@MainActor
final class MCPInstallerTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-installer-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testInstallToCleanSettingsAddsServer() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        try #"{"otherKey": "value"}"#.write(to: settings, atomically: true, encoding: .utf8)

        try MCPInstaller.installToJSONSettings(
            file: settings,
            mcpServerKey: "pastememo",
            command: "/Applications/PasteMemo.app/Contents/MacOS/pastememo-mcp"
        )

        let result = try String(contentsOf: settings)
        XCTAssertTrue(result.contains("pastememo"))
        XCTAssertTrue(result.contains("otherKey"))  // 保留原内容
    }

    func testInstallCreatesBackup() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        try "{}".write(to: settings, atomically: true, encoding: .utf8)
        try MCPInstaller.installToJSONSettings(
            file: settings,
            mcpServerKey: "pastememo",
            command: "/foo/bar"
        )
        // 备份文件应存在
        let backups = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
            .filter { $0.contains("pastememo-backup") }
        XCTAssertGreaterThanOrEqual(backups.count, 1)
    }

    func testInstallToInvalidJSONThrows() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        try "this is not valid JSON".write(to: settings, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try MCPInstaller.installToJSONSettings(
            file: settings, mcpServerKey: "pastememo", command: "/foo"
        ))
    }

    func testUninstallRemovesServer() throws {
        let settings = tmpDir.appendingPathComponent("settings.json")
        let initial = #"{"mcpServers":{"pastememo":{"command":"/foo"},"other":{"command":"/bar"}}}"#
        try initial.write(to: settings, atomically: true, encoding: .utf8)

        try MCPInstaller.uninstallFromJSONSettings(file: settings, mcpServerKey: "pastememo")

        let after = try String(contentsOf: settings)
        XCTAssertFalse(after.contains("pastememo"))
        XCTAssertTrue(after.contains("other"))
    }
}
