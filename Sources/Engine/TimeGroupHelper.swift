import Foundation

enum HistorySortMode: String, CaseIterable {
    case created
    case lastUsed

    @MainActor
    var label: String {
        switch self {
        case .created: return L10n.tr("detail.created")
        case .lastUsed: return L10n.tr("detail.lastUsed")
        }
    }

    func date(for item: ClipItem) -> Date {
        switch self {
        case .created: return item.createdAt
        case .lastUsed: return item.lastUsedAt
        }
    }
}

enum TimeGroup: String, CaseIterable {
    case pinned
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case older

    @MainActor
    var label: String {
        switch self {
        case .pinned: return L10n.tr("time.pinned")
        case .today: return L10n.tr("time.today")
        case .yesterday: return L10n.tr("time.yesterday")
        case .thisWeek: return L10n.tr("time.thisWeek")
        case .thisMonth: return L10n.tr("time.thisMonth")
        case .older: return L10n.tr("time.older")
        }
    }

    static func group(for date: Date, isPinned: Bool) -> TimeGroup {
        if isPinned { return .pinned }
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
           date >= weekAgo { return .thisWeek }
        if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now),
           date >= monthAgo { return .thisMonth }
        return .older
    }
}

struct GroupedItem<T> {
    let group: TimeGroup
    var items: [T]
}

func groupItemsByTime(
    _ items: [ClipItem],
    sortMode: HistorySortMode = .lastUsed,
    separatePinned: Bool = true
) -> [GroupedItem<ClipItem>] {
    var groups: [TimeGroup: [ClipItem]] = [:]

    for item in items {
        let isPinned = separatePinned ? item.isPinned : false
        let group = TimeGroup.group(for: sortMode.date(for: item), isPinned: isPinned)
        groups[group, default: []].append(item)
    }

    return TimeGroup.allCases.compactMap { group in
        guard let items = groups[group], !items.isEmpty else { return nil }
        return GroupedItem(group: group, items: items)
    }
}
