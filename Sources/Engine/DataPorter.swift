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
    let review: String?
    let groupName: String?
    let ocrText: String?
    let ocrStatus: String?
    let ocrUpdatedAt: Date?
    let ocrErrorMessage: String?
    let ocrVersion: Int?
}

struct ExportGroup: Codable {
    let name: String
    let icon: String
    let sortOrder: Int
    let color: String?
    let preservesItems: Bool?
}

struct ExportRule: Codable {
    let ruleID: String
    let name: String
    let enabled: Bool
    let isBuiltIn: Bool
    let sortOrder: Int
    let triggerModeRaw: String
    let notifyBeforeApply: Bool
    let notifyOnTrigger: Bool
    let writeBackToPasteboard: Bool
    let conditionLogicRaw: String
    let conditionsDataBase64: String
    let actionsDataBase64: String
    let createdAt: Date
    let updatedAt: Date
}

struct ExportPayload: Codable {
    let version: Int
    let exportDate: Date
    let items: [ExportItem]
    /// v2+. Absent in v1 files.
    let groups: [ExportGroup]?
    /// v2+. Absent in v1 files.
    let rules: [ExportRule]?
}

struct ImportResult {
    let imported: Int
    let skipped: Int
    let importedGroups: Int
    let importedRules: Int

    init(imported: Int, skipped: Int, importedGroups: Int = 0, importedRules: Int = 0) {
        self.imported = imported
        self.skipped = skipped
        self.importedGroups = importedGroups
        self.importedRules = importedRules
    }
}

// MARK: - DataPorter

enum DataPorter {

    static let currentVersion = 2

    static func exportItems(_ clipItems: [ClipItem]) throws -> Data {
        let payload = buildExportPayload(clipItems)
        return try encodeAndCompress(payload)
    }

    /// Legacy — items only, used by old callers and v1-compat tests.
    static func buildExportPayload(_ clipItems: [ClipItem]) -> ExportPayload {
        buildExportPayload(clipItems, groups: [], rules: [])
    }

