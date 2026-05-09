import Foundation
import SwiftData

@MainActor
struct GetCurrentTool: MCPTool {
    struct Output: Codable {
        let id: String
        let content: String
        let content_type: String
        let source_app: String?
        let source_app_bundle_id: String?
        let created_at: String   // ISO8601
    }

    static var descriptor: MCPToolDescriptor {
        MCPToolDescriptor(
            name: "clipboard_get_current",
            description: "Get the user's current clipboard content. Use when user references 'what I just copied' or 'the thing on my clipboard'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ])
        )
    }

    func call(
        params: JSONValue?,
        container: ModelContainer,
        guardLayer: PrivacyGuard
    ) async throws -> JSONValue {
        let context = container.mainContext
        var descriptor = FetchDescriptor<ClipItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 50  // 多取一点保证过滤后还有
        let items = try context.fetch(descriptor)
        let filtered = guardLayer.filter(items)

        guard let item = filtered.first else {
            throw NSError(domain: "PasteMemoMCP", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No clipboard items available"])
        }

        let formatter = ISO8601DateFormatter()
        let output = Output(
            id: item.itemID,
            content: item.content,
            content_type: item.contentType.rawValue,
            source_app: item.sourceApp,
            source_app_bundle_id: item.sourceAppBundleID,
            created_at: formatter.string(from: item.createdAt)
        )
        return try MCPToolResult.textJSON(output)
    }
}
