import Foundation
import SwiftData

enum SmartGroupRetention {
    @MainActor
    static func preservedGroupNames(in context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.preservesItems })
        let groups = (try? context.fetch(descriptor)) ?? []
        return Set(groups.map(\.name))
    }

    static func shouldPreserve(item: ClipItem, preservedGroupNames: Set<String>) -> Bool {
        guard let groupName = item.groupName, !groupName.isEmpty else { return false }
        return preservedGroupNames.contains(groupName)
    }

    static func filterDeletableItems(_ items: [ClipItem], preservedGroupNames: Set<String>) -> [ClipItem] {
        items.filter { !shouldPreserve(item: $0, preservedGroupNames: preservedGroupNames) }
    }
}
