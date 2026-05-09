import Foundation
import SwiftData

@MainActor
struct GetItemTool: MCPTool {
    struct Output: Codable {
        let id: String
        let content: String
        let content_type: String
        let source_app: String?
        let source_app_bundle_id: String?
        let ocr_text: String?
        let link_title: String?
        let code_language: String?
        let file_paths: [String]?
        let image_data_base64: String?
        let created_at: String
        let last_used_at: String
    }

    static var descriptor: MCPToolDescriptor {
        MCPToolDescriptor(
            name: "clipboard_get",
            description: "Get full content of a specific clipboard item by ID returned from clipboard_search.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id":                 .object(["type": .string("string")]),
                    "include_image_data": .object(["type": .string("boolean")])
                ]),
                "required": .array([.string("id")])
            ])
        )
    }

    func call(
        params: JSONValue?,
        container: ModelContainer,
        guardLayer: PrivacyGuard
    ) async throws -> JSONValue {
        guard let id = params?.objectValue?["id"]?.stringValue else {
            throw MCPToolError.invalidParams("missing 'id'")
        }
        let includeImageData = params?.objectValue?["include_image_data"]?.boolValue ?? false

        let context = container.mainContext
        let allItems = try context.fetch(FetchDescriptor<ClipItem>())
        guard let item = allItems.first(where: { $0.itemID == id }) else {
            throw MCPToolError.toolError("Item not found: \(id)")
        }

        // 过滤:被 PrivacyGuard 拦截的 ID 视同 not found(不暴露存在性)
        guard guardLayer.filter([item]).first != nil else {
            throw MCPToolError.toolError("Item not found: \(id)")
        }

        let formatter = ISO8601DateFormatter()
        let imageBase64: String? = {
            guard includeImageData else { return nil }
            return item.imageBytesForExport()?.base64EncodedString()
        }()

        let output = Output(
            id: item.itemID,
            content: item.content,
            content_type: item.contentType.rawValue,
            source_app: item.sourceApp,
            source_app_bundle_id: item.sourceAppBundleID,
            ocr_text: item.ocrText,
            link_title: item.linkTitle,
            code_language: item.codeLanguage,
            file_paths: item.resolvedFilePaths.isEmpty ? nil : item.resolvedFilePaths,
            image_data_base64: imageBase64,
            created_at: formatter.string(from: item.createdAt),
            last_used_at: formatter.string(from: item.lastUsedAt)
        )
        return try MCPToolResult.textJSON(output)
    }
}

enum MCPToolError: Error {
    case invalidParams(String)
    case toolError(String)
}