    /// Full payload: items + groups + automation rules. Always emits v2.
    static func buildExportPayload(
        _ clipItems: [ClipItem],
        groups: [SmartGroup],
        rules: [AutomationRule]
    ) -> ExportPayload {
        ExportPayload(
            version: currentVersion,
            exportDate: Date(),
            items: clipItems.map { buildExportItem(from: $0) },
            groups: groups.map { buildExportGroup(from: $0) },
            rules: rules.map { buildExportRule(from: $0) }
        )
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

    private static func decodePayload(_ data: Data) throws -> ExportPayload {
        let jsonData = decompressIfNeeded(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExportPayload.self, from: jsonData)
    }

    /// Batch import with progress callback. Runs in batches to keep UI responsive.
    @MainActor
    static func importItems(
        from data: Data,
        into context: ModelContext,
        progress: @escaping (Int, Int) -> Void
    ) async throws -> ImportResult {
        let payload = try decodePayload(data)

        let groupResult = importGroups(payload.groups ?? [], into: context)
        let ruleResult = importRules(payload.rules ?? [], into: context)

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

        recalculateGroupCounts(in: context)
        try context.save()

        return ImportResult(
            imported: imported,
            skipped: skipped,
            importedGroups: groupResult,
            importedRules: ruleResult
        )
    }

    /// Legacy sync import (for small datasets or backward compatibility)
    @MainActor
    static func importItems(from data: Data, into context: ModelContext) throws -> ImportResult {
        let payload = try decodePayload(data)

        let groupResult = importGroups(payload.groups ?? [], into: context)
        let ruleResult = importRules(payload.rules ?? [], into: context)

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
        recalculateGroupCounts(in: context)
        try context.save()
        return ImportResult(
            imported: imported,
            skipped: skipped,
            importedGroups: groupResult,
            importedRules: ruleResult
        )
    }

    // MARK: - Private

    static func buildSingleExportItem(_ clip: ClipItem) -> ExportItem { buildExportItem(from: clip) }
    static func buildSingleExportGroup(_ group: SmartGroup) -> ExportGroup { buildExportGroup(from: group) }
    static func buildSingleExportRule(_ rule: AutomationRule) -> ExportRule { buildExportRule(from: rule) }

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
            review: clip.review,
            groupName: clip.groupName,
            ocrText: clip.ocrText,
            ocrStatus: clip.ocrStatus,
            ocrUpdatedAt: clip.ocrUpdatedAt,
            ocrErrorMessage: clip.ocrErrorMessage,
            ocrVersion: clip.ocrVersion
        )
    }

    private static func buildExportGroup(from group: SmartGroup) -> ExportGroup {
        ExportGroup(
            name: group.name,
            icon: group.icon,
            sortOrder: group.sortOrder,
            color: group.color,
            preservesItems: group.preservesItems
        )
    }

    private static func buildExportRule(from rule: AutomationRule) -> ExportRule {
        ExportRule(
            ruleID: rule.ruleID,
            name: rule.name,
            enabled: rule.enabled,
            isBuiltIn: rule.isBuiltIn,
            sortOrder: rule.sortOrder,
            triggerModeRaw: rule.triggerModeRaw,
            notifyBeforeApply: rule.notifyBeforeApply,
            notifyOnTrigger: rule.notifyOnTrigger,
            writeBackToPasteboard: rule.writeBackToPasteboard,
            conditionLogicRaw: rule.conditionLogicRaw,
            conditionsDataBase64: rule.conditionsData.base64EncodedString(),
            actionsDataBase64: rule.actionsData.base64EncodedString(),
            createdAt: rule.createdAt,
            updatedAt: rule.updatedAt
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
            richTextType: exportItem.richTextType,
            review: exportItem.review
        )
        clip.sourceAppBundleID = exportItem.sourceAppBundleID
        clip.isSensitive = exportItem.isSensitive
        clip.linkTitle = exportItem.linkTitle
        clip.displayTitle = exportItem.displayTitle
        clip.faviconData = exportItem.faviconDataBase64.flatMap { Data(base64Encoded: $0) }
        clip.groupName = exportItem.groupName
        clip.ocrText = exportItem.ocrText
        clip.ocrStatus = exportItem.ocrStatus ?? clip.ocrStatus
        clip.ocrUpdatedAt = exportItem.ocrUpdatedAt
        clip.ocrErrorMessage = exportItem.ocrErrorMessage
        if let version = exportItem.ocrVersion {
            clip.ocrVersion = version
        }
        context.insert(clip)
    }

    /// Merge groups by name. Returns number of newly inserted groups.
    @discardableResult
    private static func importGroups(
        _ exportGroups: [ExportGroup],
        into context: ModelContext
    ) -> Int {
        guard !exportGroups.isEmpty else { return 0 }
        let existing = (try? context.fetch(FetchDescriptor<SmartGroup>())) ?? []
        let existingNames = Set(existing.map(\.name))

        var inserted = 0
        for exp in exportGroups where !existingNames.contains(exp.name) {
            let group = SmartGroup(
                name: exp.name,
                icon: exp.icon,
                sortOrder: exp.sortOrder,
                color: exp.color,
                preservesItems: exp.preservesItems ?? false
            )
            context.insert(group)
            inserted += 1
        }
        return inserted
    }

    /// Merge rules by ruleID; built-in rules are always skipped (owned by BuiltInRules).
    @discardableResult
    private static func importRules(
        _ exportRules: [ExportRule],
        into context: ModelContext
    ) -> Int {
        guard !exportRules.isEmpty else { return 0 }
        let existing = (try? context.fetch(FetchDescriptor<AutomationRule>())) ?? []
        let existingIDs = Set(existing.map(\.ruleID))

        var inserted = 0
        for exp in exportRules where !exp.isBuiltIn && !existingIDs.contains(exp.ruleID) {
            let rule = AutomationRule(name: exp.name)
            rule.ruleID = exp.ruleID
            rule.enabled = exp.enabled
            rule.isBuiltIn = false
            rule.sortOrder = exp.sortOrder
            rule.triggerModeRaw = exp.triggerModeRaw
            rule.notifyBeforeApply = exp.notifyBeforeApply
            rule.notifyOnTrigger = exp.notifyOnTrigger
            rule.writeBackToPasteboard = exp.writeBackToPasteboard
            rule.conditionLogicRaw = exp.conditionLogicRaw
            rule.conditionsData = Data(base64Encoded: exp.conditionsDataBase64) ?? Data()
            rule.actionsData = Data(base64Encoded: exp.actionsDataBase64) ?? Data()
            rule.createdAt = exp.createdAt
            rule.updatedAt = exp.updatedAt
            context.insert(rule)
            inserted += 1
        }
        return inserted
    }

    /// SmartGroup.count is persisted; rebuild it from actual items after bulk import
    /// so sidebar badges and quick-panel suggestions reflect restored data.
    private static func recalculateGroupCounts(in context: ModelContext) {
        guard let groups = try? context.fetch(FetchDescriptor<SmartGroup>()) else { return }
        for group in groups {
            let name = group.name
            let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.groupName == name })
            group.count = (try? context.fetchCount(descriptor)) ?? 0
        }
    }
}
