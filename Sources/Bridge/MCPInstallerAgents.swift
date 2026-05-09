import Foundation
import CryptoKit

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

    // MARK: - 环境隔离的 server key

    /// 当前 build 在 Claude Code / Cursor / Codex 配置文件里使用的 mcpServer key。
    /// dev build (bundleID 以 `.dev` 结尾) 自动用 `pastememo-dev`,prod 用 `pastememo`。
    /// 让用户可以同时安装 dev + prod 两个版本,各自独立注册,互不覆盖。
    static var pastememoServerKey: String {
        let bid = Bundle.main.bundleIdentifier ?? ""
        return bid.hasSuffix(".dev") ? "pastememo-dev" : "pastememo"
    }

    // MARK: - Claude Code

    static var claudeCode: MCPAgentTarget {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeJSON = home.appendingPathComponent(".claude.json")    // Claude Code 实际读取的 MCP 配置文件
        let claudeDir = home.appendingPathComponent(".claude")          // 仍用于 skills 目录检测 + skill 文件
        let key = pastememoServerKey
        let skillDir = claudeDir.appendingPathComponent("skills/\(key)")
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
                    mcpServerKey: key,
                    serverConfig: serverConfig
                )
                try installSkillFile(to: skillFile, serverKey: key)
            },
            uninstall: {
                try MCPInstaller.uninstallFromJSONSettings(file: claudeJSON, mcpServerKey: key)
                try? FileManager.default.removeItem(at: skillDir)
                UserDefaults.standard.removeObject(forKey: skillInstalledHashKey(serverKey: key))
            },
            isInstalled: {
                guard let data = try? Data(contentsOf: claudeJSON),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let mcpServers = json["mcpServers"] as? [String: Any]
                else { return false }
                return mcpServers[key] != nil
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
        let key = pastememoServerKey

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
                    mcpServerKey: key,
                    serverConfig: serverConfig
                )
            },
            uninstall: {
                try MCPInstaller.uninstallFromJSONSettings(file: settings, mcpServerKey: key)
            },
            isInstalled: {
                guard let data = try? Data(contentsOf: settings),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let mcpServers = json["mcpServers"] as? [String: Any]
                else { return false }
                return mcpServers[key] != nil
            }
        )
    }

    // MARK: - Helpers

    /// 当前 .app 内的 pastememo-mcp 二进制路径
    static func mcpProxyBinaryPath() -> String {
        let bundleURL = Bundle.main.bundleURL
        return bundleURL.appendingPathComponent("Contents/MacOS/pastememo-mcp").path
    }

    /// 把出厂 SKILL.md 拷到目标位置,同时把 frontmatter 里的 `{{SERVER_KEY}}` 替换成实际 key。
    /// 出厂 SKILL.md 通过 .copy("Resources") 放在 PasteMemo_PasteMemo.bundle 内,
    /// 路径: skills/pastememo/SKILL.md (相对于 bundle 根,源文件名固定不随 build 变)。
    /// 写入后会把渲染后的 SHA256 存到 UserDefaults,供后续 syncIfNeeded 判断本地是否被用户改过。
    private static func installSkillFile(to target: URL, serverKey: String) throws {
        let source = try locateSkillTemplate()
        let template = try String(contentsOf: source, encoding: .utf8)
        let rendered = template.replacingOccurrences(of: "{{SERVER_KEY}}", with: serverKey)

        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try rendered.write(to: target, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(sha256(rendered), forKey: skillInstalledHashKey(serverKey: serverKey))
    }

    // MARK: - Auto-sync

    /// 启动时调用:对"已经主动安装过 SKILL.md"的 agent 静默更新 skill 文件——
    /// 仅当本地内容自上次安装以来未被用户改动时,才用最新出厂模板覆盖。
    /// 用户改过 / 删过本地文件 / 从未点过 Install,都不动。
    static func syncSkillsIfNeeded() {
        let agent = claudeCode
        guard agent.isInstalled() else { return }      // 没在 .claude.json 里 = 没主动装过

        let key = pastememoServerKey
        let home = FileManager.default.homeDirectoryForCurrentUser
        let skillFile = home.appendingPathComponent(".claude/skills/\(key)/SKILL.md")

        guard let templateURL = try? locateSkillTemplate(),
              let template = try? String(contentsOf: templateURL, encoding: .utf8)
        else { return }
        let rendered = template.replacingOccurrences(of: "{{SERVER_KEY}}", with: key)
        let renderedHash = sha256(rendered)

        let hashKey = skillInstalledHashKey(serverKey: key)
        let storedHash = UserDefaults.standard.string(forKey: hashKey)

        // 中间态补救:用户在没有 hash 写入逻辑的旧版 App 上 install 过,本地文件是
        // 历史某版本模板的渲染产物。如果它恰好等于当前模板渲染产物,直接补 hash
        // 把用户纳入 auto-sync 体系——这样老用户也无需重新点 Install。
        // 内容不匹配则不动,等用户主动 reinstall(避免误判用户改过的内容是模板)。
        if storedHash == nil {
            guard let local = try? String(contentsOf: skillFile, encoding: .utf8),
                  sha256(local) == renderedHash
            else { return }
            UserDefaults.standard.set(renderedHash, forKey: hashKey)
            return
        }

        guard storedHash != renderedHash else { return }   // 模板没变,常态分支

        // 模板变了,看本地有没有被用户改过
        guard let localContent = try? String(contentsOf: skillFile, encoding: .utf8) else { return }
        guard sha256(localContent) == storedHash else { return }  // 用户改过,尊重不动

        // 用户没改过 → 静默升级
        do {
            try rendered.write(to: skillFile, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(renderedHash, forKey: hashKey)
        } catch {
            // 失败就静默放过,下次启动再试
        }
    }

    private static func skillInstalledHashKey(serverKey: String) -> String {
        "mcpSkillInstalledHash.\(serverKey)"
    }

    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }

    private static func locateSkillTemplate() throws -> URL {
        if let url = Bundle.main.url(forResource: "SKILL",
                                     withExtension: "md",
                                     subdirectory: "skills/pastememo") {
            return url
        }
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "SKILL",
                                       withExtension: "md",
                                       subdirectory: "skills/pastememo") {
            return url
        }
        #endif
        throw MCPInstallerError.writeFailed("SKILL.md not found in bundle")
    }
}
