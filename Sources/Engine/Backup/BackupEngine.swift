import Foundation
import SwiftData

enum BackupEngine {

    private static var maxSlots: Int {
        let stored = UserDefaults.standard.integer(forKey: "backupMaxSlots")
        return stored > 0 ? min(stored, 10) : 3
    }

    @MainActor
    static func performBackup(
        container: ModelContainer,
        destination: BackupDestination
    ) async throws {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ClipItem>()
        let clipItems = try context.fetch(descriptor)

        let jsonData = try DataPorter.exportItems(clipItems)
        let fileData = DataPorterCrypto.wrapPlaintext(jsonData)

        let currentSlot = UserDefaults.standard.integer(forKey: "backupCurrentSlot")
        let nextSlot = (currentSlot % maxSlots) + 1

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let fileName = "PasteMemo-backup-\(nextSlot)-\(timestamp)-\(clipItems.count)items.pastememo"

        let slots = maxSlots
        let existingBackups = try await destination.list()

        // Delete the file occupying the next slot
        if let oldFile = existingBackups.first(where: { $0.slot == nextSlot }) {
            try await destination.delete(fileName: oldFile.fileName)
        }

        // Clean up files with slot numbers exceeding current maxSlots
        for stale in existingBackups where stale.slot > slots {
            try await destination.delete(fileName: stale.fileName)
        }

        try await destination.upload(data: fileData, fileName: fileName)

        UserDefaults.standard.set(nextSlot, forKey: "backupCurrentSlot")
        UserDefaults.standard.set(Date(), forKey: "backupLastDate")
    }

    static func listBackups(
        destination: BackupDestination
    ) async throws -> [BackupMetadata] {
        try await destination.list()
    }

    @MainActor
    static func restore(
        from backup: BackupMetadata,
        destination: BackupDestination,
        strategy: RestoreStrategy,
        container: ModelContainer
    ) async throws -> RestoreResult {
        let fileData = try await destination.download(fileName: backup.fileName)

        let jsonData: Data
        do {
            jsonData = try DataPorterCrypto.decrypt(fileData: fileData, password: "")
        } catch {
            throw BackupError.invalidBackupFile
        }

        let context = ModelContext(container)

        if strategy == .overwrite {
            let descriptor = FetchDescriptor<ClipItem>()
            let allItems = try context.fetch(descriptor)
            for item in allItems {
                context.delete(item)
            }
        }

        let result = try DataPorter.importItems(from: jsonData, into: context)
        return RestoreResult(restoredCount: result.imported, skippedCount: result.skipped)
    }
}
