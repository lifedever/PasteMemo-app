import Foundation
import SwiftData

/// A shorter lifetime for clips marked sensitive — detected passwords / tokens, or
/// marked by hand or by a rule. Counted from the last copy or paste (`lastUsedAt`),
/// so a password still in use isn't pulled out from under the user. Pinned clips
/// and clips in "keep permanently" groups stay, same as the history retention.
enum SensitiveRetention {
    static let MINUTES_KEY = "sensitiveRetentionMinutes"
    /// 0 = no separate limit, the history retention applies.
    static let OPTIONS = [0, 10, 60, 1440, 10080]

    static var minutes: Int { max(UserDefaults.standard.integer(forKey: MINUTES_KEY), 0) }

    static func cutoff(minutes: Int = minutes, now: Date = Date()) -> Date? {
        guard minutes > 0 else { return nil }
        return now.addingTimeInterval(-TimeInterval(minutes) * 60)
    }

    @MainActor
    static func expiredItems(in context: ModelContext, cutoff: Date) -> [ClipItem] {
        let descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.isSensitive && !$0.isPinned && $0.lastUsedAt < cutoff }
        )
        let candidates = (try? context.fetch(descriptor)) ?? []
        guard !candidates.isEmpty else { return [] }
        return SmartGroupRetention.filterDeletableItems(
            candidates, preservedGroupNames: SmartGroupRetention.preservedGroupNames(in: context)
        )
    }
}
