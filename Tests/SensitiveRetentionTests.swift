import Foundation
import SwiftData
import Testing
@testable import PasteMemo

@Suite("Sensitive retention")
@MainActor
struct SensitiveRetentionTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([ClipItem.self, SmartGroup.self])
        return ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
    }

    @Test("0 means no separate limit")
    func noLimit() {
        #expect(SensitiveRetention.cutoff(minutes: 0) == nil)
        let now = Date()
        #expect(SensitiveRetention.cutoff(minutes: 10, now: now) == now.addingTimeInterval(-600))
    }

    @Test("only sensitive, unpinned, idle-past-cutoff clips outside kept groups expire")
    func selection() throws {
        let context = try makeContext()
        let now = Date()
        let old = now.addingTimeInterval(-3600)

        func clip(_ content: String, sensitive: Bool = true, pinned: Bool = false, lastUsed: Date, group: String? = nil) -> ClipItem {
            let item = ClipItem(content: content, isPinned: pinned, lastUsedAt: lastUsed)
            item.isSensitive = sensitive
            item.groupName = group
            context.insert(item)
            return item
        }
        let expired = clip("old secret", lastUsed: old)
        _ = clip("fresh secret", lastUsed: now)
        _ = clip("old plain", sensitive: false, lastUsed: old)
        _ = clip("pinned secret", pinned: true, lastUsed: old)
        _ = clip("kept secret", lastUsed: old, group: "保险箱")
        let vault = SmartGroup(name: "保险箱")
        vault.preservesItems = true
        context.insert(vault)
        try context.save()

        let result = SensitiveRetention.expiredItems(in: context, cutoff: now.addingTimeInterval(-600))
        #expect(result.map(\.content) == [expired.content])
    }
}
