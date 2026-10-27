import Foundation

/// The time menu on the storage pages. "N 个月前" means *older than* that — the menu is for
/// clearing out old history, not for browsing recent clips.
enum StorageTimeFilter: Hashable, Sendable {
    case all
    case olderThan(months: Int)
    /// Whole days, both ends included.
    case range(from: Date, to: Date)

    static let presetMonths = [1, 3, 6, 12]

    func contains(_ date: Date, now: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .all:
            return true
        case .olderThan(let months):
            guard let cutoff = calendar.date(byAdding: .month, value: -months, to: now) else { return true }
            return date < cutoff
        case .range(let from, let to):
            let start = calendar.startOfDay(for: min(from, to))
            guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to))) else {
                return date >= start
            }
            return date >= start && date < end
        }
    }
}

struct StorageFilter: Hashable, Sendable {
    var time: StorageTimeFilter = .all
    /// Empty = every type.
    var categories: Set<StorageCategory> = []

    func matches(_ record: StorageRecord, now: Date, calendar: Calendar = .current) -> Bool {
        (categories.isEmpty || categories.contains(record.category))
            && time.contains(record.createdAt, now: now, calendar: calendar)
    }
}

/// One row of the "管理存储空间" table.
struct StorageSourceSummary: Identifiable, Hashable, Sendable {
    /// `sourceName ?? ""` — the unknown source gets the empty key, like the main window's sidebar.
    var id: String { sourceName ?? "" }
    let sourceName: String?
    let count: Int
    let bytes: Int64
    let latest: Date
}

struct StorageCategoryTotal: Hashable, Sendable {
    let category: StorageCategory
    let count: Int
    let bytes: Int64
    var latest: Date = .distantPast
}

enum StorageGroupSort: Hashable, Sendable {
    case bytes, latest, count, name
}

/// What the manage page lists by.
enum StorageGrouping: Hashable, Sendable {
    case source, type
}

/// One row of the manage page, and what its detail page shows.
enum StorageGroupKey: Hashable, Sendable {
    /// Source name; "" = clips with no recorded source.
    case source(String)
    case category(StorageCategory)

    func contains(_ record: StorageRecord) -> Bool {
        switch self {
        case .source(let name): return (record.sourceName ?? "") == name
        case .category(let category): return record.category == category
        }
    }
}

struct StorageGroupSummary: Identifiable, Hashable, Sendable {
    let key: StorageGroupKey
    let count: Int
    let bytes: Int64
    let latest: Date
    var id: StorageGroupKey { key }
}

enum StorageQuery {
    /// Records the storage pages may delete under `filter`: protected clips (pinned, "永久保存"
    /// groups) never show up, so every count and size on those pages is what deleting frees.
    static func deletable(
        _ records: [StorageRecord], filter: StorageFilter, now: Date, calendar: Calendar = .current
    ) -> [StorageRecord] {
        records.filter { !$0.isProtected && filter.matches($0, now: now, calendar: calendar) }
    }

    static func groups(_ records: [StorageRecord], by grouping: StorageGrouping, sort: StorageGroupSort = .bytes) -> [StorageGroupSummary] {
        switch grouping {
        case .source:
            return sources(records, sort: sort).map {
                StorageGroupSummary(key: .source($0.id), count: $0.count, bytes: $0.bytes, latest: $0.latest)
            }
        case .type:
            return categoryTotals(records, sort: sort).map {
                StorageGroupSummary(key: .category($0.category), count: $0.count, bytes: $0.bytes, latest: $0.latest)
            }
        }
    }

    static func sources(_ records: [StorageRecord], sort: StorageGroupSort = .bytes) -> [StorageSourceSummary] {
        var totals: [String: (name: String?, count: Int, bytes: Int64, latest: Date)] = [:]
        for record in records {
            let key = record.sourceName ?? ""
            var entry = totals[key] ?? (record.sourceName, 0, 0, .distantPast)
            entry.count += 1
            entry.bytes += record.bytes
            entry.latest = max(entry.latest, record.createdAt)
            totals[key] = entry
        }
        let rows = totals.values.map {
            StorageSourceSummary(sourceName: $0.name, count: $0.count, bytes: $0.bytes, latest: $0.latest)
        }
        return rows.sorted { a, b in
            switch sort {
            case .bytes where a.bytes != b.bytes: return a.bytes > b.bytes
            case .latest where a.latest != b.latest: return a.latest > b.latest
            case .count where a.count != b.count: return a.count > b.count
            default:
                // Ties (and .name) fall back to the name; the unknown source sorts last.
                switch (a.sourceName, b.sourceName) {
                case let (x?, y?): return x.localizedStandardCompare(y) == .orderedAscending
                case (nil, _): return false
                case (_, nil): return true
                }
            }
        }
    }

    /// Per-type totals, largest first by default; types with no clips are left out. Name order
    /// is the menus' order (`StorageCategory.allCases`).
    static func categoryTotals(_ records: [StorageRecord], sort: StorageGroupSort = .bytes) -> [StorageCategoryTotal] {
        var totals: [StorageCategory: (count: Int, bytes: Int64, latest: Date)] = [:]
        for record in records {
            var entry = totals[record.category] ?? (0, 0, .distantPast)
            entry.count += 1
            entry.bytes += record.bytes
            entry.latest = max(entry.latest, record.createdAt)
            totals[record.category] = entry
        }
        let order = Dictionary(uniqueKeysWithValues: StorageCategory.allCases.enumerated().map { ($1, $0) })
        return totals
            .map { StorageCategoryTotal(category: $0.key, count: $0.value.count, bytes: $0.value.bytes, latest: $0.value.latest) }
            .sorted { a, b in
                switch sort {
                case .bytes where a.bytes != b.bytes: return a.bytes > b.bytes
                case .latest where a.latest != b.latest: return a.latest > b.latest
                case .count where a.count != b.count: return a.count > b.count
                default: return order[a.category, default: 0] < order[b.category, default: 0]
                }
            }
    }
}

/// Click selection for the storage lists. A click — with or without ⌘ — toggles one row and
/// becomes the anchor; ⇧-click selects every row from the anchor to the clicked one, like
/// Finder. Rows keep their checkbox meaning, so a plain click never clears the others.
struct StorageClickSelection<ID: Hashable> {
    private(set) var anchor: ID?

    mutating func click(_ id: ID, extendingRange: Bool, order: [ID], selection: inout Set<ID>) {
        if extendingRange, let anchor,
           let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            selection.formUnion(order[min(from, to)...max(from, to)])
            return
        }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        anchor = id
    }
}
