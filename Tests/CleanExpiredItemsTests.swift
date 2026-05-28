import Foundation
import SwiftData
import Testing
@testable import PasteMemo

@Suite("cleanExpiredItems SQL pushdown")
@MainActor
struct CleanExpiredItemsTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([ClipItem.self, SmartGroup.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    @Test("Predicate selects expired & unpinned items")
    func predicateSelectsExpiredUnpinned() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let now = Date()
        let cutoff = now.addingTimeInterval(-3600)

        let expired = ClipItem(content: "expired", createdAt: now.addingTimeInterval(-7200))
        let fresh = ClipItem(content: "fresh", createdAt: now)
        context.insert(expired)
        context.insert(fresh)
        try context.save()

        let candidates = ClipboardManager.fetchExpiredCandidates(in: context, cutoff: cutoff)

        #expect(candidates.count == 1)
        #expect(candidates.first?.content == "expired")
    }

    @Test("Predicate excludes pinned items even when expired")
    func predicateExcludesPinned() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let cutoff = Date()
        let ancient = Date().addingTimeInterval(-86_400)

        let pinned = ClipItem(content: "pinned-expired", isPinned: true, createdAt: ancient)
        let unpinned = ClipItem(content: "unpinned-expired", isPinned: false, createdAt: ancient)
        context.insert(pinned)
        context.insert(unpinned)
        try context.save()

        let candidates = ClipboardManager.fetchExpiredCandidates(in: context, cutoff: cutoff)

        #expect(candidates.count == 1)
        #expect(candidates.first?.content == "unpinned-expired")
    }

    @Test("Predicate uses strict less-than at the cutoff boundary")
    func predicateStrictLessThan() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let cutoff = Date()

        let atBoundary = ClipItem(content: "boundary", createdAt: cutoff)
        let justBefore = ClipItem(content: "just-before", createdAt: cutoff.addingTimeInterval(-1))
        context.insert(atBoundary)
        context.insert(justBefore)
        try context.save()

        let candidates = ClipboardManager.fetchExpiredCandidates(in: context, cutoff: cutoff)

        // `< cutoff` is strict: an item created AT the cutoff is not expired yet.
        #expect(candidates.count == 1)
        #expect(candidates.first?.content == "just-before")
    }

    @Test("Empty store yields empty candidate list (no crash)")
    func emptyStoreReturnsEmpty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let candidates = ClipboardManager.fetchExpiredCandidates(in: context, cutoff: Date())

        #expect(candidates.isEmpty)
    }

    @Test("Preserved-group filter excludes items in preserveItems group")
    func preservedGroupFilterExcludesPreservedItems() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let ancient = Date().addingTimeInterval(-86_400)

        let keeperGroup = SmartGroup(name: "Keeper", preservesItems: true)
        let normalGroup = SmartGroup(name: "Normal", preservesItems: false)
        context.insert(keeperGroup)
        context.insert(normalGroup)

        let preservedItem = ClipItem(content: "in-keeper", createdAt: ancient)
        preservedItem.groupName = "Keeper"
        let normalItem = ClipItem(content: "in-normal", createdAt: ancient)
        normalItem.groupName = "Normal"
        let ungroupedItem = ClipItem(content: "ungrouped", createdAt: ancient)
        context.insert(preservedItem)
        context.insert(normalItem)
        context.insert(ungroupedItem)
        try context.save()

        let candidates = ClipboardManager.fetchExpiredCandidates(in: context, cutoff: Date())
        let preservedNames = SmartGroupRetention.preservedGroupNames(in: context)
        let deletable = SmartGroupRetention.filterDeletableItems(candidates, preservedGroupNames: preservedNames)

        let deletableContents = Set(deletable.map(\.content))
        #expect(candidates.count == 3)
        #expect(deletable.count == 2)
        #expect(deletableContents == ["in-normal", "ungrouped"])
    }

    @Test("New SQL+memory pipeline matches the old all-in-memory pipeline (regression oracle)")
    func newPipelineMatchesOldBehavior() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let cutoff = Date()
        let ancient = cutoff.addingTimeInterval(-86_400)
        let future = cutoff.addingTimeInterval(86_400)

        // Mixed dataset: pinned/unpinned × past/future × grouped/ungrouped × preserved/normal group
        let keeper = SmartGroup(name: "Keeper", preservesItems: true)
        let normal = SmartGroup(name: "Normal", preservesItems: false)
        context.insert(keeper)
        context.insert(normal)

        func make(_ label: String, age: Date, pinned: Bool, group: String? = nil) -> ClipItem {
            let item = ClipItem(content: label, isPinned: pinned, createdAt: age)
            item.groupName = group
            context.insert(item)
            return item
        }

        let scenarios = [
            make("a-past-unpinned-nogroup", age: ancient, pinned: false),
            make("b-past-pinned-nogroup", age: ancient, pinned: true),
            make("c-past-unpinned-keeper", age: ancient, pinned: false, group: "Keeper"),
            make("d-past-pinned-keeper", age: ancient, pinned: true, group: "Keeper"),
            make("e-past-unpinned-normal", age: ancient, pinned: false, group: "Normal"),
            make("f-future-unpinned-nogroup", age: future, pinned: false),
            make("g-future-pinned-nogroup", age: future, pinned: true),
        ]
        try context.save()

        // OLD pipeline: fetch all, filter in memory by all 3 conditions
        let oldDescriptor = FetchDescriptor<ClipItem>()
        let allItems = try context.fetch(oldDescriptor)
        let preservedNames = SmartGroupRetention.preservedGroupNames(in: context)
        let oldResult = Set(allItems.filter {
            $0.createdAt < cutoff
                && !$0.isPinned
                && !SmartGroupRetention.shouldPreserve(item: $0, preservedGroupNames: preservedNames)
        }.map(\.content))

        // NEW pipeline: SQL predicate fetch + memory preserved-group filter
        let candidates = ClipboardManager.fetchExpiredCandidates(in: context, cutoff: cutoff)
        let newResult = Set(
            SmartGroupRetention.filterDeletableItems(candidates, preservedGroupNames: preservedNames)
                .map(\.content)
        )

        #expect(oldResult == newResult, "New pipeline must produce the exact same delete set as the old one")
        // Sanity: we expect a, e to be the only deletable ones in this dataset.
        #expect(newResult == ["a-past-unpinned-nogroup", "e-past-unpinned-normal"])
        _ = scenarios // keep references; quiet unused warning
    }
}
