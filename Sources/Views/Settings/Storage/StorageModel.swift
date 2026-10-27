import SwiftUI
import SwiftData

/// State shared by the storage pages (data page → manage → one source or type): the latest scan,
/// the filters, and whatever long job (delete, TIFF conversion) is running. Lives as long as
/// the settings window, so filters survive going back and forth between the pages.
@MainActor
final class StorageModel: ObservableObject {
    struct Job: Equatable {
        let title: String
        var done = 0
        var total = 0
    }

    @Published private(set) var snapshot: StorageSnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var scanFailed = false
    @Published var filter = StorageFilter() { didSet { recompute() } }
    /// Switching starts a fresh selection: a source and a type are different things to tick.
    @Published var grouping: StorageGrouping = .source {
        didSet {
            guard grouping != oldValue else { return }
            selectedGroups.removeAll()
            recompute()
        }
    }
    @Published var groupSort: StorageGroupSort = .bytes { didSet { recompute() } }
    /// Filters sources by name; not used when listing by type.
    @Published var sourceSearch = "" { didSet { recompute() } }
    @Published var selectedGroups: Set<StorageGroupKey> = []
    @Published private(set) var rows: [StorageGroupSummary] = []
    /// Bumped whenever `deletable` changes, so pages can cache what they derive from it.
    @Published private(set) var revision = 0
    /// Clips a running delete is removing. Pages must stop showing them *before* the first
    /// batch is saved: a saved-deleted SwiftData object reads `isDeleted == false` again, and a
    /// row touching its external-storage attributes (rich text, image) makes Core Data fetch a
    /// file that is gone — an uncatchable exception (crash on 2026-10-27, deleting every text clip).
    @Published private(set) var deletingIDs: Set<String> = []
    @Published private(set) var job: Job?

    /// Deletable records under the current filter; every page reads from this.
    private(set) var deletable: [StorageRecord] = []
    /// Every record the storage pages can delete, ignoring the filters: the data page's figures.
    private(set) var cleanable: [StorageRecord] = []
    /// Pinned / permanent-group clips, left out of every figure here.
    private(set) var protectedCount = 0
    private var scannedAt = Date()
    private var scanGeneration = 0

    var isBusy: Bool { job != nil }

    /// TIFF originals the optimize row offers: ones already found not to convert losslessly
    /// this launch are left out.
    var convertibleTIFFs: [StorageSnapshot.TIFFOriginal] {
        let skip = OriginalImageOptimizer.shared.unconvertiblePaths
        return (snapshot?.tiffOriginals ?? []).filter { !skip.contains($0.path) }
    }

    func refresh() async {
        guard let locations = StorageScanner.Locations.live() else {
            scanFailed = true
            return
        }
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        let result = await Task.detached(priority: .userInitiated) { StorageScanner.scan(locations) }.value
        // A newer scan started while this one ran (a delete finished, say): its result wins.
        guard generation == scanGeneration else { return }
        isScanning = false
        scanFailed = result == nil
        scannedAt = Date()
        snapshot = result
        recompute()
    }

    private func recompute() {
        guard let snapshot else {
            deletable = []
            cleanable = []
            protectedCount = 0
            rows = []
            revision += 1
            return
        }
        cleanable = snapshot.records.filter { !$0.isProtected && !deletingIDs.contains($0.id) }
        protectedCount = snapshot.records.count - snapshot.records.filter { !$0.isProtected }.count
        // Listing by type, the type menu would only hide rows; it applies to sources only.
        var applied = filter
        if grouping == .type { applied.categories = [] }
        deletable = StorageQuery.deletable(snapshot.records, filter: applied, now: scannedAt)
        if !deletingIDs.isEmpty { deletable.removeAll { deletingIDs.contains($0.id) } }
        var groups = StorageQuery.groups(deletable, by: grouping, sort: groupSort)
        let query = sourceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if grouping == .source, !query.isEmpty {
            groups = groups.filter { displayName(for: $0.key).localizedCaseInsensitiveContains(query) }
        }
        rows = groups
        revision += 1
    }

    /// Entering from the data page, whose numbers are always all-time and all types: start the
    /// manage / type pages unfiltered, so the first numbers seen match the ones just clicked.
    /// Between the manage and detail pages the filters stay as set.
    func resetFilters() {
        filter = StorageFilter()
        sourceSearch = ""
    }

    // MARK: - Lookups

    func displayName(_ sourceName: String?) -> String {
        sourceName ?? L10n.tr("filter.other")
    }

    func displayName(for key: StorageGroupKey) -> String {
        switch key {
        case .source(let name): return displayName(name.isEmpty ? nil : name)
        case .category(let category): return category.label
        }
    }

    func icon(forSource sourceName: String?) -> NSImage? {
        guard let sourceName else { return nil }
        return appIcon(forBundleID: snapshot?.bundleIDs[sourceName], name: sourceName)
    }

    func records(in key: StorageGroupKey) -> [StorageRecord] {
        deletable.filter(key.contains)
    }

    /// Selected rows that are on screen: a source hidden by the search or emptied by the
    /// filter is neither counted nor deleted.
    var visibleSelection: [StorageGroupSummary] {
        rows.filter { selectedGroups.contains($0.key) }
    }

    var selectedItemIDs: [String] {
        let keys = visibleSelection.map(\.key)
        return deletable.filter { record in keys.contains { $0.contains(record) } }.map(\.id)
    }

    // MARK: - Jobs

    @discardableResult
    func delete(itemIDs: [String], in context: ModelContext) async -> Int {
        guard !itemIDs.isEmpty, job == nil else { return 0 }
        // Synchronously, before anything awaits: the next redraw already lacks these rows.
        deletingIDs = Set(itemIDs)
        recompute()
        job = Job(title: L10n.tr("storage.deleting"), total: itemIDs.count)
        let started = Date()
        let deleted = await StorageCleaner.delete(itemIDs: itemIDs, in: context) { [weak self] done, total in
            self?.job?.done = done
            self?.job?.total = total
        }
        let cleaned = Date()
        job = nil
        await refresh()
        deletingIDs = []
        DiagnosticLog.log("STORAGE delete job n=\(deleted) total=\(Int(cleaned.timeIntervalSince(started) * 1000))ms rescan=\(Int(Date().timeIntervalSince(cleaned) * 1000))ms")
        return deleted
    }

    /// Runs in the background (the optimize row shows the progress): unlike a delete, nothing
    /// here needs the window held still. Asks the store itself, so it works before the page's
    /// first scan has finished.
    func convertTIFFs() async {
        guard OriginalImageOptimizer.isEnabled,
              await OriginalImageOptimizer.shared.convertExisting() != nil else { return }
        await refresh()
    }
}
