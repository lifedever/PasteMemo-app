import Foundation

// MARK: - Backup Types

struct BackupMetadata {
    let fileName: String
    let slot: Int
    let createdAt: Date
    let itemCount: Int
    let fileSize: Int64
}

enum BackupFrequency: String, CaseIterable {
    case twoHours = "2h"
    case sixHours = "6h"
    case daily = "1d"
    case threeDays = "3d"
    case weekly = "1w"
    case monthly = "1mo"

    var interval: TimeInterval {
        switch self {
        case .twoHours: return 2 * 3600
        case .sixHours: return 6 * 3600
        case .daily: return 24 * 3600
        case .threeDays: return 3 * 24 * 3600
        case .weekly: return 7 * 24 * 3600
        case .monthly: return 30 * 24 * 3600
        }
    }

    @MainActor
    var displayName: String {
        switch self {
        case .twoHours: return L10n.tr("backup.frequency.twoHours")
        case .sixHours: return L10n.tr("backup.frequency.sixHours")
        case .daily: return L10n.tr("backup.frequency.daily")
        case .threeDays: return L10n.tr("backup.frequency.threeDays")
        case .weekly: return L10n.tr("backup.frequency.weekly")
        case .monthly: return L10n.tr("backup.frequency.monthly")
        }
    }
}

enum BackupDestinationType: String, CaseIterable {
    case local
    case webdav

    @MainActor
    var displayName: String {
        switch self {
        case .local: return L10n.tr("backup.destination.local")
        case .webdav: return "WebDAV"
        }
    }
}

enum RestoreStrategy {
    case merge
    case overwrite
}

struct RestoreResult {
    let restoredCount: Int
    let skippedCount: Int
}

enum BackupError: LocalizedError {
    case iCloudNotAvailable
    case webdavConnectionFailed(String)
    case backupFailed(String)
    case restoreFailed(String)
    case noBackupsFound
    case invalidBackupFile

    var errorDescription: String? {
        switch self {
        case .iCloudNotAvailable: return "iCloud Drive is not available. Please sign in to iCloud."
        case .webdavConnectionFailed(let msg): return "WebDAV connection failed: \(msg)"
        case .backupFailed(let msg): return "Backup failed: \(msg)"
        case .restoreFailed(let msg): return "Restore failed: \(msg)"
        case .noBackupsFound: return "No backups found."
        case .invalidBackupFile: return "Invalid backup file."
        }
    }
}

// MARK: - File Name Parser

enum BackupFileNameParser {
    static func parse(_ name: String) -> (slot: Int, date: Date, itemCount: Int)? {
        // Match with optional item count: PasteMemo-backup-{slot}-{date}[-{count}items].pastememo
        let pattern = #"PasteMemo-backup-(\d+)-(\d{8}-\d{6})(?:-(\d+)items)?\.pastememo"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              match.numberOfRanges >= 3 else { return nil }

        guard let slotRange = Range(match.range(at: 1), in: name),
              let dateRange = Range(match.range(at: 2), in: name),
              let slot = Int(name[slotRange]) else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        guard let date = formatter.date(from: String(name[dateRange])) else { return nil }

        var itemCount = 0
        if match.numberOfRanges >= 4, let countRange = Range(match.range(at: 3), in: name) {
            itemCount = Int(name[countRange]) ?? 0
        }

        return (slot, date, itemCount)
    }
}

// MARK: - Protocol

protocol BackupDestination: Sendable {
    var displayName: String { get }
    var isAvailable: Bool { get async }

    func upload(data: Data, fileName: String) async throws
    func download(fileName: String) async throws -> Data
    func list() async throws -> [BackupMetadata]
    func delete(fileName: String) async throws
}
