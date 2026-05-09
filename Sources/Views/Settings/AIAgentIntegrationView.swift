import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct AIAgentIntegrationView: View {
    @AppStorage("mcpAllowSensitive") private var allowSensitive = false
    @State private var agentStates: [String: Bool] = [:]   // id -> installed?
    @State private var statusMessage: String?

    var body: some View {
        Form {
            if !mcpProxyBinaryExists {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("pastememo-mcp binary missing")
                                .font(.headline)
                            Text("This usually happens after an in-app update from a version before MCP support. Please re-download the DMG from lifedever.com to fix this.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Open Download Page") {
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

            Section("Service") {
                HStack {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("MCP server running")
                        .font(.callout)
                    Spacer()
                    Text(socketPath).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Agents") {
                ForEach(MCPAgentRegistry.all, id: \.id) { agent in
                    AgentRow(agent: agent,
                             installed: agentStates[agent.id] ?? false,
                             binaryExists: mcpProxyBinaryExists,
                             onInstall: { install(agent) },
                             onUninstall: { uninstall(agent) })
                }
            }

            Section("Privacy") {
                Toggle("Allow Agent to read sensitive items", isOn: $allowSensitive)
                NavigationLink("Source App Blocklist") {
                    MCPSourceAppBlocklistView()
                }
            }

            if let msg = statusMessage {
                Section { Text(msg).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshStates() }
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
            statusMessage = "Installed to \(agent.displayName). Restart \(agent.displayName) for changes to take effect."
        } catch {
            statusMessage = "Failed to install to \(agent.displayName): \(error.localizedDescription)"
        }
    }

    private func uninstall(_ agent: MCPAgentTarget) {
        do {
            try agent.uninstall()
            agentStates[agent.id] = false
            statusMessage = "Uninstalled from \(agent.displayName)."
        } catch {
            statusMessage = "Failed to uninstall from \(agent.displayName): \(error.localizedDescription)"
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
                Text(agent.detect() ? "Detected" : "Not installed").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Codex CLI 在 v1 是 manual config 模式;Claude Code/Cursor 一键
            if agent.id == "codex" {
                Button("Manual Config") { showSnippet = true }
                    .buttonStyle(.borderless)
            } else if installed {
                Button("Uninstall", role: .destructive, action: onUninstall)
                    .buttonStyle(.borderless)
            } else {
                Button("Install", action: onInstall)
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
            Text("Manual Configuration for \(agent.displayName)")
                .font(.headline)
            Text("Copy the snippet below and merge it into the relevant config file.")
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
                Button("Copy to Clipboard") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(snippet, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 480)
    }
}

@MainActor
struct MCPSourceAppBlocklistView: View {
    // @Observable singleton: 直接 let,SwiftUI 会自动追踪属性访问
    private let blocklist = MCPSourceAppBlocklist.shared

    var body: some View {
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
                Text("No blocked apps").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            Button("Add App") {
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
    }
}
