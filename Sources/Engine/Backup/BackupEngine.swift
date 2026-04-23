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
        destination: BackupDestination,
        progress: @MainActor @escaping (_ current: Int, _ total: Int, _ isFinalizing: Bool) -> Void = { _, _, _ in }
    ) async throws {
        let context = ModelContext(container)
        let clipItems = try context.fetch(FetchDescriptor<ClipItem>())
        let groups = (try? context.fetch(FetchDescriptor<SmartGroup>())) ?? []
        let rules = (try? context.fetch(FetchDescriptor<AutomationRule>())) ?? []

        let total = clipItems.count

        // Stream-encode each ExportItem and stream-compress to a temp file. Avoids
        // holding the full [ExportItem] array, encoded JSON Data, and zlib output
        // buffer in memory simultaneously — peak memory used to scale ~4× with
        // total clip bytes (issue #39).
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pastememo-backup-\(UUID().uuidString).zlib")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await DataPorter.encodeAndCompress(
            clipItems: clipItems,
            groups: groups,
            rules: rules,
            to: tempURL
        ) { current, _ in
            progress(current, total, false)
        }
        progress(total, total, true)

        // Read the compressed file once + prepend the 6-byte plaintext envelope.
        // upload(data:) still takes a Data; switching destinations to a streaming
        // upload would cut peak further but is out of scope for this fix.
        let compressedData = try Data(contentsOf: tempURL)
        let fileData = DataPorterCrypto.wrapPlaintext(compressedData)

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
            // Wipe clips and groups entirely; keep built-in rules (owned by BuiltInRules),
            // wipe user-defined ones.
            for item in (try? context.fetch(FetchDescriptor<ClipItem>())) ?? [] {
                context.delete(item)
            }
            for group in (try? context.fetch(FetchDescriptor<SmartGroup>())) ?? [] {
                context.delete(group)
            }
            let userRules = (try? context.fetch(
                FetchDescriptor<AutomationRule>(predicate: #Predicate { !$0.isBuiltIn })
            )) ?? []
            for rule in userRules {
                context.delete(rule)
            }
        }

        let result = try DataPorter.importItems(from: jsonData, into: context)
        return RestoreResult(restoredCount: result.imported, skippedCount: result.skipped)
    }
}
