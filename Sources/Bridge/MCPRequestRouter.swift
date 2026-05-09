import Foundation
import SwiftData

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

    func handle(_ req: JSONRPCRequest) async -> JSONRPCResponse {
        switch req.method {
        case "initialize":
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
            return await handleToolCall(req)
        default:
            return .failure(id: req.id, error: .methodNotFound)
        }
    }

    private func handleToolCall(_ req: JSONRPCRequest) async -> JSONRPCResponse {
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
            let result = try await tool.call(params: p["arguments"], container: container, guardLayer: guardLayer)
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
