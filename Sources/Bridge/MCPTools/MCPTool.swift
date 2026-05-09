import Foundation
import SwiftData

/// 所有 MCP 工具的统一接口。
/// 实现必须 MainActor（要访问 ModelContainer）。
@MainActor
protocol MCPTool {
    static var descriptor: MCPToolDescriptor { get }

    /// 执行工具。container 是 PasteMemo 的 ModelContainer，guard 是过滤层。
    /// `clientName` 是 `initialize` 阶段对端汇报的 `clientInfo.name`(如 "claude-code"、"cursor"、
    /// "codex"),用于把 MCP 写入的剪贴板项标记成"AI Agent 来源"。绝大多数工具用不上,
    /// 默认实现忽略这个参数。
    /// 返回值是 MCP `tools/call` 的 result.content（按 MCP 2024-11-05 规范是
    /// `[{ type: "text", text: "..." }]` 形态）。
    func call(
        params: JSONValue?,
        container: ModelContainer,
        guardLayer: PrivacyGuard,
        clientName: String?
    ) async throws -> JSONValue
}

/// MCP `tools/call` 响应的 content 字段标准包装：返回单段文本（JSON 字符串化）
enum MCPToolResult {
    /// 把任意 Encodable 包装成 [{ type: "text", text: <encoded> }]
    static func textJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let str = String(data: data, encoding: .utf8) ?? "{}"
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(str)
                ])
            ])
        ])
    }
}
