import SwiftUI
import SwiftData
import Combine

extension Notification.Name {
    static let typeOrderDidChange = Notification.Name("typeOrderDidChange")
}

@MainActor
@Observable
final class ClipItemStore {
    enum QueryValue<T> {
        case unchanged
        case set(T)
    }

    /// All active store instances — used by deleteAndNotify to synchronously remove items
    private static var activeStores = NSHashTable<AnyObject>.weakObjects()

    private(set) var items: [ClipItem] = []
    private(set) var hasMore = true
    private(set) var totalCount = 0
    private(set) var availableTypes: [ClipContentType] = []

    static let historySortModeKey = "historySortMode"

    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            cancelPendingSearchDebounce()
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                executeSearch()
                return
            }
            searchDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                self?.executeSearch()
                self?.searchDebounceTask = nil
            }
        }
    }

    private var searchDebounceTask: Task<Void, Never>?

    private func cancelPendingSearchDebounce() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
    }

    private func executeSearch() {
        currentOffset = 0
        hasMore = true
        let ids = queryItemIDs(offset: 0, limit: pageSize)
        items = hydrateItems(ids: ids)
        hasMore = ids.count >= pageSize
        currentOffset = ids.count
    }

    var filterType: ClipContentType? = nil
    var pinnedOnly: Bool = false
    var sensitiveOnly: Bool = false
    var sourceApp: FilteredApp? = nil
    var groupName: String? = nil
    var sortMode: HistorySortMode = {
        let raw = UserDefaults.standard.string(forKey: ClipItemStore.historySortModeKey) ?? HistorySortMode.lastUsed.rawValue
        return HistorySortMode(rawValue: raw) ?? .lastUsed
    }() {
        didSet {
            guard sortMode != oldValue else { return }
            UserDefaults.standard.set(sortMode.rawValue, forKey: Self.historySortModeKey)
            currentOffset = 0
            reload()
        }
    }

    /// Call after changing filter properties to apply them in one reload
    func applyFilters() {
        currentOffset = 0
        reload()
    }

    /// Update multiple query inputs in one pass to avoid stacked search debounce
    /// and immediate reload work from separate property writes.
    func updateQuery(
        searchText: QueryValue<String> = .unchanged,
        filterType: QueryValue<ClipContentType?> = .unchanged,
        pinnedOnly: Bool? = nil,
        sensitiveOnly: Bool? = nil,
        sourceApp: QueryValue<FilteredApp?> = .unchanged,
        groupName: QueryValue<String?> = .unchanged
    ) {
        cancelPendingSearchDebounce()

        let nextSearchText: String = switch searchText {
        case .unchanged: self.searchText
        case .set(let value): value
        }
        let nextFilterType: ClipContentType? = switch filterType {
        case .unchanged: self.filterType
        case .set(let value): value
        }
        let nextPinnedOnly = pinnedOnly ?? self.pinnedOnly
        let nextSensitiveOnly = sensitiveOnly ?? self.sensitiveOnly
        let nextSourceApp: FilteredApp? = switch sourceApp {
        case .unchanged: self.sourceApp
        case .set(let value): value
        }
        let nextGroupName: String? = switch groupName {
        case .unchanged: self.groupName
        case .set(let value): value
        }

        let changed =
            nextSearchText != self.searchText ||
            nextFilterType != self.filterType ||
            nextPinnedOnly != self.pinnedOnly ||
            nextSensitiveOnly != self.sensitiveOnly ||
            nextSourceApp != self.sourceApp ||
            nextGroupName != self.groupName

        self.searchText = nextSearchText
        self.filterType = nextFilterType
        self.pinnedOnly = nextPinnedOnly
        self.sensitiveOnly = nextSensitiveOnly
        self.sourceApp = nextSourceApp
        self.groupName = nextGroupName

        guard changed else { return }
        currentOffset = 0

        let trimmed = nextSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            reload()
            return
        }

        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.executeSearch()
            self?.searchDebounceTask = nil
        }
    }

    var sortPinnedFirst = false
    var isActive = false
    /// Set true during bulk operations (import/restore) to suppress observer reloads
    static var isBulkOperation = false

    private let pageSize = 50
    private var isLoadingMore = false
    private var currentOffset = 0
    private var modelContext: ModelContext?
    private var observer: AnyCancellable?
    private var typeOrderObserver: AnyCancellable?
    private var _db: SQLiteConnection?

    enum FilteredApp: Equatable {
        case named(String)
        case unknown
    }

    private var needsRefresh = true

    func configure(modelContext: ModelContext, reloadData: Bool = true) {
        let isFirstTime = self.modelContext == nil
        self.modelContext = modelContext
        if isFirstTime {
            Self.activeStores.add(self)
            observeChanges()
        }
        invalidateDB()
        if needsRefresh {
            refreshAvailableTypes()
            refreshSidebarCounts()
            refreshSourceApps()
            needsRefresh = false
        }
        if reloadData {
            reload()
        }
    }

    // MARK: - Public

    func reload() {
        cancelPendingSearchDebounce()
        let loadCount = max(currentOffset, pageSize)
        currentOffset = 0
        hasMore = true
        let ids = queryItemIDs(offset: 0, limit: loadCount)
        items = hydrateItems(ids: ids)
        hasMore = ids.count >= loadCount
        currentOffset = ids.count
        totalCount = queryTotalCount()
    }

    func loadMore() {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        let ids = queryItemIDs(offset: currentOffset, limit: pageSize)
        let hydrated = hydrateItems(ids: ids)
        items.append(contentsOf: hydrated)
        hasMore = ids.count >= pageSize
        currentOffset += ids.count
        isLoadingMore = false
    }

    func removeItems(matching ids: Set<PersistentIdentifier>) {
        items.removeAll { ids.contains($0.persistentModelID) }
    }

    func resetFilters() {
        filterType = nil
        pinnedOnly = false
        sensitiveOnly = false
        sourceApp = nil
        groupName = nil
        searchText = ""
        currentOffset = 0
        reload()
    }

    /// Hydrate SwiftData objects by itemID, preserving SQL sort order
    private func hydrateItems(ids: [String]) -> [ClipItem] {
        guard let context = modelContext, !ids.isEmpty else { return [] }
        var seen = Set<String>()
        let uniqueIDs = ids.filter { seen.insert($0).inserted }
        // Batch fetch in chunks to avoid N individual queries
        var map: [String: ClipItem] = [:]
        map.reserveCapacity(uniqueIDs.count)
        let chunkSize = 50
        for start in stride(from: 0, to: uniqueIDs.count, by: chunkSize) {
            let end = min(start + chunkSize, uniqueIDs.count)
            let chunkIDs = Array(uniqueIDs[start..<end])
            let predicate = #Predicate<ClipItem> { item in
                chunkIDs.contains(item.itemID)
            }
            let desc = FetchDescriptor<ClipItem>(predicate: predicate)
            if let fetched = try? context.fetch(desc) {
                for item in fetched {
                    map[item.itemID] = item
                }
            }
        }
        return uniqueIDs.compactMap { map[$0] }
    }

    /// Quick check: get the itemID of the latest item (no filters)
    func queryFirstItemID() -> String? {
        guard let db = openDB() else { return nil }
        var conditions: [String] = []
        var params: [Any] = []
        addRetentionCondition(&conditions, &params)
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return db.queryStrings("SELECT ZITEMID FROM ZCLIPITEM \(whereClause) \(orderByClause(pinnedFirst: false)) LIMIT 1", params: params).first
    }

    // MARK: - SQL Queries

    private func queryItemIDs(offset: Int, limit: Int) -> [String] {
        guard let db = openDB() else { return [] }


        var conditions: [String] = []
        var params: [Any] = []

        addRetentionCondition(&conditions, &params)
        addFilterConditions(&conditions, &params)
        addSearchCondition(&conditions, &params)

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let orderBy = orderByClause(pinnedFirst: sortPinnedFirst)

        params.append(limit)
        params.append(offset)
        return db.queryStrings(
            "SELECT DISTINCT ZITEMID FROM ZCLIPITEM \(whereClause) \(orderBy) LIMIT ? OFFSET ?",
            params: params
        )
    }



    private func queryTotalCount() -> Int {
        guard let db = openDB() else { return 0 }

        var conditions: [String] = []
        var params: [Any] = []

        addRetentionCondition(&conditions, &params)
        addFilterConditions(&conditions, &params)
        addSearchCondition(&conditions, &params)

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return db.queryInt("SELECT COUNT(*) FROM ZCLIPITEM \(whereClause)", params: params)
    }

    private var sortColumn: String {
        switch sortMode {
        case .created:
            return "ZCREATEDAT"
        case .lastUsed:
            return "ZLASTUSEDAT"
        }
    }

    private func orderByClause(pinnedFirst: Bool) -> String {
        pinnedFirst
            ? "ORDER BY ZISPINNED DESC, \(sortColumn) DESC"
            : "ORDER BY \(sortColumn) DESC"
    }

    // MARK: - Condition Builders

    private func addRetentionCondition(_ conditions: inout [String], _ params: inout [Any]) {
        guard let cutoff = ProManager.shared.retentionCutoffDate else { return }
        let cutoffVal = cutoff.timeIntervalSince(Date(timeIntervalSinceReferenceDate: 0))
        conditions.append("(ZISPINNED = 1 OR ZCREATEDAT >= ?)")
        params.append(cutoffVal)
    }

    private func addFilterConditions(_ conditions: inout [String], _ params: inout [Any]) {
        if let type = filterType {
            conditions.append("ZCONTENTTYPERAW = ?")
            params.append(type.rawValue)
        }
        if pinnedOnly { conditions.append("ZISPINNED = 1") }
        if sensitiveOnly { conditions.append("ZISSENSITIVE = 1") }
        if let app = sourceApp {
            switch app {
            case .named(let name):
                conditions.append("ZSOURCEAPP = ?")
                params.append(name)
            case .unknown:
                conditions.append("ZSOURCEAPP IS NULL")
            }
        }
        if let groupName {
            conditions.append("ZGROUPNAME = ?")
            params.append(groupName)
        }
    }

    private func addSearchCondition(_ conditions: inout [String], _ params: inout [Any]) {
        guard !searchText.isEmpty else { return }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pattern = "%\(trimmed)%"
        conditions.append(
            "ZITEMID IN (SELECT itemID FROM clip_fts WHERE content LIKE ? OR displayTitle LIKE ? OR linkTitle LIKE ? OR ocrText LIKE ?)"
        )
        params.append(pattern)
        params.append(pattern)
        params.append(pattern)
        params.append(pattern)
    }

    // MARK: - Metadata Queries

    func refreshAvailableTypes() {
        guard let db = openDB() else { return }

        let rawTypes = db.queryStrings("SELECT DISTINCT ZCONTENTTYPERAW FROM ZCLIPITEM")
        let existingTypes = Set(rawTypes.compactMap { ClipContentType(rawValue: $0) })
        availableTypes = ClipContentType.visibleCases.filter { type in
            ProManager.shared.canUseContentType(type) && existingTypes.contains(type)
        }
    }

    // MARK: - Sidebar Counts (cached, refreshed on data change)

    var sidebarCounts = SidebarCounts()

    struct SidebarCounts {
        var all = 0
        var pinned = 0
        var sensitive = 0
        var byType: [ClipContentType: Int] = [:]
        var byApp: [String?: Int] = [:]  // nil key = unknown app
        var byGroup: [(name: String, icon: String, count: Int)] = []
    }

    func refreshSidebarCounts() {
        guard let db = openDB() else { return }
        var counts = SidebarCounts()
        let summary = db.queryIntRow(
            """
            SELECT COUNT(*),
                   COALESCE(SUM(CASE WHEN ZISPINNED = 1 THEN 1 ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN ZISSENSITIVE = 1 THEN 1 ELSE 0 END), 0)
            FROM ZCLIPITEM
            """,
            columnCount: 3
        )
        counts.all = summary[0]
        counts.pinned = summary[1]
        counts.sensitive = summary[2]

        let visibleTypes = Set(ClipContentType.visibleCases)
        for (rawType, count) in db.queryStringIntPairs(
            "SELECT ZCONTENTTYPERAW, COUNT(*) FROM ZCLIPITEM GROUP BY ZCONTENTTYPERAW"
        ) {
            guard count > 0,
                  let type = ClipContentType(rawValue: rawType),
                  visibleTypes.contains(type) else { continue }
            counts.byType[type] = count
        }

        for (app, count) in db.queryStringIntPairs(
            "SELECT ZSOURCEAPP, COUNT(*) FROM ZCLIPITEM WHERE ZSOURCEAPP IS NOT NULL GROUP BY ZSOURCEAPP ORDER BY ZSOURCEAPP"
        ) {
            counts.byApp[app] = count
        }

        let nullCount = db.queryInt("SELECT COUNT(*) FROM ZCLIPITEM WHERE ZSOURCEAPP IS NULL")
        if nullCount > 0 { counts.byApp[nil] = nullCount }

        counts.byGroup = db.queryStringStringIntTuples(
            "SELECT ZNAME, COALESCE(ZICON, 'folder'), ZCOUNT FROM ZSMARTGROUP ORDER BY ZSORTORDER"
        ).map { (name: $0.0, icon: $0.1, count: $0.2) }

        sidebarCounts = counts
    }

    private(set) var sourceApps: [String] = []

    private func refreshSourceApps() {
        guard let db = openDB() else { return }
        var apps = db.queryStrings(
            "SELECT DISTINCT ZSOURCEAPP FROM ZCLIPITEM WHERE ZSOURCEAPP IS NOT NULL ORDER BY ZSOURCEAPP"
        )
        if !db.queryStrings("SELECT 1 FROM ZCLIPITEM WHERE ZSOURCEAPP IS NULL LIMIT 1").isEmpty {
            apps.append("")
        }
        sourceApps = apps
    }

    // MARK: - Helpers

    private func openDB() -> SQLiteConnection? {
        if let db = _db { return db }
        guard let url = storeURL else { return nil }
        _db = SQLiteConnection(path: url.path)
        return _db
    }

    private var storeURL: URL? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo"
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport.appendingPathComponent(bundleID).appendingPathComponent("PasteMemo.store")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var isRefreshing = false
    private var skipNextThrottledRefresh = false

    /// Post this notification after pin/sensitive/delete to trigger immediate reload
    static let itemDidUpdateNotification = Notification.Name("ClipItemStoreItemDidUpdate")
    /// Post this notification after content/title/OCR updates that do not affect sidebar counts
    static let itemContentDidUpdateNotification = Notification.Name("ClipItemStoreItemContentDidUpdate")
    /// Post this notification after `lastUsedAt` updates to trigger a lightweight reorder refresh
    static let itemLastUsedDidUpdateNotification = Notification.Name("ClipItemStoreItemLastUsedDidUpdate")

    /// Remove items from store, delete from context, save, and notify.
    /// This is the ONLY safe way to delete ClipItems — ensures store.items
    /// is updated before context.save() triggers SwiftUI re-render.
    static func deleteAndNotify(_ itemsToDelete: [ClipItem], from context: ModelContext) {
        // Pause clipboard monitoring to prevent cleanExpiredItems from firing
        // during deletion (nested RunLoops can trigger the timer's Task)
        let wasPaused = ClipboardManager.shared.isPaused
        if !wasPaused { ClipboardManager.shared.pauseMonitoring() }

        // Remove only the deleted items from stores (avoids full-list flash).
        let idsToDelete = Set(itemsToDelete.map(\.persistentModelID))
        for case let store as ClipItemStore in activeStores.allObjects {
            store.items.removeAll { idsToDelete.contains($0.persistentModelID) }
        }
        // Suppress observer reloads during bulk deletion
        isBulkOperation = true
        for item in itemsToDelete {
            context.delete(item)
        }
        isBulkOperation = false
        saveAndNotify(context)

        if !wasPaused { ClipboardManager.shared.resumeMonitoring() }
    }

    /// Save context then trigger immediate UI refresh across all store instances
    static func saveAndNotify(_ context: ModelContext) {
        try? context.save()
        NotificationCenter.default.post(name: itemDidUpdateNotification, object: nil)
    }

    /// Save context then trigger a lightweight refresh when searchable content changed
    /// but sidebar counts and available types do not need to be recomputed.
    static func saveAndNotifyContent(_ context: ModelContext) {
        try? context.save()
        NotificationCenter.default.post(name: itemContentDidUpdateNotification, object: nil)
    }

    /// Save context then trigger a lightweight list reorder refresh across all store instances
    static func saveAndNotifyLastUsed(_ context: ModelContext) {
        try? context.save()
        NotificationCenter.default.post(name: itemLastUsedDidUpdateNotification, object: nil)
    }

    private var immediateObserver: AnyCancellable?
    private var lightweightObserver: AnyCancellable?
    private var contentObserver: AnyCancellable?

    private func observeChanges() {
        observer = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextDidSave)
            .throttle(for: .seconds(0.5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self, self.isActive, !self.isRefreshing, !ClipItemStore.isBulkOperation else {
                    self?.needsRefresh = true
                    return
                }
                // Skip if already refreshed by immediate observer
                if self.skipNextThrottledRefresh {
                    self.skipNextThrottledRefresh = false
                    return
                }
                self.performRefresh()
            }

        immediateObserver = NotificationCenter.default
            .publisher(for: Self.itemDidUpdateNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isActive, !self.isRefreshing else { return }
                self.skipNextThrottledRefresh = true
                self.performRefresh()
            }

        lightweightObserver = NotificationCenter.default
            .publisher(for: Self.itemLastUsedDidUpdateNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isActive, !self.isRefreshing else { return }
                self.skipNextThrottledRefresh = true
                self.performLightweightRefresh()
            }

        contentObserver = NotificationCenter.default
            .publisher(for: Self.itemContentDidUpdateNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isActive, !self.isRefreshing else { return }
                self.skipNextThrottledRefresh = true
                self.performLightweightRefresh()
            }

        typeOrderObserver = NotificationCenter.default
            .publisher(for: .typeOrderDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAvailableTypes()
            }
    }

    private func performRefresh() {
        isRefreshing = true
        invalidateDB()
        refreshAvailableTypes()
        refreshSidebarCounts()
        refreshSourceApps()
        needsRefresh = false
        reload()
        isRefreshing = false
    }

    private func performLightweightRefresh() {
        isRefreshing = true
        invalidateDB()
        needsRefresh = false
        reload()
        isRefreshing = false
    }

    /// Close the cached raw SQLite connection so the next query opens a fresh one
    /// that sees the latest SwiftData/CoreData WAL writes.
    private func invalidateDB() {
        _db?.close()
        _db = nil
    }

}
