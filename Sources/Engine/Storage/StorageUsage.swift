import Foundation

/// What the storage pages filter by. Content types fold into a handful of buckets so the
/// type menu stays short; the main window keeps the fine-grained types.
enum StorageCategory: String, CaseIterable, Sendable, Hashable {
    case image, video, file, text, link, code, other

    init(contentTypeRaw: String) {
        switch ClipContentType(rawValue: contentTypeRaw) {
        case .image: self = .image
        case .video: self = .video
        case .file, .document, .archive, .application, .audio: self = .file
        case .text: self = .text
        case .link: self = .link
        case .code: self = .code
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .file: return "doc"
        case .text: return "text.alignleft"
        case .link: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "ellipsis.circle"
        }
    }

    /// The `ClipItem.contentTypeRaw` values this bucket covers; `.other` is everything else.
    var contentTypes: [String] {
        switch self {
        case .image: return [ClipContentType.image.rawValue]
        case .video: return [ClipContentType.video.rawValue]
        case .file: return [ClipContentType.file, .document, .archive, .application, .audio].map(\.rawValue)
        case .text: return [ClipContentType.text.rawValue]
        case .link: return [ClipContentType.link.rawValue]
        case .code: return [ClipContentType.code.rawValue]
        case .other: return []
        }
    }

    @MainActor
    var label: String {
        switch self {
        case .image: return L10n.tr("type.image")
        case .video: return L10n.tr("type.video")
        case .file: return L10n.tr("type.file")
        case .text: return L10n.tr("type.text")
        case .link: return L10n.tr("type.link")
        case .code: return L10n.tr("type.code")
        case .other: return L10n.tr("type.other")
        }
    }
}

/// One clip as the storage pages see it: who copied it, when, and how many bytes PasteMemo
/// keeps for it. Bytes count only what PasteMemo itself stores — a Finder copy references the
/// user's file, which is neither counted nor ever deleted here.
struct StorageRecord: Sendable, Identifiable, Equatable {
    let id: String
    /// nil = no recorded source app (old clips, AI Agent writes).
    let sourceName: String?
    let category: StorageCategory
    let createdAt: Date
    /// Pinned, or in a "永久保存" group: shown in totals, never deleted from the storage pages.
    let isProtected: Bool
    let originalBytes: Int64
    let previewBytes: Int64
    let richTextBytes: Int64
    let textBytes: Int64
    let originalPath: String?
    /// Masked in the main list; the storage grid doesn't show its picture either.
    var isSensitive = false

    var bytes: Int64 { originalBytes + previewBytes + richTextBytes + textBytes }
}

/// Where the bytes on disk go, for the overview bar.
struct StorageBreakdown: Sendable, Equatable {
    var originals: Int64 = 0
    /// Thumbnails, link favicons.
    var previews: Int64 = 0
    /// Rich text + pasteboard snapshots.
    var richText: Int64 = 0
    /// Plain text plus everything else in the database file (search index, indexes).
    var textAndIndex: Int64 = 0
    var backups: Int64 = 0

    var total: Int64 { originals + previews + richText + textAndIndex + backups }
}

struct StorageSnapshot: Sendable {
    let records: [StorageRecord]
    /// Latest bundle ID seen per source name, for the app icon.
    let bundleIDs: [String: String]
    let breakdown: StorageBreakdown
    /// Cached originals still stored as TIFF — the lossless PNG conversion candidates.
    let tiffOriginals: [TIFFOriginal]

    struct TIFFOriginal: Sendable, Equatable {
        let itemID: String
        let path: String
        let bytes: Int64
    }
}

enum StorageScanner {
    struct Locations: Sendable {
        let store: URL
        let originals: URL
        let backups: URL?

        /// Core Data keeps `@Attribute(.externalStorage)` blobs beside the store in
        /// `.<store name>_SUPPORT/_EXTERNAL_DATA`.
        var externalData: URL {
            store.deletingLastPathComponent()
                .appendingPathComponent(".\(store.deletingPathExtension().lastPathComponent)_SUPPORT")
                .appendingPathComponent("_EXTERNAL_DATA")
        }

        /// This build's store, without touching anything else (no folders created).
        static var liveStore: URL { dataDirectory.appendingPathComponent("PasteMemo.store") }

        /// This build's data directory — Dev and Release each have their own.
        static var dataDirectory: URL {
            URL.applicationSupportDirectory
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo", isDirectory: true)
        }

