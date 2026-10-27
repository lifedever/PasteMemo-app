import Foundation
import SwiftData

/// Permanent deletes from the storage pages and the retention setting. Unlike the main
/// window's delete (which keeps cached originals around for its undo toast), the space comes
/// back right away: cached originals go with their clips, and the database hands its freed
/// pages back to the file system.
@MainActor
enum StorageCleaner {
    nonisolated private static let FETCH_CHUNK = 500

    /// Deletes the clips with these IDs. Clips pinned or moved into a "永久保存" group since
    /// the IDs were collected are skipped. Returns how many were deleted.
    @discardableResult
    static func delete(
        itemIDs: [String], in context: ModelContext, progress: ((Int, Int) -> Void)? = nil
    ) async -> Int {
        var items: [ClipItem] = []
        for start in stride(from: 0, to: itemIDs.count, by: FETCH_CHUNK) {
            let chunk = Array(itemIDs[start..<min(start + FETCH_CHUNK, itemIDs.count)])
            let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { chunk.contains($0.itemID) })
            items += (try? context.fetch(descriptor)) ?? []
        }
        return await delete(items, in: context, progress: progress)
    }

    @discardableResult
    static func delete(
        _ candidates: [ClipItem], in context: ModelContext, progress: ((Int, Int) -> Void)? = nil
    ) async -> Int {
        let preserved = SmartGroupRetention.preservedGroupNames(in: context)
        let items = candidates.filter {
            !$0.isDeleted && !$0.isPinned
                && !SmartGroupRetention.shouldPreserve(item: $0, preservedGroupNames: preserved)
        }
        guard !items.isEmpty else { return 0 }
        let originals = items.compactMap { item in item.originalImageFilePath.map { (item.itemID, $0) } }
        let started = Date()

        await ClipItemStore.deleteAndNotifyBatched(items, from: context, progress: progress)
        let deleted = Date()

        // Only reclaim the files of clips that are really gone from disk. A failed save leaves
        // the rows in the store (and its original must stay with it) — asking the context would
        // not tell: a fetch skips objects marked deleted even while the save never landed.
        let ids = originals.map(\.0)
        let stillStored = await Task.detached(priority: .utility) { storedIDs(ids) }.value
        if let stillStored {
            deleteCachedOriginals(originals.filter { !stillStored.contains($0.0) }.map(\.1))
        }
        let originalsDone = Date()
        await reclaimFreePages()
        // Where a long delete spends its time, for tuning without guessing.
        func ms(_ from: Date, _ to: Date) -> Int { Int(to.timeIntervalSince(from) * 1000) }
        DiagnosticLog.log("STORAGE delete n=\(items.count) rows=\(ms(started, deleted))ms originals=\(ms(deleted, originalsDone))ms vacuum=\(ms(originalsDone, Date()))ms")
        return items.count
    }

    nonisolated private static var storePath: String {
        StorageScanner.Locations.dataDirectory.appendingPathComponent("PasteMemo.store").path
    }

    /// Which of `ids` still have a row on disk; nil when the store can't be read (then no
    /// original is touched).
    nonisolated private static func storedIDs(_ ids: [String]) -> Set<String>? {
        guard !ids.isEmpty else { return [] }
        guard let db = SQLiteConnection(path: storePath, readOnly: true) else { return nil }
        defer { db.close() }
        db.setBusyTimeout(milliseconds: 2000)
        var stored = Set<String>()
        for start in stride(from: 0, to: ids.count, by: FETCH_CHUNK) {
            let chunk = Array(ids[start..<min(start + FETCH_CHUNK, ids.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let ok = db.forEachRow("SELECT ZITEMID FROM ZCLIPITEM WHERE ZITEMID IN (\(placeholders))", params: chunk) {
                if let id = $0.text(0) { stored.insert(id) }
            }
            guard ok else { return nil }
        }
        return stored
    }

    /// Never touches anything outside the Originals cache, whatever a row claims its path is.
    static func deleteCachedOriginals(_ paths: [String]) {
        guard let directory = ClipboardManager.originalsCacheDirectory()?.standardizedFileURL.path else { return }
        for path in paths where isInside(path, directory: directory) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    nonisolated static func isInside(_ path: String, directory: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        return standardized.deletingLastPathComponent().path == directory
    }

    /// Hands the space a bulk delete frees back to the file system. Off the main thread, with a
    /// busy timeout so SwiftData's own writes simply wait their turn.
    static func reclaimFreePages() async {
        let path = storePath
        await Task.detached(priority: .utility) { compactStore(at: path) }.value
    }

    nonisolated static func compactStore(at path: String) {
        guard let db = SQLiteConnection(path: path) else { return }
        defer { db.close() }
        db.setBusyTimeout(milliseconds: 5000)
        // FTS5 keeps a deleted row's index data — it only appends a delete marker — until its
        // segments merge: a store emptied down to 4 clips still carried an 18.7 MB search index
        // (2026-10-27). 'optimize' merges everything and drops what was deleted.
        if db.tableExists("clip_fts") {
            db.execute("INSERT INTO clip_fts(clip_fts) VALUES('optimize')")
        }
        // `auto_vacuum = incremental`: freed pages only leave the file on incremental_vacuum.
        db.execute("PRAGMA incremental_vacuum")
        // The -wal file keeps its size after a checkpoint unless truncated (6 MB of it, there).
        // Busy while SwiftData reads: then it's simply left for next time.
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
}
