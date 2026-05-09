import Foundation
import SwiftData

/// 单个 MCP TCP/Unix-socket 连接的本地状态。每个 client 一份,跟 readLoop 一起活/灭。
/// 目前只装一个 `clientName`(来自 `initialize.params.clientInfo.name`),后续如果有更多
/// per-connection 状态(认证、订阅等)可以塞进来。`final class` 是为了让 readLoop 可以
/// 持引用、router 在 initialize 阶段写入,在后续 tools/call 阶段读出。
final class MCPClientContext: @unchecked Sendable {
    var clientName: String?

    init() {}
}

@MainActor
final class MCPRequestRouter {
    private let container: ModelContainer

    /// 5 个工具的注册表
    private let tools: [String: any MCPTool] = [
        "clipboard_get_current":      GetCurrentTool(),
        "clipboard_search":           SearchHistoryTool(),
        "clipboard_get":              GetItemTool(),
        "clipboard_list_recent_apps": ListRecentAppsTool(),
        "clipboard_set":              SetClipboardTool(),
    ]

    private let toolDescriptors: [MCPToolDescriptor] = [
        GetCurrentTool.descriptor,
        SearchHistoryTool.descriptor,
        GetItemTool.descriptor,
        ListRecentAppsTool.descriptor,
        SetClipboardTool.descriptor,
    ]

    init(container: ModelContainer) {
        self.container = container
    }

    func handle(_ req: JSONRPCRequest, context: MCPClientContext) async -> JSONRPCResponse {
        switch req.method {
        case "initialize":
            // 抓 clientInfo.name 存到 per-connection context,后续 tools/call 给
            // SetClipboardTool 用作 ClipItem.agentSource。
            if let info = req.params?.objectValue?["clientInfo"]?.objectValue,
               let name = info["name"]?.stringValue {
                context.clientName = name
            }
            return .success(id: req.id, result: .object([
                "protocolVersion": .string(MCPProtocol.mcpProtocolVersion),
                "capabilities": .object([
                    "tools": .object([:])
                ]),
                "serverInfo": .object([
                    "name": .string(MCPProtocol.serverName),
                    "version": .string(MCPProtocol.serverVersion)
                ])
            ]))
        case "tools/list":
            let arr: [JSONValue] = toolDescriptors.map { d in
                .object([
                    "name": .string(d.name),
                    "description": .string(d.description),
                    "inputSchema": d.inputSchema
                ])
            }
            return .success(id: req.id, result: .object(["tools": .array(arr)]))
        case "tools/call":
            return await handleToolCall(req, context: context)
        default:
            return .failure(id: req.id, error: .methodNotFound)
        }
    }

    private func handleToolCall(_ req: JSONRPCRequest, context: MCPClientContext) async -> JSONRPCResponse {
        guard let p = req.params?.objectValue,
              let name = p["name"]?.stringValue else {
            return .failure(id: req.id, error: .invalidParams("missing 'name'"))
        }
        guard let tool = tools[name] else {
            return .failure(id: req.id, error: .invalidParams("unknown tool: \(name)"))
        }

        // 当前隐私设置(从 UserDefaults / @AppStorage 读)
        let allowSensitive = UserDefaults.standard.bool(forKey: "mcpAllowSensitive")
        let blocklist = MCPSourceAppBlocklist.shared.blockedBundleIDs
        let guardLayer = PrivacyGuard(allowSensitive: allowSensitive, sourceAppBlocklist: blocklist)

        do {
            let result = try await tool.call(
                params: p["arguments"],
                container: container,
                guardLayer: guardLayer,
                clientName: context.clientName
            )
            return .success(id: req.id, result: result)
        } catch let err as MCPToolError {
            switch err {
            case .invalidParams(let msg): return .failure(id: req.id, error: .invalidParams(msg))
            case .toolError(let msg):     return .failure(id: req.id, error: .toolError(msg))
            }
        } catch {
            return .failure(id: req.id, error: .toolError(error.localizedDescription))
        }
    }
}
