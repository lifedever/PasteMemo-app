import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct AIAgentIntegrationView: View {
    @AppStorage("mcpAllowSensitive") private var allowSensitive = false
    @State private var agentStates: [String: Bool] = [:]   // id -> installed?
    @State private var agentStatusMessages: [String: String] = [:]

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
                             statusMessage: agentStatusMessages[agent.id],
                             onInstall: { install(agent) },
                             onUninstall: { uninstall(agent) })
                }
            }

            Section(L10n.tr("settings.aiAgents.privacy")) {
                Toggle(L10n.tr("settings.aiAgents.allowSensitive"), isOn: $allowSensitive)
            }

            MCPSourceAppBlocklistSection()

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
            agentStatusMessages[agent.id] = String(format: L10n.tr("settings.aiAgents.installed"), agent.displayName, agent.displayName)
        } catch {
            agentStatusMessages[agent.id] = String(format: L10n.tr("settings.aiAgents.installFailed"), agent.displayName, error.localizedDescription)
        }
    }

    private func uninstall(_ agent: MCPAgentTarget) {
        do {
            try agent.uninstall()
            agentStates[agent.id] = false
            agentStatusMessages[agent.id] = String(format: L10n.tr("settings.aiAgents.uninstalled"), agent.displayName)
        } catch {
            agentStatusMessages[agent.id] = String(format: L10n.tr("settings.aiAgents.uninstallFailed"), agent.displayName, error.localizedDescription)
        }
    }
}

@MainActor
private struct AgentRow: View {
    let agent: MCPAgentTarget
    let installed: Bool
    let binaryExists: Bool
    let statusMessage: String?
    let onInstall: () -> Void
    let onUninstall: () -> Void
    @State private var showSnippet = false

