import Foundation
import SwiftData

@MainActor
struct SearchHistoryTool: MCPTool {
    struct OutputItem: Codable {
        let id: String
        let title: String
        let content_preview: String
        let content_type: String
        let source_app: String?
        let source_app_bundle_id: String?
        let created_at: String
        let has_image: Bool
        let has_ocr_text: Bool
    }

    static var descriptor: MCPToolDescriptor {
        MCPToolDescriptor(
            name: "clipboard_search",
            description: "Search the user's clipboard history. Returns previews — call clipboard_get for full content.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query":                .object(["type": .string("string")]),
                    "content_type":         .object(["type": .string("string")]),
                    "source_app_bundle_id": .object(["type": .string("string")]),
                    "since":                .object(["type": .string("string"), "format": .string("date-time")]),
                    "limit":                .object(["type": .string("number")])
                ]),
                "required": .array([])
            ])
        )
    }

    func call(
        params: JSONValue?,
        container: ModelContainer,
        guardLayer: PrivacyGuard
    ) async throws -> JSONValue {
        let p = params?.objectValue ?? [:]
        let query = p["query"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        let typeFilter = p["content_type"]?.stringValue.flatMap { ClipContentType(rawValue: $0) }
        let sourceFilter = p["source_app_bundle_id"]?.stringValue
        let since: Date? = {
            guard let s = p["since"]?.stringValue else { return nil }
            return ISO8601DateFormatter().date(from: s)
        }()
        let limit = min(p["limit"]?.intValue ?? 20, 100)

        let context = container.mainContext

        // 多取一点(留余量做内存过滤),最后再 prefix(limit)
        var descriptor = FetchDescriptor<ClipItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit * 4
        var items = try context.fetch(descriptor)

        // SwiftData predicate 受限,用内存过滤(数据量小,fetchLimit 已限制)
        if let q = query, !q.isEmpty {
            let lower = q.lowercased()
            items = items.filter { item in
                item.content.lowercased().contains(lower) ||
                (item.ocrText?.lowercased().contains(lower) ?? false) ||
                (item.linkTitle?.lowercased().contains(lower) ?? false) ||
                (item.displayTitle?.lowercased().contains(lower) ?? false)
            }
        }
        if let t = typeFilter { items = items.filter { $0.contentType == t } }
        if let s = sourceFilter { items = items.filter { $0.sourceAppBundleID == s } }
        if let d = since { items = items.filter { $0.createdAt >= d } }

        let filtered = Array(guardLayer.filter(items).prefix(limit))
        let formatter = ISO8601DateFormatter()
        let output = filtered.map { item in
            OutputItem(
                id: item.itemID,
                title: item.displayTitle ?? "",
                content_preview: PrivacyGuard.truncatePreview(item.content),
                content_type: item.contentType.rawValue,
                source_app: item.sourceApp,
                source_app_bundle_id: item.sourceAppBundleID,
                created_at: formatter.string(from: item.createdAt),
                has_image: item.imageData != nil,
                has_ocr_text: !(item.ocrText?.isEmpty ?? true)
            )
        }
        return try MCPToolResult.textJSON(output)
    }
}
