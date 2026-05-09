import XCTest
import SwiftData
@testable import PasteMemo

@MainActor
final class PrivacyGuardTests: XCTestCase {

    func testFilterDropsSensitiveByDefault() {
        let container = SampleClips.makeContainer()
        let context = container.mainContext
        let items = SampleClips.seed(in: context)

        let guardLayer = PrivacyGuard(allowSensitive: false, sourceAppBlocklist: [])
        let filtered = guardLayer.filter(items)

        // 5 条原始样本，过滤掉 1 条敏感（index 1）→ 4 条
        XCTAssertEqual(filtered.count, 4)
        XCTAssertFalse(filtered.contains(where: { $0.isSensitive }))
    }

    func testFilterRemovesBlocklistedSourceApps() {
        let container = SampleClips.makeContainer()
        let items = SampleClips.seed(in: container.mainContext)

        let guardLayer = PrivacyGuard(allowSensitive: false,
                                      sourceAppBlocklist: ["com.evil.app"])
        let filtered = guardLayer.filter(items)

        XCTAssertFalse(filtered.contains(where: { $0.sourceAppBundleID == "com.evil.app" }))
    }

    func testAllowSensitiveTruePassesSensitiveThrough() {
        let container = SampleClips.makeContainer()
        let items = SampleClips.seed(in: container.mainContext)

        let guardLayer = PrivacyGuard(allowSensitive: true, sourceAppBlocklist: [])
        let filtered = guardLayer.filter(items)

        XCTAssertTrue(filtered.contains(where: { $0.isSensitive }))
    }

    func testTruncatePreview200Chars() {
        let preview = PrivacyGuard.truncatePreview(String(repeating: "A", count: 500))
        XCTAssertEqual(preview.count, 200)
    }
}
