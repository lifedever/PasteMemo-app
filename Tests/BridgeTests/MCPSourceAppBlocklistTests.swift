import XCTest
@testable import PasteMemo

@MainActor
final class MCPSourceAppBlocklistTests: XCTestCase {
    override func setUp() {
        // 用唯一 key 隔离，避免污染真实 UserDefaults
        UserDefaults.standard.removeObject(forKey: "mcpSourceAppBlocklist")
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
}
