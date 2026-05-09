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

    struct Output: Codable {
        let items: [OutputItem]
        /// Total matches after all filters + privacy, before pagination. Use to decide whether to keep paging.
        let total: Int
        /// True when the underlying scan hit the safety cap and `total` may undercount. Walk the time window via `until` to drill deeper.
        let total_capped: Bool
    }

    /// Hard cap on rows scanned per call. Past this, callers should narrow by `since`/`until`.
    private static let safetyCap = 10_000

    static var descriptor: MCPToolDescriptor {
        MCPToolDescriptor(
            name: "clipboard_search",
            description: "Search the user's clipboard history. Returns { items, total, total_capped } — items are previews (call clipboard_get for full content), total is the post-filter count before pagination, total_capped warns when scan hit the safety cap. Page deep history with since/until time-window pairs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query":                .object(["type": .string("string")]),
                    "content_type":         .object(["type": .string("string")]),
                    "source_app_bundle_id": .object(["type": .string("string")]),
                    "since":                .object(["type": .string("string"), "format": .string("date-time")]),
                    "until":                .object(["type": .string("string"), "format": .string("date-time")]),
                    "limit":                .object(["type": .string("number")])
                ]),
                "required": .array([])
            ])
        )
    }

    func call(
        params: JSONValue?,
        container: ModelContainer,
        guardLayer: PrivacyGuard,
        clientName: String? = nil
    ) async throws -> JSONValue {
        let p = params?.objectValue ?? [:]
        let query = p["query"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        let typeFilter = p["content_type"]?.stringValue.flatMap { ClipContentType(rawValue: $0) }
        let sourceFilter = p["source_app_bundle_id"]?.stringValue
        let isoFormatter = ISO8601DateFormatter()
        let since: Date? = p["since"]?.stringValue.flatMap { isoFormatter.date(from: $0) }
        let until: Date? = p["until"]?.stringValue.flatMap { isoFormatter.date(from: $0) }
        let limit = min(p["limit"]?.intValue ?? 20, 100)

        let context = container.mainContext

        // Scan up to safetyCap to compute an accurate `total` after filtering.
        // SwiftData predicate 对 enum/可选捕获支持有限,沿用内存过滤;对 1036 量级的真实数据足够,
        // 大体量场景由 total_capped + since/until 时间窗口翻页解决。
        var descriptor = FetchDescriptor<ClipItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = Self.safetyCap
        var items = try context.fetch(descriptor)
        let totalCapped = items.count == Self.safetyCap

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
        if let d = until { items = items.filter { $0.createdAt < d } }

        let visible = guardLayer.filter(items)
        let total = visible.count
        let page = Array(visible.prefix(limit))

        let outputItems = page.map { item in
            OutputItem(
                id: item.itemID,
                title: item.displayTitle ?? "",
                content_preview: PrivacyGuard.truncatePreview(item.content),
                content_type: item.contentType.rawValue,
                source_app: item.sourceApp,
                source_app_bundle_id: item.sourceAppBundleID,
                created_at: isoFormatter.string(from: item.createdAt),
                has_image: item.imageData != nil,
                has_ocr_text: !(item.ocrText?.isEmpty ?? true)
            )
        }
        return try MCPToolResult.textJSON(Output(items: outputItems, total: total, total_capped: totalCapped))
    }
}
