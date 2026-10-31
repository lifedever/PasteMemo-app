import Foundation
import SwiftData
import Testing
@testable import PasteMemo

/// Deleting clips used to pause monitoring through the persisted user toggle and flip it
/// back afterwards — a crash or quit mid-delete left capture switched off for good.
/// The hold must stay in memory: the persisted setting never changes during a delete.
@Suite("Bulk write monitoring hold", .serialized)
@MainActor
struct BulkWriteHoldTests {
    private static let monitoringKey = "clipboardMonitoringEnabled"

    @Test("batched delete holds monitoring without touching the persisted toggle")
    func batchedDeleteKeepsPersistedToggle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bulkhold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: Schema([ClipItem.self, AutomationRule.self, SmartGroup.self]),
            configurations: [ModelConfiguration(url: root.appendingPathComponent("PasteMemo.store"))]
        )
        let context = container.mainContext
        let items = (0..<5).map { ClipItem(content: "item \($0)", contentType: .text) }
        items.forEach(context.insert)
        try context.save()

        let manager = ClipboardManager.shared
        if !manager.isMonitoringEnabled { manager.isMonitoringEnabled = true }

        var midDeleteChecks = 0
        await ClipItemStore.deleteAndNotifyBatched(items, from: context, batchSize: 2) { done, total in
            guard done > 0, done < total else { return }
            midDeleteChecks += 1
            #expect(manager.isHeldForBulkWrite)
            #expect(manager.isMonitoringEnabled)
            #expect(UserDefaults.standard.object(forKey: Self.monitoringKey) as? Bool != false)
        }

        #expect(midDeleteChecks > 0)
        #expect(!manager.isHeldForBulkWrite)
        #expect(manager.isMonitoringEnabled)
    }

    @Test("overlapping holds release only when the last one ends")
    func nestedHolds() {
        let manager = ClipboardManager.shared
        manager.beginBulkWriteHold()
        manager.beginBulkWriteHold()
        manager.endBulkWriteHold()
        #expect(manager.isHeldForBulkWrite)
        manager.endBulkWriteHold()
        #expect(!manager.isHeldForBulkWrite)
        manager.endBulkWriteHold()
        #expect(!manager.isHeldForBulkWrite, "an unmatched end must not go negative")
    }
}
