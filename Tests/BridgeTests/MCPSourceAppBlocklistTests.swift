import XCTest
@testable import PasteMemo

@MainActor
final class MCPSourceAppBlocklistTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "mcpSourceAppBlocklist")
        UserDefaults.standard.removeObject(forKey: "mcpSourceAppBlocklistNames")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "mcpSourceAppBlocklist")
        UserDefaults.standard.removeObject(forKey: "mcpSourceAppBlocklistNames")
    }

    func testAddAndCheck() {
        let bl = MCPSourceAppBlocklist()
        bl.add(bundleID: "com.evil.app", name: "Evil App")
        XCTAssertTrue(bl.isBlocked("com.evil.app"))
        XCTAssertFalse(bl.isBlocked("com.good.app"))
    }

    func testRemove() {
        let bl = MCPSourceAppBlocklist()
        bl.add(bundleID: "com.evil.app", name: "Evil App")
        bl.remove(bundleID: "com.evil.app")
        XCTAssertFalse(bl.isBlocked("com.evil.app"))
    }

    func testPersistenceAcrossInstances() {
        let bl1 = MCPSourceAppBlocklist()
        bl1.add(bundleID: "com.evil.app", name: "Evil App")

        let bl2 = MCPSourceAppBlocklist()
        XCTAssertTrue(bl2.isBlocked("com.evil.app"))
        XCTAssertEqual(bl2.appNames["com.evil.app"], "Evil App")
    }
}
