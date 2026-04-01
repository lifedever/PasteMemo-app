import Foundation
import SwiftData

// MARK: - Export Types

struct ExportItem: Codable {
    let content: String
    let contentType: String
    let sourceApp: String?
    let sourceAppBundleID: String?
    let isFavorite: Bool
    let isPinned: Bool
    let isSensitive: Bool
    let createdAt: Date
    let lastUsedAt: Date
    let linkTitle: String?
    let displayTitle: String?
    let codeLanguage: String?
    let imageDataBase64: String?
    let faviconDataBase64: String?
    let richTextDataBase64: String?
    let richTextType: String?
    let groupName: String?
}

struct ExportPayload: Codable {
    let version: Int
    let exportDate: Date
    let items: [ExportItem]
}

struct ImportResult {
    let imported: Int
    let skipped: Int
}

// MARK: - DataPorter

enum DataPorter {

    static func exportItems(_ clipItems: [ClipItem]) throws -> Data {
        let payload = buildExportPayload(clipItems)
        return try encodeAndCompress(payload)
    }

    /// Extract ClipItems into Sendable ExportItems on main thread
    static func buildExportPayload(_ clipItems: [ClipItem]) -> ExportPayload {
        let exportItems = clipItems.map { buildExportItem(from: $0) }
        return ExportPayload(version: 1, exportDate: Date(), items: exportItems)
    }

    /// Encode + compress (can run on background thread)
    nonisolated static func encodeAndCompress(_ payload: ExportPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(payload)
        return (try? (jsonData as NSData).compressed(using: .zlib) as Data) ?? jsonData
    }

    /// Decompress zlib data if needed, otherwise return as-is (backward compatible with uncompressed exports)
    private static func decompressIfNeeded(_ data: Data) -> Data {
        (try? (data as NSData).decompressed(using: .zlib) as Data) ?? data
    }

    /// Batch import with progress callback. Runs in batches to keep UI responsive.
    @MainActor
    static func importItems(
        from data: Data,
        into context: ModelContext,
        progress: @escaping (Int, Int) -> Void
    ) async throws -> ImportResult {
        let jsonData = decompressIfNeeded(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ExportPayload.self, from: jsonData)

        let total = payload.items.count
        var imported = 0
        var skipped = 0
        let batchSize = 100

        for batchStart in stride(from: 0, to: total, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, total)
            let batch = payload.items[batchStart..<batchEnd]

            for exportItem in batch {
                if isDuplicate(exportItem, in: context) {
                    skipped += 1
                } else {
                    insertClipItem(from: exportItem, into: context)
                    imported += 1
                }
            }

            try context.save()
            progress(batchStart + batch.count, total)

            // Yield to main thread between batches so UI stays responsive
            await Task.yield()
        }

        return ImportResult(imported: imported, skipped: skipped)
    }

    /// Legacy sync import (for small datasets or backward compatibility)
    @MainActor
    static func importItems(from data: Data, into context: ModelContext) throws -> ImportResult {
        let jsonData = decompressIfNeeded(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ExportPayload.self, from: jsonData)

        var imported = 0
        var skipped = 0

        for exportItem in payload.items {
            if isDuplicate(exportItem, in: context) {
                skipped += 1
            } else {
                insertClipItem(from: exportItem, into: context)
                imported += 1
            }
        }

        try context.save()
        return ImportResult(imported: imported, skipped: skipped)
    }

    // MARK: - Private

    static func buildSingleExportItem(_ clip: ClipItem) -> ExportItem { buildExportItem(from: clip) }

    private static func buildExportItem(from clip: ClipItem) -> ExportItem {
        ExportItem(
            content: clip.content,
            contentType: clip.contentType.rawValue,
            sourceApp: clip.sourceApp,
            sourceAppBundleID: clip.sourceAppBundleID,
            isFavorite: clip.isFavorite,
            isPinned: clip.isPinned,
            isSensitive: clip.isSensitive,
            createdAt: clip.createdAt,
            lastUsedAt: clip.lastUsedAt,
            linkTitle: clip.linkTitle,
            displayTitle: clip.displayTitle,
            codeLanguage: clip.codeLanguage,
            imageDataBase64: clip.imageData?.base64EncodedString(),
            faviconDataBase64: clip.faviconData?.base64EncodedString(),
            richTextDataBase64: clip.richTextData?.base64EncodedString(),
            richTextType: clip.richTextType,
            groupName: clip.groupName
        )
    }

    private static func isDuplicate(_ exportItem: ExportItem, in context: ModelContext) -> Bool {
        let content = exportItem.content
        let lowerBound = exportItem.createdAt.addingTimeInterval(-1)
        let upperBound = exportItem.createdAt.addingTimeInterval(1)

        let descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate<ClipItem> {
                $0.content == content
                    && $0.createdAt >= lowerBound
                    && $0.createdAt <= upperBound
            }
        )
        let count = (try? context.fetchCount(descriptor)) ?? 0
        return count > 0
    }

    @MainActor
    private static func insertClipItem(from exportItem: ExportItem, into context: ModelContext) {
        let contentType = ClipContentType(rawValue: exportItem.contentType) ?? .text
        let clip = ClipItem(
            content: exportItem.content,
            contentType: contentType,
            imageData: exportItem.imageDataBase64.flatMap { Data(base64Encoded: $0) },
            sourceApp: exportItem.sourceApp,
            isFavorite: exportItem.isFavorite,
            isPinned: exportItem.isPinned,
            createdAt: exportItem.createdAt,
            lastUsedAt: exportItem.lastUsedAt,
            codeLanguage: exportItem.codeLanguage,
            richTextData: exportItem.richTextDataBase64.flatMap { Data(base64Encoded: $0) },
            richTextType: exportItem.richTextType
        )
        clip.sourceAppBundleID = exportItem.sourceAppBundleID
        clip.isSensitive = exportItem.isSensitive
        clip.linkTitle = exportItem.linkTitle
        clip.displayTitle = exportItem.displayTitle
        clip.faviconData = exportItem.faviconDataBase64.flatMap { Data(base64Encoded: $0) }
        clip.groupName = exportItem.groupName
        context.insert(clip)
    }
}
