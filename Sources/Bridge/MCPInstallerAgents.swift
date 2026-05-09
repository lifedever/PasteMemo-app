import Foundation

/// 一个 Agent 的元数据 + 安装/卸载方法
@MainActor
struct MCPAgentTarget {
    let id: String                   // "claude-code" / "codex" / "cursor"
    let displayName: String
    let detect: () -> Bool           // 是否本机已装
    let install: () throws -> Void
    let uninstall: () throws -> Void
    let isInstalled: () -> Bool      // 是否已写入 mcpServer 配置
}

@MainActor
enum MCPAgentRegistry {

    static var all: [MCPAgentTarget] {
        [claudeCode, codex, cursor]
    }

    // MARK: - Claude Code

    static var claudeCode: MCPAgentTarget {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeJSON = home.appendingPathComponent(".claude.json")    // Claude Code 实际读取的 MCP 配置文件
        let claudeDir = home.appendingPathComponent(".claude")          // 仍用于 skills 目录检测 + skill 文件
        let skillDir = claudeDir.appendingPathComponent("skills/pastememo")
        let skillFile = skillDir.appendingPathComponent("SKILL.md")

        return MCPAgentTarget(
            id: "claude-code",
            displayName: "Claude Code",
            detect: { FileManager.default.fileExists(atPath: claudeDir.path) },
            install: {
                let cmd = mcpProxyBinaryPath()
                let serverConfig: [String: Any] = [
                    "type": "stdio",
                    "command": cmd,
                    "args": [],
                    "env": [:]
                ]
                try MCPInstaller.installToJSONSettings(
                    file: claudeJSON,
                    mcpServerKey: "pastememo",
                    serverConfig: serverConfig
                )
                try installSkillFile(to: skillFile)
            },
            uninstall: {
                try MCPInstaller.uninstallFromJSONSettings(file: claudeJSON, mcpServerKey: "pastememo")
                try? FileManager.default.removeItem(at: skillDir)
            },
            isInstalled: {
                guard let data = try? Data(contentsOf: claudeJSON),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let mcpServers = json["mcpServers"] as? [String: Any]
                else { return false }
                return mcpServers["pastememo"] != nil
            }
        )
    }

    // MARK: - Codex

    static var codex: MCPAgentTarget {
        // Codex CLI 用 ~/.config/codex/config.toml
        // v1 提供"手动配置"弹窗,detect 仅检测目录,install 走手动 (UI 显示 TOML 片段)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexDir = home.appendingPathComponent(".config/codex")
        return MCPAgentTarget(
            id: "codex",
            displayName: "Codex CLI",
            detect: { FileManager.default.fileExists(atPath: codexDir.path) },
            install: { throw MCPInstallerError.writeFailed("Codex install must use manual config snippet (TOML)") },
            uninstall: { throw MCPInstallerError.writeFailed("Codex uninstall: edit config.toml manually") },
            isInstalled: { false }   // v1 总是返回 false,提示手动配置
        )
    }

    // MARK: - Cursor

    static var cursor: MCPAgentTarget {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cursorDir = home.appendingPathComponent(".cursor")
        let settings = cursorDir.appendingPathComponent("mcp.json")

        return MCPAgentTarget(
            id: "cursor",
            displayName: "Cursor",
            detect: {
                FileManager.default.fileExists(atPath: cursorDir.path)
                || FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Cursor/User").path)
            },
            install: {
                try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
                let cmd = mcpProxyBinaryPath()
                let serverConfig: [String: Any] = [
                    "type": "stdio",
                    "command": cmd,
                    "args": [],
                    "env": [:]
                ]
                try MCPInstaller.installToJSONSettings(
                    file: settings,
                    mcpServerKey: "pastememo",
                    serverConfig: serverConfig
                )
            },
            uninstall: {
                try MCPInstaller.uninstallFromJSONSettings(file: settings, mcpServerKey: "pastememo")
            },
            isInstalled: {
                guard let data = try? Data(contentsOf: settings),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let mcpServers = json["mcpServers"] as? [String: Any]
                else { return false }
                return mcpServers["pastememo"] != nil
            }
        )
    }

    // MARK: - Helpers

    /// 当前 .app 内的 pastememo-mcp 二进制路径
    private static func mcpProxyBinaryPath() -> String {
        let bundleURL = Bundle.main.bundleURL
        return bundleURL.appendingPathComponent("Contents/MacOS/pastememo-mcp").path
    }

    /// 把出厂 SKILL.md 拷到目标位置。
    /// 出厂 SKILL.md 通过 .copy("Resources") 放在 PasteMemo_PasteMemo.bundle 内,
    /// 路径: skills/pastememo/SKILL.md (相对于 bundle 根)
    private static func installSkillFile(to target: URL) throws {
        guard let source = Bundle.main.url(forResource: "SKILL",
                                           withExtension: "md",
                                           subdirectory: "skills/pastememo") else {
            // Bundle.main 找不到时,尝试 Bundle.module (test 环境或不同打包方式)
            #if SWIFT_PACKAGE
            if let source = Bundle.module.url(forResource: "SKILL",
                                              withExtension: "md",
                                              subdirectory: "skills/pastememo") {
                try copySkillFile(from: source, to: target)
                return
            }
            #endif
            throw MCPInstallerError.writeFailed("SKILL.md not found in bundle")
        }
        try copySkillFile(from: source, to: target)
    }

    private static func copySkillFile(from source: URL, to target: URL) throws {
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
    }
}
