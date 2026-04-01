import SwiftUI
import SwiftData
import ServiceManagement
import Carbon

struct SettingsView: View {
    @EnvironmentObject var proManager: ProManager

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label(L10n.tr("settings.general"), systemImage: "gear") }
            PreferencesTab()
                .tabItem { Label(L10n.tr("settings.preferences"), systemImage: "slider.horizontal.3") }
            RelayTab()
                .tabItem { Label(L10n.tr("relay.tab"), systemImage: "arrow.forward") }
            PrivacyTab()
                .tabItem { Label(L10n.tr("settings.privacy"), systemImage: "lock.shield") }
            if ProManager.AUTOMATION_ENABLED {
                AutomationTab()
                    .tabItem { Label(L10n.tr("settings.automation"), systemImage: "gearshape.2") }
            }
            DataTab()
                .tabItem { Label(L10n.tr("dataPorter.section"), systemImage: "externaldrive") }
            ProTab()
                .environmentObject(proManager)
                .tabItem { Label("Pro", systemImage: "star") }
            AboutTab()
                .tabItem { Label(L10n.tr("settings.about"), systemImage: "info.circle") }
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
        .localized()
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @ObservedObject private var languageManager = LanguageManager.shared
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("copySoundName") private var copySoundName = "custom:sound2"
    @AppStorage("pasteSoundName") private var pasteSoundName = "custom:sound1"
    @State private var previousLanguage = LanguageManager.shared.current

    var body: some View {
        Form {
            Section(L10n.tr("settings.general")) {
                Toggle(L10n.tr("settings.launchAtLogin"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        if launchAtLogin {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                    }
            }

            Section(L10n.tr("settings.appearance")) {
                Picker(L10n.tr("settings.theme"), selection: $appearanceMode) {
                    Text(L10n.tr("settings.theme.system")).tag("system")
                    Text(L10n.tr("settings.theme.light")).tag("light")
                    Text(L10n.tr("settings.theme.dark")).tag("dark")
                }
                .onChange(of: appearanceMode) {
                    AppDelegate.applyAppearance(appearanceMode)
                }

                Picker(L10n.tr("settings.language"), selection: $languageManager.current) {
                    ForEach(L10n.supportedLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .onChange(of: languageManager.current) {
                    guard languageManager.current != previousLanguage else { return }
                    previousLanguage = languageManager.current
                    showLanguageRestartAlert()
                }

            }

            Section(L10n.tr("settings.sound")) {
                Toggle(L10n.tr("settings.sound.enabled"), isOn: $soundEnabled)
                if soundEnabled {
                    soundPicker(
                        label: L10n.tr("settings.sound.copy"),
                        selection: $copySoundName
                    )
                    soundPicker(
                        label: L10n.tr("settings.sound.paste"),
                        selection: $pasteSoundName
                    )
                }
            }

            Section {
                Button(L10n.tr("settings.showGuide")) {
                    showOnboardingWindow()
                }
                .pointerCursor()
            }
        }
        .formStyle(.grouped)
    }


    private func soundPicker(label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            Section(L10n.tr("settings.sound.section.custom")) {
                ForEach(SoundManager.CUSTOM_SOUNDS, id: \.storageKey) { source in
                    Text(source.displayName).tag(source.storageKey)
                }
            }
            Section(L10n.tr("settings.sound.section.system")) {
                ForEach(SoundManager.SYSTEM_SOUNDS, id: \.storageKey) { source in
                    Text(source.displayName).tag(source.storageKey)
                }
            }
        }
        .onChange(of: selection.wrappedValue) {
            SoundManager.preview(.from(storageKey: selection.wrappedValue))
        }
    }

    private func showLanguageRestartAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("settings.language.restart_title")
        alert.informativeText = L10n.tr("settings.language.restart_message")
        alert.addButton(withTitle: L10n.tr("settings.language.restart_now"))
        alert.addButton(withTitle: L10n.tr("settings.language.restart_later"))
        if alert.runModal() == .alertFirstButtonReturn {
            relaunchApp()
        }
    }

    private func relaunchApp() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && open \"\(path)\""]
        try? task.launch()
        AppDelegate.shouldReallyQuit = true
        NSApp.terminate(nil)
    }
}

// MARK: - Data Tab