    private var captionText: String {
        if let msg = statusMessage { return msg }
        return L10n.tr(agent.detect() ? "settings.aiAgents.detected" : "settings.aiAgents.notInstalled")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                Text(captionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // Codex CLI 在 v1 是 manual config 模式;其他 Agent 未检测到时也走手动
            if agent.id == "codex" || !agent.detect() {
                Button(L10n.tr("settings.aiAgents.manualConfig")) { showSnippet = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .pointerCursor()
            } else if installed {
                InstalledBadge(onUninstall: onUninstall)
            } else {
                Button(L10n.tr("settings.aiAgents.install"), action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .disabled(!binaryExists)
                    .pointerCursor()
            }
        }
        .sheet(isPresented: $showSnippet) {
            ManualConfigSheet(agent: agent)
        }
    }
}

@MainActor
private struct InstalledBadge: View {
    let onUninstall: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if hovering {
                Button(L10n.tr("settings.aiAgents.uninstall"),
                       role: .destructive,
                       action: onUninstall)
                    .buttonStyle(.borderless)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                    Text(L10n.tr("settings.aiAgents.installed.label"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        // pointerCursor 用 .onHover push/pop;放外层 Group(常驻视图)上,
        // 否则内部 Button 是 hovering=true 之后才创建的,光标已停在区域里
        // .onHover 不会再次触发,变不成小手。
        .pointerCursor()
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

@MainActor
private struct ManualConfigSheet: View {
    let agent: MCPAgentTarget
    @Environment(\.dismiss) private var dismiss

    /// Codex 用 TOML 格式
    private var snippet: String {
        let cmd = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pastememo-mcp").path
        let key = MCPAgentRegistry.pastememoServerKey  // dev/prod 自动用不同 key
        switch agent.id {
        case "codex":
            return """
            # Add this to ~/.config/codex/config.toml under [mcp_servers]:

            [mcp_servers.\(key)]
            command = "\(cmd)"
            """
        default:
            // 通用 JSON 片段(给手动配置的 Cline 等)
            return """
            {
              "mcpServers": {
                "\(key)": {
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

// MARK: - MCP Source App Blocklist Section

@MainActor
struct MCPSourceAppBlocklistSection: View {
    @State private var blocklist = MCPSourceAppBlocklist.shared
    @State private var isShowingAppPicker = false

    var body: some View {
        Section {
            sectionContent
        } header: {
            Text(L10n.tr("settings.aiAgents.sourceBlocklist"))
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        if blocklist.blockedApps.isEmpty {
            Text(L10n.tr("settings.aiAgents.blocklist.empty"))
                .foregroundStyle(.tertiary)
                .font(.callout)
        } else {
            ForEach(blocklist.blockedApps, id: \.bundleID) { app in
                MCPBlockedAppRow(bundleID: app.bundleID, name: app.name) {
                    blocklist.remove(bundleID: app.bundleID)
                }
            }
        }

        Button(L10n.tr("settings.aiAgents.blocklist.add")) {
            isShowingAppPicker = true
        }
        .pointerCursor()
        .sheet(isPresented: $isShowingAppPicker) {
            MCPAppPickerSheet(blocklist: blocklist, isPresented: $isShowingAppPicker)
        }
    }
}

// MARK: - Row

private struct MCPBlockedAppRow: View {
    let bundleID: String
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack {
            appIcon
            Text(name)
            Spacer()
            Button { onRemove() } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var appIcon: some View {
        let icon = resolveIcon(bundleID: bundleID)
        return Image(nsImage: icon)
            .resizable()
            .frame(width: 20, height: 20)
    }

    private func resolveIcon(bundleID: String) -> NSImage {
        if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage()
    }
}

// MARK: - App Picker Sheet

private struct MCPAppPickerSheet: View {
    var blocklist: MCPSourceAppBlocklist
    @Binding var isPresented: Bool
    @State private var runningApps: [(bundleID: String, name: String, icon: NSImage)] = []
    @State private var selectedBundleIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            runningAppsList
            Divider()
            sheetFooter
        }
        .frame(width: 340, height: 400)
        .onAppear { loadRunningApps() }
    }

    private var sheetHeader: some View {
        Text(L10n.tr("settings.ignoredApps.selectApp"))
            .font(.headline)
            .padding()
    }

    private var runningAppsList: some View {
        List {
            Section(L10n.tr("settings.ignoredApps.running")) {
                ForEach(Array(runningApps.enumerated()), id: \.element.bundleID) { _, app in
                    let bid = app.bundleID
                    let isSelected = selectedBundleIDs.contains(bid)
                    Button {
                        if isSelected {
                            selectedBundleIDs.remove(bid)
                        } else {
                            selectedBundleIDs.insert(bid)
                        }
                    } label: {
                        HStack {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(app.name)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }

    private var sheetFooter: some View {
        HStack {
            Button(L10n.tr("settings.ignoredApps.browse")) {
                browseForApp()
            }
            .pointerCursor()
            Spacer()
            Button(L10n.tr("action.cancel")) {
                isPresented = false
            }
            .pointerCursor()
            if !selectedBundleIDs.isEmpty {
                Button(L10n.tr("settings.aiAgents.blocklist.add")) {
                    addSelectedApps()
                }
                .pointerCursor()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func addSelectedApps() {
        for bundleID in selectedBundleIDs {
            guard let app = runningApps.first(where: { $0.bundleID == bundleID }) else { continue }
            blocklist.add(bundleID: app.bundleID, name: app.name)
        }
        isPresented = false
    }

    private func loadRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleID: String, name: String, icon: NSImage)? in
                guard let bundleID = app.bundleIdentifier,
                      let name = app.localizedName,
                      !bundleID.contains("pastememo"),
                      !blocklist.isBlocked(bundleID) else { return nil }
                return (bundleID: bundleID, name: name, icon: app.icon ?? NSImage())
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        runningApps = apps
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier else { continue }
            let name = bundle.infoDictionary?["CFBundleName"] as? String
                ?? url.deletingPathExtension().lastPathComponent
            blocklist.add(bundleID: bundleID, name: name)
        }
        isPresented = false
    }
}
