import Foundation
import AppKit
import SwiftData

@MainActor
struct SetClipboardTool: MCPTool {
    struct Output: Codable {
        let written: Bool
        let item_id: String?
    }

    static var descriptor: MCPToolDescriptor {
        MCPToolDescriptor(
            name: "clipboard_set",
            description: "Write text to the user's clipboard. The user will paste it themselves. Do not use this for sensitive data without confirmation.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "content":       .object(["type": .string("string")]),
                    "content_type":  .object(["type": .string("string"), "enum": .array([.string("text"), .string("code"), .string("link")])]),
                    "code_language": .object(["type": .string("string")])
                ]),
                "required": .array([.string("content")])
            ])
        )
    }

    func call(
        params: JSONValue?,
        container: ModelContainer,
        guardLayer: PrivacyGuard,
        clientName: String? = nil
    ) async throws -> JSONValue {
        guard let content = params?.objectValue?["content"]?.stringValue, !content.isEmpty else {
            throw MCPToolError.invalidParams("missing or empty 'content'")
        }
        let typeStr = params?.objectValue?["content_type"]?.stringValue ?? "text"
        let allowedTypes: Set<String> = ["text", "code", "link"]
        guard allowedTypes.contains(typeStr) else {
            throw MCPToolError.invalidParams("content_type must be one of \(allowedTypes)")
        }

        // 直接写 NSPasteboard.general(简单文本场景就够了;
        // 不走 ClipboardManager.writeToPasteboard 因为那个为现有 ClipItem 设计)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)

        // 把 MCP 客户端名(`initialize.params.clientInfo.name`)写到自定义 UTI 上,
        // ClipboardManager 的 monitor loop 抓到后会读这个 marker 并填到 ClipItem.agentSource。
        // setString 不会 bump changeCount,跟 PasteMemoMarker 一样不影响 baseline。
        if let name = clientName, !name.isEmpty {
            pasteboard.setString(name, forType: .agentSource)
        }

        // ClipboardManager 的 monitor loop 会自动捕获新剪贴板 → 形成新 ClipItem
        // 这里不直接 insert,避免与 monitor loop 双写冲突
        return try MCPToolResult.textJSON(Output(written: true, item_id: nil))
    }
}
