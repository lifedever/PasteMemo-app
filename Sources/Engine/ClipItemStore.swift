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

    var searchText: String = "" {
        didSet {
            guard !isApplyingBatchQuery else { return }
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
    private var isApplyingBatchQuery = false

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
    var aiAgentOnly: Bool = false
    var sourceApp: FilteredApp? = nil
    var groupName: String? = nil

    /// Call after changing filter properties to apply them in one reload
    func applyFilters() {
        currentOffset = 0
        reload()
    }

    func updateQuery(
        searchText: QueryValue<String> = .unchanged,
        filterType: QueryValue<ClipContentType?> = .unchanged,
        pinnedOnly: Bool? = nil,
        sensitiveOnly: Bool? = nil,
        aiAgentOnly: Bool? = nil,
        sourceApp: QueryValue<FilteredApp?> = .unchanged,
        groupName: QueryValue<String?> = .unchanged
    ) {
        cancelPendingSearchDebounce()
        isApplyingBatchQuery = true
        defer { isApplyingBatchQuery = false }

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
        let nextAIAgentOnly = aiAgentOnly ?? self.aiAgentOnly
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
            nextAIAgentOnly != self.aiAgentOnly ||
            nextSourceApp != self.sourceApp ||
            nextGroupName != self.groupName

        self.searchText = nextSearchText
        self.filterType = nextFilterType
        self.pinnedOnly = nextPinnedOnly
        self.sensitiveOnly = nextSensitiveOnly
        self.aiAgentOnly = nextAIAgentOnly
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

    private(set) var needsRefresh = true

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

    /// Consume the `needsRefresh` flag set by observers while the store was inactive.
    /// No-op when clean — safe to call on every quick panel show.
    func refreshIfNeeded() {
        guard needsRefresh else { return }
        performRefresh()
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
        aiAgentOnly = false
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

    private func orderByClause(pinnedFirst: Bool) -> String {
        pinnedFirst
            ? "ORDER BY ZISPINNED DESC, ZLASTUSEDAT DESC"
            : "ORDER BY ZLASTUSEDAT DESC"
    }

    // MARK: - Condition Builders

    private func addRetentionCondition(_ conditions: inout [String], _ params: inout [Any]) {
        guard let cutoff = ProManager.shared.retentionCutoffDate else { return }
        let cutoffVal = cutoff.timeIntervalSince(Date(timeIntervalSinceReferenceDate: 0))
        // Must mirror ClipboardManager.cleanExpiredItems' preservation logic:
        // items in `preservesItems = true` groups survive deletion, so they
        // must also survive the query filter. Without this, those items become
        // invisible "dark matter" — still matched by findExistingDuplicate
        // (which doesn't apply retention), so a fresh copy of the same content
        // gets merged into the hidden row and the user sees no UI feedback.
        conditions.append("""
            (ZISPINNED = 1
             OR ZCREATEDAT >= ?
             OR ZGROUPNAME IN (SELECT ZNAME FROM ZSMARTGROUP WHERE ZPRESERVESITEMS = 1))
        """)
        params.append(cutoffVal)
    }

    private func addFilterConditions(_ conditions: inout [String], _ params: inout [Any]) {
        if let type = filterType {
            // Mixed items carry multiple independent representations — they should appear
            // under every category whose corresponding auxiliary field is populated.
            if let mixedClause = Self.mixedCrossoverSQL(for: type) {
                conditions.append("(ZCONTENTTYPERAW = ? OR \(mixedClause))")
            } else {
                conditions.append("ZCONTENTTYPERAW = ?")
            }
            params.append(type.rawValue)
        }
        if pinnedOnly { conditions.append("ZISPINNED = 1") }
        if sensitiveOnly { conditions.append("ZISSENSITIVE = 1") }
        if aiAgentOnly { conditions.append("ZAGENTSOURCE IS NOT NULL") }
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

    /// Extra SQL (parameter-less) that lets `.mixed` items surface under cross-category filters
    /// based on which auxiliary representation they carry. Nil means strict match only.
    static func mixedCrossoverSQL(for type: ClipContentType) -> String? {
        switch type {
        case .image:
            return "(ZCONTENTTYPERAW = 'mixed' AND ZIMAGEDATA IS NOT NULL)"
        case .file:
            return "(ZCONTENTTYPERAW = 'mixed' AND ZFILEPATHS IS NOT NULL AND ZFILEPATHS != '')"
        case .text:
            return "(ZCONTENTTYPERAW = 'mixed' AND ZCONTENT IS NOT NULL AND ZCONTENT != '' AND ZCONTENT != '[Mixed]')"
        default:
            return nil
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
        var existingTypes = Set(rawTypes.compactMap { ClipContentType(rawValue: $0) })
        // A mixed item grants visibility to every crossover category its auxiliary fields populate,
        // so the sidebar exposes an entry point even when no strict-typed item exists yet.
        if existingTypes.contains(.mixed) {
            for (type, clause) in [
                (ClipContentType.image, "ZIMAGEDATA IS NOT NULL"),
                (ClipContentType.file,  "ZFILEPATHS IS NOT NULL AND ZFILEPATHS != ''"),
                (ClipContentType.text,  "ZCONTENT IS NOT NULL AND ZCONTENT != '' AND ZCONTENT != '[Mixed]'"),
            ] {
                if db.queryInt("SELECT COUNT(*) FROM ZCLIPITEM WHERE ZCONTENTTYPERAW = 'mixed' AND \(clause)") > 0 {
                    existingTypes.insert(type)
                }
            }
        }
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
        var aiAgent = 0
        var byType: [ClipContentType: Int] = [:]
        var byApp: [String?: Int] = [:]  // nil key = unknown app
        var byGroup: [(name: String, icon: String, count: Int, preservesItems: Bool)] = []
    }

    func refreshSidebarCounts() {
        guard let db = openDB() else { return }
        var counts = SidebarCounts()
        let summary = db.queryIntRow(
            """
            SELECT COUNT(*),
                   COALESCE(SUM(CASE WHEN ZISPINNED = 1 THEN 1 ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN ZISSENSITIVE = 1 THEN 1 ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN ZAGENTSOURCE IS NOT NULL THEN 1 ELSE 0 END), 0)
            FROM ZCLIPITEM
            """,
            columnCount: 4
        )
        counts.all = summary[0]
        counts.pinned = summary[1]
        counts.sensitive = summary[2]
        counts.aiAgent = summary[3]
        let visibleTypes = Set(ClipContentType.visibleCases)
        for (rawType, count) in db.queryStringIntPairs(
            "SELECT ZCONTENTTYPERAW, COUNT(*) FROM ZCLIPITEM GROUP BY ZCONTENTTYPERAW"
        ) {
            guard count > 0,
                  let type = ClipContentType(rawValue: rawType),
                  visibleTypes.contains(type) else { continue }
            counts.byType[type] = count
        }
        // Mixed items contribute to every category whose corresponding representation is present.
        for (type, clause) in [
            (ClipContentType.image, "ZIMAGEDATA IS NOT NULL"),
            (ClipContentType.file,  "ZFILEPATHS IS NOT NULL AND ZFILEPATHS != ''"),
            (ClipContentType.text,  "ZCONTENT IS NOT NULL AND ZCONTENT != '' AND ZCONTENT != '[Mixed]'"),
        ] where visibleTypes.contains(type) {
            let extra = db.queryInt("SELECT COUNT(*) FROM ZCLIPITEM WHERE ZCONTENTTYPERAW = 'mixed' AND \(clause)")
            if extra > 0 {
                counts.byType[type, default: 0] += extra
            }
        }
        for (app, count) in db.queryStringIntPairs(
            "SELECT ZSOURCEAPP, COUNT(*) FROM ZCLIPITEM WHERE ZSOURCEAPP IS NOT NULL GROUP BY ZSOURCEAPP ORDER BY ZSOURCEAPP"
        ) {
            counts.byApp[app] = count
        }
        let nullCount = db.queryInt("SELECT COUNT(*) FROM ZCLIPITEM WHERE ZSOURCEAPP IS NULL")
        if nullCount > 0 { counts.byApp[nil] = nullCount }
        counts.byGroup = db.queryGroupRows(
            "SELECT ZNAME, COALESCE(ZICON, 'folder'), ZCOUNT, COALESCE(ZPRESERVESITEMS, 0) FROM ZSMARTGROUP ORDER BY ZSORTORDER"
        ).map { (name: $0.0, icon: $0.1, count: $0.2, preservesItems: $0.3) }
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

    /// Always returns a fresh SQLite connection. Opening is cheap (~hundreds of µs
    /// on local files) and eliminates an entire class of "cached connection doesn't
    /// see the latest SwiftData write" bugs (e.g. new group not appearing, multi-file
    /// paste not bumping to top, group reorder not reflected in quick panel).
    /// Callers don't need to remember to invalidate — every query sees fresh data.
    private func openDB() -> SQLiteConnection? {
        _db?.close()
        _db = nil
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

    /// Remove items from store, delete from context, rebuild group counts,
    /// save, and notify. This is the ONLY safe way to delete ClipItems —
    /// ensures store.items is updated before context.save() triggers SwiftUI
    /// re-render, and that SmartGroup.count badges stay accurate without each
    /// caller having to remember to recalculate.
    static func deleteAndNotify(_ itemsToDelete: [ClipItem], from context: ModelContext) {
        guard !itemsToDelete.isEmpty else { return }

        // Pause clipboard monitoring to prevent cleanExpiredItems from firing
        // during deletion (nested RunLoops can trigger the timer's Task)
        let wasPaused = ClipboardManager.shared.isPaused
        if !wasPaused { ClipboardManager.shared.pauseMonitoring() }

        // Remove only the deleted items from stores (avoids full-list flash).
        let idsToDelete = Set(itemsToDelete.map(\.persistentModelID))
        for case let store as ClipItemStore in activeStores.allObjects {
            store.items.removeAll { idsToDelete.contains($0.persistentModelID) }
        }
        let touchesGroups = itemsToDelete.contains { ($0.groupName ?? "").isEmpty == false }

        // Preserve any caller-set bulk-operation flag (e.g. settings clear data)
        // so we don't toggle it off while a larger transaction is still running.
        let wasBulk = isBulkOperation
        isBulkOperation = true
        for item in itemsToDelete {
            context.delete(item)
        }
        if touchesGroups {
            ClipboardManager.shared.recalculateAllGroupCounts(context: context)
        }
        isBulkOperation = wasBulk
        saveAndNotify(context)

        if !wasPaused { ClipboardManager.shared.resumeMonitoring() }
    }

    /// Async batched variant of `deleteAndNotify` for large deletions. Yields
    /// between batches so the UI stays responsive; callers typically show a
    /// progress sheet and forward the `(done, total)` callback to it.
    @MainActor
    static func deleteAndNotifyBatched(
        _ itemsToDelete: [ClipItem],
        from context: ModelContext,
        batchSize: Int = 200,
        progress: ((Int, Int) -> Void)? = nil
    ) async {
        guard !itemsToDelete.isEmpty else { return }

        let wasPaused = ClipboardManager.shared.isPaused
        if !wasPaused { ClipboardManager.shared.pauseMonitoring() }

        let idsToDelete = Set(itemsToDelete.map(\.persistentModelID))
        for case let store as ClipItemStore in activeStores.allObjects {
            store.items.removeAll { idsToDelete.contains($0.persistentModelID) }
        }
        let touchesGroups = itemsToDelete.contains { ($0.groupName ?? "").isEmpty == false }

        let wasBulk = isBulkOperation
        isBulkOperation = true

        let total = itemsToDelete.count
        var done = 0
        progress?(0, total)
        for batchStart in stride(from: 0, to: total, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, total)
            for idx in batchStart..<batchEnd {
                context.delete(itemsToDelete[idx])
            }
            try? context.save()
            done = batchEnd
            progress?(done, total)
            await Task.yield()
        }
        if touchesGroups {
            ClipboardManager.shared.recalculateAllGroupCounts(context: context)
        }
        isBulkOperation = wasBulk
        saveAndNotify(context)

        if !wasPaused { ClipboardManager.shared.resumeMonitoring() }
    }

    /// Save context then trigger immediate UI refresh across all store instances
    static func saveAndNotify(_ context: ModelContext) {
        try? context.save()
        NotificationCenter.default.post(name: itemDidUpdateNotification, object: nil)
    }

    /// Synchronously refresh every live store. Use after bulk writes (import,
    /// restore) where the caller needs the UI to reflect the new state *before*
    /// dismissing a progress sheet or showing a success alert — the regular
    /// `saveAndNotify` path dispatches the observer on `.receive(on: RunLoop.main)`
    /// which lands asynchronously and leaves a visible empty-state flash.
    static func refreshAllStoresNow() {
        for case let store as ClipItemStore in activeStores.allObjects {
            if store.isActive {
                store.performRefresh()
            } else {
                store.needsRefresh = true
            }
        }
    }

    static func saveAndNotifyContent(_ context: ModelContext) {
        try? context.save()
        NotificationCenter.default.post(name: itemContentDidUpdateNotification, object: nil)
    }

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
                guard let self, !self.isRefreshing else { return }
                guard self.isActive else {
                    self.needsRefresh = true
                    return
                }
                self.skipNextThrottledRefresh = true
                self.performRefresh()
            }

        lightweightObserver = NotificationCenter.default
            .publisher(for: Self.itemLastUsedDidUpdateNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isRefreshing else { return }
                guard self.isActive else {
                    self.needsRefresh = true
                    return
                }
                self.skipNextThrottledRefresh = true
                self.performLightweightRefresh()
            }

        contentObserver = NotificationCenter.default
            .publisher(for: Self.itemContentDidUpdateNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isRefreshing else { return }
                guard self.isActive else {
                    self.needsRefresh = true
                    return
                }
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

    func performRefresh() {
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
