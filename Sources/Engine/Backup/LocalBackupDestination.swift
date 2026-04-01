import Foundation

struct LocalBackupDestination: BackupDestination {

    var displayName: String { "Local" }

    var isAvailable: Bool {
        get async { true }
    }

    func upload(data: Data, fileName: String) async throws {
        let dir = Self.accessBackupDirectory()
        try ensureDirectoryExists(dir)
        let fileURL = dir.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
    }

    func download(fileName: String) async throws -> Data {
        let dir = Self.accessBackupDirectory()
        let fileURL = dir.appendingPathComponent(fileName)
        return try Data(contentsOf: fileURL)
    }

    func list() async throws -> [BackupMetadata] {
        let dir = Self.accessBackupDirectory()
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        let contents = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        )

        return contents
            .filter { $0.pathExtension == "pastememo" }
            .compactMap { parseMetadata(from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func delete(fileName: String) async throws {
        let dir = Self.accessBackupDirectory()
        let fileURL = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Synchronous list for UI — avoids async timing issues.
    func listSync() -> [BackupMetadata] {
        let dir = Self.accessBackupDirectory()
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "pastememo" }
            .compactMap { parseMetadata(from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Directory Management

    /// Display path (no side effects).
    static var backupDirectory: URL {
        if let bookmarked = resolveBookmark() {
            return bookmarked
        }
        if let saved = UserDefaults.standard.string(forKey: "backupLocalPath"), !saved.isEmpty {
            return URL(fileURLWithPath: saved)
        }
        return defaultDirectory
    }

    /// Access path with security scope activated. Use for all file I/O.
    static func accessBackupDirectory() -> URL {
        if let bookmarked = resolveBookmark() {
            _ = bookmarked.startAccessingSecurityScopedResource()
            return bookmarked
        }
        // Fallback: saved path string (works for dirs the app already has access to)
        if let saved = UserDefaults.standard.string(forKey: "backupLocalPath"), !saved.isEmpty {
            return URL(fileURLWithPath: saved)
        }
        return defaultDirectory
    }

    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo"
        return appSupport.appendingPathComponent(bundleID).appendingPathComponent("backups")
    }

    static func setBackupDirectory(_ url: URL) {
        saveBookmark(for: url)
        UserDefaults.standard.set(url.path, forKey: "backupLocalPath")
    }

    static var hasCustomDirectory: Bool {
        UserDefaults.standard.data(forKey: BOOKMARK_KEY) != nil
    }

    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: BOOKMARK_KEY)
    }

    // MARK: - Security-Scoped Bookmark

    private static let BOOKMARK_KEY = "backupDirectoryBookmark"

    private static func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: BOOKMARK_KEY)
    }

    private static func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: BOOKMARK_KEY) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale { saveBookmark(for: url) }
        return url
    }

    // MARK: - Private

    private func ensureDirectoryExists(_ dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func parseMetadata(from url: URL) -> BackupMetadata? {
        let fileName = url.lastPathComponent
        guard let parsed = BackupFileNameParser.parse(fileName) else { return nil }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        return BackupMetadata(
            fileName: fileName,
            slot: parsed.slot,
            createdAt: parsed.date,
            itemCount: parsed.itemCount,
            fileSize: Int64(fileSize)
        )
    }
}
