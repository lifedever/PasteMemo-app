import Foundation
import SwiftData

@MainActor
struct ListRecentAppsTool: MCPTool {
    struct OutputItem: Codable {
        let source_app: String?
        let source_app_bundle_id: String
        let last_clip_at: String
        let count_24h: Int
    }

    static var descriptor: MCPToolDescriptor {
        MCPToolDescriptor(
            name: "clipboard_list_recent_apps",
            description: "List apps the user recently copied from. Use to narrow clipboard_search by source_app_bundle_id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object(["type": .string("number")])
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
        let limit = min(params?.objectValue?["limit"]?.intValue ?? 10, 30)
        let context = container.mainContext

        var descriptor = FetchDescriptor<ClipItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1000
        let items = try context.fetch(descriptor)
        let filtered = guardLayer.filter(items)

        let now = Date()
        let dayAgo = now.addingTimeInterval(-86400)

        var groups: [String: (app: String?, last: Date, count24h: Int)] = [:]
        for item in filtered {
            guard let bid = item.sourceAppBundleID else { continue }
            let cur = groups[bid]
            let last = max(cur?.last ?? .distantPast, item.createdAt)
            let inc = item.createdAt >= dayAgo ? 1 : 0
            groups[bid] = (item.sourceApp ?? cur?.app, last, (cur?.count24h ?? 0) + inc)
        }

        let formatter = ISO8601DateFormatter()
        let sorted = groups
            .sorted { $0.value.last > $1.value.last }
            .prefix(limit)
            .map { (bid, info) in
                OutputItem(
                    source_app: info.app,
                    source_app_bundle_id: bid,
                    last_clip_at: formatter.string(from: info.last),
                    count_24h: info.count24h
                )
            }
        return try MCPToolResult.textJSON(Array(sorted))
    }
}
