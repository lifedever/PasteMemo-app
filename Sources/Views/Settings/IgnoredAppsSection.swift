import SwiftUI
import AppKit

struct IgnoredAppsSection: View {
    @State private var ignoredAppsManager = IgnoredAppsManager.shared
    @State private var isShowingAppPicker = false
    private var isLocked: Bool { !ProManager.shared.isPro }

    var body: some View {
        Section {
            if isLocked {
                lockedContent
            } else {
                unlockedContent
            }
        } header: {
            HStack {
                Text(L10n.tr("settings.ignoredApps"))
                if isLocked {
                    ProBadge()
                }
            }
        }
    }

    private var lockedContent: some View {
        Text(L10n.tr("settings.ignoredApps.empty"))
            .foregroundStyle(.tertiary)
            .font(.callout)
    }

    @ViewBuilder
    private var unlockedContent: some View {
        if ignoredAppsManager.ignoredApps.isEmpty {
            Text(L10n.tr("settings.ignoredApps.empty"))
                .foregroundStyle(.tertiary)
                .font(.callout)
        } else {
            ForEach(ignoredAppsManager.ignoredApps, id: \.bundleID) { app in
                IgnoredAppRow(bundleID: app.bundleID, name: app.name) {
                    ignoredAppsManager.removeApp(bundleID: app.bundleID)
                }
            }
        }

        Button(L10n.tr("settings.ignoredApps.add")) {
            isShowingAppPicker = true
        }
        .pointerCursor()
        .sheet(isPresented: $isShowingAppPicker) {
            AppPickerSheet(ignoredAppsManager: ignoredAppsManager, isPresented: $isShowingAppPicker)
        }
    }
}

// MARK: - Ignored App Row

private struct IgnoredAppRow: View {
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

private struct AppPickerSheet: View {
    var ignoredAppsManager: IgnoredAppsManager
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
                Button(L10n.tr("settings.ignoredApps.add")) {
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
            ignoredAppsManager.addApp(bundleID: app.bundleID, name: app.name)
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
                      !ignoredAppsManager.isIgnored(bundleID) else { return nil }
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
            ignoredAppsManager.addApp(bundleID: bundleID, name: name)
        }
        isPresented = false
    }
}

// MARK: - Pro Badge

struct ProBadge: View {
    var body: some View {
        Text("Pro")
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.orange, in: Capsule())
    }
}