        static func live() -> Locations? {
            guard let originals = ClipboardManager.originalsCacheDirectory() else { return nil }
            // Local backup files take disk space even after switching to WebDAV, so the local
            // folder is always counted.
            return Locations(
                store: dataDirectory.appendingPathComponent("PasteMemo.store"),
                originals: originals,
                backups: LocalBackupDestination.backupDirectory
            )
        }
    }

    /// Reads the store through its own read-only connection; safe off the main thread while
    /// SwiftData keeps writing (WAL). Returns nil when the store can't be opened.
    static func scan(_ locations: Locations) -> StorageSnapshot? {
        guard let db = SQLiteConnection(path: locations.store.path, readOnly: true) else { return nil }
        defer { db.close() }
        db.setBusyTimeout(milliseconds: 2000)

        let externalSizes = fileSizes(in: locations.externalData)
        let preserved = Set(db.queryStrings("SELECT ZNAME FROM ZSMARTGROUP WHERE ZPRESERVESITEMS = 1"))

        var records: [StorageRecord] = []
        var bundleIDs: [String: (id: String, at: Double)] = [:]
        var tiffs: [StorageSnapshot.TIFFOriginal] = []
        var breakdown = StorageBreakdown()
        var originalSizes: [String: Int64] = [:]

        // Blob columns hold Core Data's own framing: 0x01 + bytes inline, or 0x02 + the
        // external file's UUID. Only the marker and the UUID are pulled out — never the bytes.
        func blobColumns(_ column: String) -> String {
            "substr(\(column), 1, 1), length(\(column)), CAST(substr(\(column), 2, 36) AS TEXT)"
        }
        let sql = """
            SELECT ZITEMID, ZSOURCEAPP, ZSOURCEAPPBUNDLEID, ZCONTENTTYPERAW, ZCREATEDAT, ZISPINNED, ZGROUPNAME,
                   ZORIGINALIMAGEFILEPATH,
                   ifnull(length(CAST(ZCONTENT AS BLOB)), 0) + ifnull(length(CAST(ZOCRTEXT AS BLOB)), 0)
                       + ifnull(length(CAST(ZSMSMESSAGETEXT AS BLOB)), 0),
                   \(blobColumns("ZIMAGEDATA")), \(blobColumns("ZFAVICONDATA")),
                   \(blobColumns("ZRICHTEXTDATA")), \(blobColumns("ZPASTEBOARDSNAPSHOT")),
                   ZISSENSITIVE
            FROM ZCLIPITEM
            """
        // Core Data keeps one external file for identical blobs and lets every such row point
        // at it (copies of one screenshot, say). Counting the file once per row double-counted
        // hundreds of MB, so rows are sized after the pass: each takes its share of a shared file.
        struct Pending {
            var record: StorageRecord
            var externalPreviews: [String] = []
            var externalRichText: [String] = []
        }
        var pending: [Pending] = []
        var references: [String: Int] = [:]
        var inlinePreviews: Int64 = 0
        var inlineRichText: Int64 = 0

        let ok = db.forEachRow(sql) { row in
            /// Inline bytes, or the external file it points at.
            func blob(_ first: Int32) -> (inline: Int64, external: String?) {
                let length = row.int(first + 1)
                guard length > 0 else { return (0, nil) }
                switch row.text(first) {
                case "\u{01}": return (length - 1, nil)
                case "\u{02}": return (0, row.text(first + 2))
                default: return (length, nil)
                }
            }
            let itemID = row.text(0) ?? ""
            let name = row.text(1).flatMap { $0.isEmpty ? nil : $0 }
            let created = row.double(4)
            if let name, let bundleID = row.text(2), !bundleID.isEmpty,
               created >= (bundleIDs[name]?.at ?? -.infinity) {
                bundleIDs[name] = (bundleID, created)
            }
            let groupName = row.text(6)
            let originalPath = row.text(7)
            var originalBytes: Int64 = 0
            if let originalPath {
                originalBytes = originalSizes[originalPath] ?? fileSize(atPath: originalPath)
                originalSizes[originalPath] = originalBytes
                if originalBytes > 0, originalPath.lowercased().hasSuffix(".tiff") {
                    tiffs.append(.init(itemID: itemID, path: originalPath, bytes: originalBytes))
                }
            }
            let previewParts = [blob(9), blob(12)]
            let richParts = [blob(15), blob(18)]
            let previews = previewParts.map(\.inline).reduce(0, +)
            let rich = richParts.map(\.inline).reduce(0, +)
            inlinePreviews += previews
            inlineRichText += rich
            let entry = Pending(
                record: StorageRecord(
                    id: itemID,
                    sourceName: name,
                    category: StorageCategory(contentTypeRaw: row.text(3) ?? ""),
                    createdAt: Date(timeIntervalSinceReferenceDate: created),
                    isProtected: row.int(5) != 0 || groupName.map(preserved.contains) == true,
                    originalBytes: originalBytes,
                    previewBytes: previews,
                    richTextBytes: rich,
                    textBytes: row.int(8),
                    originalPath: originalPath,
                    isSensitive: row.int(21) != 0
                ),
                externalPreviews: previewParts.compactMap(\.external),
                externalRichText: richParts.compactMap(\.external)
            )
            for file in entry.externalPreviews + entry.externalRichText { references[file, default: 0] += 1 }
            pending.append(entry)
        }
        guard ok else { return nil }

        func share(_ file: String) -> Int64 {
            guard let size = externalSizes[file], let count = references[file], count > 0 else { return 0 }
            return size / Int64(count)
        }
        var previewFiles = Set<String>()
        var richTextFiles = Set<String>()
        for entry in pending {
            var record = entry.record
            record = StorageRecord(
                id: record.id, sourceName: record.sourceName, category: record.category,
                createdAt: record.createdAt, isProtected: record.isProtected,
                originalBytes: record.originalBytes,
                previewBytes: record.previewBytes + entry.externalPreviews.map(share).reduce(0, +),
                richTextBytes: record.richTextBytes + entry.externalRichText.map(share).reduce(0, +),
                textBytes: record.textBytes, originalPath: record.originalPath, isSensitive: record.isSensitive
            )
            previewFiles.formUnion(entry.externalPreviews)
            richTextFiles.formUnion(entry.externalRichText)
            records.append(record)
        }
        breakdown.previews = inlinePreviews + previewFiles.compactMap { externalSizes[$0] }.reduce(0, +)
        breakdown.richText = inlineRichText + richTextFiles.subtracting(previewFiles).compactMap { externalSizes[$0] }.reduce(0, +)

        breakdown.originals = fileSizes(in: locations.originals).values.reduce(0, +)
        let storeFiles = ["", "-wal", "-shm"].reduce(Int64(0)) {
            $0 + fileSize(atPath: locations.store.path + $1)
        }
        let databaseBytes = storeFiles + externalSizes.values.reduce(0, +)
        breakdown.textAndIndex = max(0, databaseBytes - breakdown.previews - breakdown.richText)
        if let backups = locations.backups {
            breakdown.backups = fileSizes(in: backups)
                .filter { $0.key.hasPrefix("PasteMemo-backup-") && $0.key.hasSuffix(".pastememo") }
                .values.reduce(0, +)
        }
        return StorageSnapshot(
            records: records,
            bundleIDs: bundleIDs.mapValues(\.id),
            breakdown: breakdown,
            tiffOriginals: tiffs
        )
    }

