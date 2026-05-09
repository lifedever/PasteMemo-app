import Foundation

enum MCPInstallerError: Error, LocalizedError {
    case parseFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .parseFailed(let r): return "Failed to parse settings: \(r)"
        case .writeFailed(let r): return "Failed to write settings: \(r)"
        }
    }
}

enum MCPInstaller {

    /// 通用 JSON settings 安装。serverConfig 是完整的 server entry (`{ type, command, args, env, ... }`)。
    /// 用于 Claude Code 的 ~/.claude.json 和 Cursor 的 ~/.cursor/mcp.json 等。
    static func installToJSONSettings(file: URL, mcpServerKey: String, serverConfig: [String: Any]) throws {
        // 1. 备份(文件不存在则跳过)
        try makeBackup(of: file)

        // 2. 读 + 解析: 不存在或为空 → 起始空对象;格式坏 → 拒绝写入
        let json = try readSettings(file: file)

        // 3. 修改: mcpServers.<key> = serverConfig
        var mutable = json
        var mcpServers = (mutable["mcpServers"] as? [String: Any]) ?? [:]
        mcpServers[mcpServerKey] = serverConfig
        mutable["mcpServers"] = mcpServers

        // 4. atomic write
        try atomicWriteJSON(mutable, to: file)
    }

    /// 便利重载:只设 command,保持向后兼容
    static func installToJSONSettings(file: URL, mcpServerKey: String, command: String) throws {
        try installToJSONSettings(file: file, mcpServerKey: mcpServerKey, serverConfig: ["command": command])
    }

    /// 同上但移除 key
    static func uninstallFromJSONSettings(file: URL, mcpServerKey: String) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try makeBackup(of: file)

        let data = try Data(contentsOf: file)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPInstallerError.parseFailed(file.lastPathComponent)
        }
        if var mcpServers = json["mcpServers"] as? [String: Any] {
            mcpServers.removeValue(forKey: mcpServerKey)
            json["mcpServers"] = mcpServers
        }
        try atomicWriteJSON(json, to: file)
    }

    // MARK: - Helpers

    private static func readSettings(file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try Data(contentsOf: file)
        if data.isEmpty { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPInstallerError.parseFailed(file.lastPathComponent)
        }
        return json
    }

    private static func makeBackup(of file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = file.deletingPathExtension()
            .appendingPathExtension("\(file.pathExtension).pastememo-backup-\(ts)")
        try FileManager.default.copyItem(at: file, to: backup)
    }

    private static func atomicWriteJSON(_ obj: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj,
                                              options: [.prettyPrinted, .sortedKeys])
        let tmp = file.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: [.atomic])
        // rename atomically
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: file)
        }
    }
}
