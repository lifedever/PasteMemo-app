import Foundation
import SwiftData
import Testing
@testable import PasteMemo

@Suite("ClipItem.isGone")
@MainActor
struct ClipItemIsGoneTests {
    @Test("Gone while the delete is pending and after it's saved — when isDeleted alone reads false")
    func deletedAndSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("isgone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: Schema([ClipItem.self, AutomationRule.self, SmartGroup.self]),
            configurations: [ModelConfiguration(url: root.appendingPathComponent("PasteMemo.store"))]
        )
        let context = container.mainContext
        let item = ClipItem(content: "x", contentType: .text, richTextData: Data(count: 300_000), richTextType: "html")
        context.insert(item)
        try context.save()
        #expect(!item.isGone)

        context.delete(item)
        #expect(item.isGone)
        try context.save()
        #expect(!item.isDeleted, "SwiftData's own flag flips back once saved — the reason isGone exists")
        #expect(item.isGone)
    }
}