    /// Just the TIFF originals, without the full scan — what the launch-time conversion needs.
    /// Rides the partial index on ZORIGINALIMAGEFILEPATH.
    static func tiffOriginals(in locations: Locations) -> [StorageSnapshot.TIFFOriginal] {
        guard let db = SQLiteConnection(path: locations.store.path, readOnly: true) else { return [] }
        defer { db.close() }
        db.setBusyTimeout(milliseconds: 2000)
        var result: [StorageSnapshot.TIFFOriginal] = []
        db.forEachRow("""
            SELECT ZITEMID, ZORIGINALIMAGEFILEPATH FROM ZCLIPITEM
            WHERE ZORIGINALIMAGEFILEPATH IS NOT NULL AND lower(ZORIGINALIMAGEFILEPATH) LIKE '%.tiff'
            """) { row in
            guard let itemID = row.text(0), let path = row.text(1) else { return }
            let bytes = fileSize(atPath: path)
            if bytes > 0 { result.append(.init(itemID: itemID, path: path, bytes: bytes)) }
        }
        return result
    }

    /// File name → size for the regular files directly inside `directory`.
    static func fileSizes(in directory: URL) -> [String: Int64] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: []
        ) else { return [:] }
        var sizes: [String: Int64] = [:]
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            sizes[url.lastPathComponent] = Int64(values.fileSize ?? 0)
        }
        return sizes
    }

    static func fileSize(atPath path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// File-style byte counts (decimal, like Finder), shared by every storage page.
enum StorageFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
