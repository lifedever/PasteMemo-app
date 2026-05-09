import Foundation

enum MCPProtocol {
    static let mcpProtocolVersion = "2024-11-05"
    static let serverName = "pastememo"
    static let serverVersion = "1.0.0"
}

// MARK: - JSON-RPC 2.0 envelope

struct JSONRPCRequest: Decodable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String
    let params: JSONValue?
}

struct JSONRPCResponse: Encodable, Sendable {
    let jsonrpc: String = "2.0"
    let id: JSONRPCID?
    let result: JSONValue?
    let error: JSONRPCError?

    static func success(id: JSONRPCID?, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }
    static func failure(id: JSONRPCID?, error: JSONRPCError) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: nil, error: error)
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        // 仅编码非 nil 的一项,避免同时出现 result+error (JSON-RPC 2.0 §5.1)
        if let result = result {
            try c.encode(result, forKey: .result)
        } else if let error = error {
            try c.encode(error, forKey: .error)
        }
    }
}

struct JSONRPCError: Encodable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?

    static let parseError       = JSONRPCError(code: -32700, message: "Parse error", data: nil)
    static let invalidRequest   = JSONRPCError(code: -32600, message: "Invalid Request", data: nil)
    static let methodNotFound   = JSONRPCError(code: -32601, message: "Method not found", data: nil)
    static func invalidParams(_ reason: String) -> JSONRPCError {
        .init(code: -32602, message: "Invalid params: \(reason)", data: nil)
    }
    static func toolError(_ message: String) -> JSONRPCError {
        .init(code: -32000, message: message, data: nil)
    }
}

/// JSON-RPC id 可以是 number、string 或 null
enum JSONRPCID: Codable, Sendable {
    case number(Int)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let i = try? c.decode(Int.self) { self = .number(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid JSON-RPC id")
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        case .null: try c.encodeNil()
        }
    }
}

/// 通用 JSON 容器（params / result 是任意 JSON）
indirect enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid JSON")
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let b):    try c.encode(b)
        case .number(let n):  try c.encode(n)
        case .string(let s):  try c.encode(s)
        case .array(let a):   try c.encode(a)
        case .object(let o):  try c.encode(o)
        }
    }

    // 便利访问器
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    var intValue: Int? {
        guard case .number(let n) = self else { return nil }
        guard n.rounded() == n, n >= Double(Int.min), n <= Double(Int.max) else { return nil }
        return Int(n)
    }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}

// MARK: - MCP-specific

/// MCP tool 元数据（用于 tools/list 响应）
struct MCPToolDescriptor: Encodable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue   // JSON Schema
}