struct DataTab: View {
    var body: some View {
        Form {
            BackupSettingsSection()
            DataPorterSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Preferences Tab

struct PreferencesTab: View {
    @ObservedObject private var hotkeyManager = HotkeyManager.shared
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 0x09
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = cmdKey | shiftKey
    @AppStorage("managerHotkeyKeyCode") private var managerKeyCode = -1
    @AppStorage("managerHotkeyModifiers") private var managerModifiers = -1
    @AppStorage("doubleTapEnabled") private var doubleTapEnabled = false
    @AppStorage("doubleTapModifier") private var doubleTapModifier = 0
    @AppStorage("retentionDays") private var retentionDays = 90
    @AppStorage("addNewLineAfterPaste") private var addNewLineAfterPaste = false
    @AppStorage("showLinkURL") private var showLinkURL = false
    @AppStorage("webPreviewEnabled") private var webPreviewEnabled = true
    @ObservedObject private var proManager = ProManager.shared

    private let allRetentionOptions = [1, 3, 7, 14, 30, 60, 90, 180, 365]

    private var availableOptions: [Int] {
        proManager.isPro
            ? allRetentionOptions
            : allRetentionOptions.filter { $0 <= ProManager.FREE_HISTORY_DAYS }
    }

    private var showForever: Bool { proManager.isPro }

    var body: some View {
        Form {
            Section(L10n.tr("settings.shortcuts")) {
                HStack {
                    Text(L10n.tr("settings.quickPanelShortcut"))
                    Spacer()
                    if hotkeyManager.isCleared {
                        Text(L10n.tr("settings.shortcut.none"))
                            .foregroundStyle(.tertiary)
                            .font(.callout)
                    }
                    ShortcutRecorder(keyCode: $hotkeyKeyCode, modifiers: $hotkeyModifiers, onChanged: applyShortcut)
                        .frame(width: 140, height: 24)
                    Button {
                        hotkeyManager.clearShortcut()
                        hotkeyKeyCode = -1
                        hotkeyModifiers = -1
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                HStack {
                    Text(L10n.tr("settings.managerShortcut"))
                    Spacer()
                    if hotkeyManager.isManagerCleared {
                        Text(L10n.tr("settings.shortcut.none"))
                            .foregroundStyle(.tertiary)
                            .font(.callout)
                    }
                    ShortcutRecorder(keyCode: $managerKeyCode, modifiers: $managerModifiers, onChanged: applyManagerShortcut)
                        .frame(width: 140, height: 24)
                    Button {
                        hotkeyManager.clearManagerShortcut()
                        managerKeyCode = -1
                        managerModifiers = -1
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                Toggle(L10n.tr("settings.doubleTap"), isOn: $doubleTapEnabled)
                    .onChange(of: doubleTapEnabled) {
                        DoubleTapDetector.shared.restart()
                    }
                if doubleTapEnabled {
                    Picker(L10n.tr("settings.doubleTap.modifier"), selection: $doubleTapModifier) {
                        ForEach(DoubleTapModifier.allCases, id: \.rawValue) { mod in
                            Text(mod.label).tag(mod.rawValue)
                        }
                    }
                    .onChange(of: doubleTapModifier) {
                        DoubleTapDetector.shared.restart()
                    }
                }
            }

            Section(L10n.tr("settings.behavior")) {
                Toggle(L10n.tr("settings.addNewLine"), isOn: $addNewLineAfterPaste)
                Toggle(L10n.tr("settings.showLinkURL"), isOn: $showLinkURL)
                Toggle(L10n.tr("settings.webPreview"), isOn: $webPreviewEnabled)
            }

            Section(L10n.tr("settings.history")) {
                Picker(L10n.tr("settings.retentionDays"), selection: $retentionDays) {
                    if showForever {
                        Text(L10n.tr("settings.retentionDays.forever")).tag(0)
                    }
                    ForEach(availableOptions, id: \.self) { days in
                        Text(L10n.tr("settings.retentionDays.days", days)).tag(days)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func applyShortcut() {
        HotkeyManager.shared.updateShortcut(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }

    private func applyManagerShortcut() {
        HotkeyManager.shared.updateManagerShortcut(keyCode: managerKeyCode, modifiers: managerModifiers)
    }
}

// MARK: - Relay Tab

struct RelayTab: View {
    @AppStorage("relayPasteKeyCode") private var relayPasteKeyCode = 0x09
    @AppStorage("relayPasteModifiers") private var relayPasteModifiers = controlKey
    @AppStorage("relayAlertDismissed") private var relayAlertDismissed = false

    private var pasteShortcut: String {
        shortcutDisplayString(keyCode: relayPasteKeyCode, modifiers: relayPasteModifiers)
    }

    var body: some View {
        Form {
            Section {
                Text(L10n.tr("relay.settings.description"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.tr("relay.settings.shortcuts")) {
                HStack {
                    Text(L10n.tr("relay.settings.pasteKey"))
                    Spacer()
                    ShortcutRecorder(keyCode: $relayPasteKeyCode, modifiers: $relayPasteModifiers)
                        .frame(width: 140, height: 24)
                        .disabled(RelayManager.shared.isActive && !RelayManager.shared.isPaused)
                }
                Text(RelayManager.shared.isActive && !RelayManager.shared.isPaused
                    ? L10n.tr("relay.settings.pauseToChange")
                    : L10n.tr("relay.settings.pasteKeyNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.tr("relay.settings.operations")) {
                HStack {
                    Text(L10n.tr("relay.settings.op.paste"))
                    Spacer()
                    Text(pasteShortcut)
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section {
                if relayAlertDismissed {
                    Button(L10n.tr("relay.settings.resetAlert")) {
                        relayAlertDismissed = false
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Privacy Tab

struct PrivacyTab: View {
    @AppStorage("sensitiveDetectionEnabled") private var isSensitiveDetectionEnabled = true

    var body: some View {
        Form {
            Section(L10n.tr("settings.privacy.sensitive")) {
                Toggle(L10n.tr("settings.privacy.sensitiveDetection"), isOn: $isSensitiveDetectionEnabled)
                Text(L10n.tr("settings.privacy.sensitiveHint"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            IgnoredAppsSection()
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Automation Tab

struct AutomationTab: View {
    @AppStorage("automationEnabled") private var automationEnabled = true
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AutomationRule.sortOrder) private var rules: [AutomationRule]
    @ObservedObject private var proManager = ProManager.shared

    private var enabledCount: Int { rules.filter(\.enabled).count }

    var body: some View {
        Form {
            if proManager.isPro {
                automationContent
            } else {
                proLockedSection
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var automationContent: some View {
        Group {
            Section {
                Toggle(L10n.tr("settings.automation.enabled"), isOn: $automationEnabled)
            }

            Section(L10n.tr("settings.automation.ruleCount", rules.count, enabledCount)) {
                ForEach(rules) { rule in
                    Toggle(isOn: Binding(
                        get: { rule.enabled },
                        set: { rule.enabled = $0; try? modelContext.save() }
                    )) {
                        HStack {
                            Text(rule.isBuiltIn ? L10n.tr(rule.name) : rule.name)
                            Spacer()
                            Text(rule.triggerMode == .automatic
                                ? L10n.tr("settings.automation.auto")
                                : L10n.tr("settings.automation.manual"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section {
                Button(L10n.tr("settings.automation.manage")) {
                    AutomationManagerWindow.show()
                }
                .pointerCursor()

                Text(L10n.tr("settings.automation.hint"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var proLockedSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(L10n.tr("settings.automation.proRequired"))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Pro Tab

struct ProTab: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)

                    Text("PasteMemo Pro")
                        .font(.headline)

                    Text(L10n.tr("pro.beta.desc"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section(L10n.tr("pro.features")) {
                Label(L10n.tr("pro.feature.unlimited"), systemImage: "infinity")
                Label(L10n.tr("pro.feature.automation"), systemImage: "gearshape.2")
                Label(L10n.tr("pro.feature.customCategory"), systemImage: "folder")
                Label(L10n.tr("pro.feature.smartGroup"), systemImage: "gearshape.arrow.triangle.2.circlepath")
                Label(L10n.tr("pro.feature.icloud"), systemImage: "icloud")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - About Tab

struct AboutTab: View {
    @ObservedObject private var updateChecker = UpdateChecker.shared

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    Text("PasteMemo")
                        .font(.title2.bold())
                    Text(L10n.tr("about.description"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                HStack {
                    Text(L10n.tr("settings.currentVersion"))
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                        .foregroundStyle(.secondary)
                }
                Button(L10n.tr("menu.checkForUpdates")) {
                    Task { await updateChecker.checkForUpdates(userInitiated: true) }
                }
                .disabled(updateChecker.isChecking)
            }

            Section {
                Link(L10n.tr("about.website"), destination: URL(string: "https://www.lifedever.com/PasteMemo/")!)
                Link(L10n.tr("about.help"), destination: URL(string: "https://www.lifedever.com/PasteMemo/help/")!)
                Link(L10n.tr("menu.reportIssue"), destination: URL(string: "https://github.com/lifedever/PasteMemo/issues")!)
                Link(L10n.tr("about.sponsor"), destination: URL(string: "https://www.lifedever.com/")!)
            }

            Section {
                Text("© 2026 lifedever. All rights reserved.")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
