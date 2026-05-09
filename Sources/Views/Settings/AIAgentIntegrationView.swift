import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct AIAgentIntegrationView: View {
    @AppStorage("mcpAllowSensitive") private var allowSensitive = false
    @State private var agentStates: [String: Bool] = [:]   // id -> installed?
    @State private var statusMessage: String?
    @State private var showBlocklistSheet = false

    var body: some View {
        Form {
            if !mcpProxyBinaryExists {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("settings.aiAgents.binaryMissing"))
                                .font(.headline)
                            Text(L10n.tr("settings.aiAgents.binaryMissingDetail"))
                                .font(.caption).foregroundStyle(.secondary)
                            Button(L10n.tr("settings.aiAgents.openDownload")) {
                                if let url = URL(string: "https://www.lifedever.com/PasteMemo/") {
                                    NSWorkspace.shared.open(url)
                                }
                            }.buttonStyle(.link)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            Section(L10n.tr("settings.aiAgents.service")) {
                HStack {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(L10n.tr("settings.aiAgents.serverRunning"))
                        .font(.callout)
                    Spacer()
                    Text(socketPath).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L10n.tr("settings.aiAgents.agents")) {
                ForEach(MCPAgentRegistry.all, id: \.id) { agent in
                    AgentRow(agent: agent,
                             installed: agentStates[agent.id] ?? false,
                             binaryExists: mcpProxyBinaryExists,
                             onInstall: { install(agent) },
                             onUninstall: { uninstall(agent) })
                }
            }

            Section(L10n.tr("settings.aiAgents.privacy")) {
                Toggle(L10n.tr("settings.aiAgents.allowSensitive"), isOn: $allowSensitive)
                Button {
                    showBlocklistSheet = true
                } label: {
                    HStack {
                        Text(L10n.tr("settings.aiAgents.sourceBlocklist"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            if let msg = statusMessage {
                Section { Text(msg).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshStates() }
        .sheet(isPresented: $showBlocklistSheet) {
            MCPSourceAppBlocklistView()
                .frame(minWidth: 480, minHeight: 360)
        }
    }

    private var socketPath: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo"
        return "~/Library/Application Support/\(bundleID)/mcp.sock"
    }

    private var mcpProxyBinaryExists: Bool {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pastememo-mcp").path
        return FileManager.default.fileExists(atPath: path)
    }

    private func refreshStates() {
        for agent in MCPAgentRegistry.all {
            agentStates[agent.id] = agent.isInstalled()
        }
    }

    private func install(_ agent: MCPAgentTarget) {
        do {
            try agent.install()
            agentStates[agent.id] = true
            statusMessage = String(format: L10n.tr("settings.aiAgents.installed"), agent.displayName, agent.displayName)
        } catch {
            statusMessage = String(format: L10n.tr("settings.aiAgents.installFailed"), agent.displayName, error.localizedDescription)
        }
    }

    private func uninstall(_ agent: MCPAgentTarget) {
        do {
            try agent.uninstall()
            agentStates[agent.id] = false
            statusMessage = String(format: L10n.tr("settings.aiAgents.uninstalled"), agent.displayName)
        } catch {
            statusMessage = String(format: L10n.tr("settings.aiAgents.uninstallFailed"), agent.displayName, error.localizedDescription)
        }
    }
}

@MainActor
private struct AgentRow: View {
    let agent: MCPAgentTarget
    let installed: Bool
    let binaryExists: Bool
    let onInstall: () -> Void
    let onUninstall: () -> Void
    @State private var showSnippet = false

    var body: some View {
        HStack {
            Image(systemName: agent.detect() ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(agent.detect() ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(agent.displayName)
                Text(L10n.tr(agent.detect() ? "settings.aiAgents.detected" : "settings.aiAgents.notInstalled")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Codex CLI 在 v1 是 manual config 模式;其他 Agent 未检测到时也走手动
            if agent.id == "codex" || !agent.detect() {
                Button(L10n.tr("settings.aiAgents.manualConfig")) { showSnippet = true }
                    .buttonStyle(.borderless)
            } else if installed {
                Button(L10n.tr("settings.aiAgents.uninstall"), role: .destructive, action: onUninstall)
                    .buttonStyle(.borderless)
            } else {
                Button(L10n.tr("settings.aiAgents.install"), action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .disabled(!binaryExists)
            }
        }
        .sheet(isPresented: $showSnippet) {
            ManualConfigSheet(agent: agent)
        }
    }
}

@MainActor
private struct ManualConfigSheet: View {
    let agent: MCPAgentTarget
    @Environment(\.dismiss) private var dismiss

    /// Codex 用 TOML 格式
    private var snippet: String {
        let cmd = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pastememo-mcp").path
        switch agent.id {
        case "codex":
            return """
            # Add this to ~/.config/codex/config.toml under [mcp_servers]:

            [mcp_servers.pastememo]
            command = "\(cmd)"
            """
        default:
            // 通用 JSON 片段(给手动配置的 Cline 等)
            return """
            {
              "mcpServers": {
                "pastememo": {
                  "command": "\(cmd)"
                }
              }
            }
            """
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: L10n.tr("settings.aiAgents.manualConfig.title"), agent.displayName))
                .font(.headline)
            Text(L10n.tr("settings.aiAgents.manualConfig.subtitle"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(snippet)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
            }
            .frame(maxHeight: 200)
            HStack {
                Button(L10n.tr("settings.aiAgents.manualConfig.copy")) {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(snippet, forType: .string)
                }
                Spacer()
                Button(L10n.tr("settings.aiAgents.manualConfig.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480)
    }
}

@MainActor
struct MCPSourceAppBlocklistView: View {
    private let blocklist = MCPSourceAppBlocklist.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("settings.aiAgents.sourceBlocklist"))
                    .font(.headline)
                Spacer()
                Button(L10n.tr("settings.aiAgents.blocklist.add")) {
                    addAppViaPanel()
                }
            }
            .padding()
            .background(.bar)

            Divider()

            List {
                ForEach(blocklist.blockedApps, id: \.bundleID) { app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            blocklist.remove(bundleID: app.bundleID)
                        } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }
                if blocklist.blockedApps.isEmpty {
                    Text(L10n.tr("settings.aiAgents.blocklist.empty")).foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(L10n.tr("settings.aiAgents.manualConfig.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    private func addAppViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url),
           let bid = bundle.bundleIdentifier {
            let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
            blocklist.add(bundleID: bid, name: name)
        }
    }
}
