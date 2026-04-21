import SwiftUI
import SwiftData
import ServiceManagement
import Carbon

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label(L10n.tr("settings.general"), systemImage: "gear") }
            PreferencesTab()
                .tabItem { Label(L10n.tr("settings.preferences"), systemImage: "slider.horizontal.3") }
            ShortcutsTab()
                .tabItem { Label(L10n.tr("settings.shortcuts"), systemImage: "keyboard") }
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
            SponsorTab()
                .tabItem { Label(L10n.tr("settings.sponsor"), systemImage: "heart") }
            AboutTab()
                .tabItem { Label(L10n.tr("settings.about"), systemImage: "info.circle") }
        }
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
        .localized()
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("menuBarIconStyle") private var menuBarIconStyle = "outline"
    @ObservedObject private var languageManager = LanguageManager.shared
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("hideDockIcon") private var hideDockIcon = false
    @State private var showHideDockConfirm = false
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
                Toggle(L10n.tr("settings.hideDockIcon"), isOn: Binding(
                    get: { hideDockIcon },
                    set: { newValue in
                        if newValue {
                            showHideDockConfirm = true
                        } else {
                            hideDockIcon = false
                            NSApp.setActivationPolicy(.regular)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                ))
                .alert(L10n.tr("settings.hideDockIcon.confirm.title"), isPresented: $showHideDockConfirm) {
                    Button(L10n.tr("settings.hideDockIcon.confirm.ok")) {
                        hideDockIcon = true
                        for window in NSApp.windows where window.isVisible && window.canBecomeMain {
                            window.close()
                        }
                        NSApp.setActivationPolicy(.accessory)
                    }
                    Button(L10n.tr("action.cancel"), role: .cancel) {}
                } message: {
                    Text(L10n.tr("settings.hideDockIcon.confirm.message"))
                }
                Text(L10n.tr("settings.hideDockIcon.hint"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
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

                Picker(L10n.tr("settings.menuBarIconStyle"), selection: $menuBarIconStyle) {
                    Label {
                        Text(L10n.tr("settings.menuBarIconStyle.outline"))
                    } icon: {
                        if let img = PasteMemoApp.menuBarIconPreview(filled: false) {
                            Image(nsImage: img)
                        }
                    }
                    .tag("outline")
                    Label {
                        Text(L10n.tr("settings.menuBarIconStyle.filled"))
                    } icon: {
                        if let img = PasteMemoApp.menuBarIconPreview(filled: true) {
                            Image(nsImage: img)
                        }
                    }
                    .tag("filled")
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

struct ShortcutsTab: View {
    @ObservedObject private var hotkeyManager = HotkeyManager.shared
    @AppStorage("hotkeyKeyCode") private var hotkeyKeyCode = 0x09
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = cmdKey | shiftKey
    @AppStorage("managerHotkeyKeyCode") private var managerKeyCode = -1
    @AppStorage("managerHotkeyModifiers") private var managerModifiers = -1
    @AppStorage("managerHotkeyGlobalEnabled") private var managerHotkeyGlobalEnabled = true
    @AppStorage("relayHotkeyKeyCode") private var relayKeyCode = -1
    @AppStorage("relayHotkeyModifiers") private var relayModifiers = -1
    @AppStorage("doubleTapEnabled") private var doubleTapEnabled = false
    @AppStorage("doubleTapModifier") private var doubleTapModifier = 0

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
                    HStack(spacing: 6) {
                        Text(L10n.tr("settings.managerShortcut.global"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Toggle("", isOn: $managerHotkeyGlobalEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .fixedSize()
                            .onChange(of: managerHotkeyGlobalEnabled) {
                                hotkeyManager.updateManagerHotkeyGlobalEnabled(managerHotkeyGlobalEnabled)
                            }
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

                Text(L10n.tr("settings.managerShortcut.scopeHint"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)

                HStack {
                    Text(L10n.tr("settings.relayShortcut"))
                    Spacer()
                    if hotkeyManager.isRelayCleared {
                        Text(L10n.tr("settings.shortcut.none"))
                            .foregroundStyle(.tertiary)
                            .font(.callout)
                    }
                    ShortcutRecorder(keyCode: $relayKeyCode, modifiers: $relayModifiers, onChanged: applyRelayShortcut)
                        .frame(width: 140, height: 24)
                    Button {
                        hotkeyManager.clearRelayShortcut()
                        relayKeyCode = -1
                        relayModifiers = -1
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
        }
        .formStyle(.grouped)
    }

    private func applyShortcut() {
        HotkeyManager.shared.updateShortcut(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
    }

    private func applyManagerShortcut() {
        HotkeyManager.shared.updateManagerShortcut(keyCode: managerKeyCode, modifiers: managerModifiers)
    }

    private func applyRelayShortcut() {
        HotkeyManager.shared.updateRelayShortcut(keyCode: relayKeyCode, modifiers: relayModifiers)
    }
}

// MARK: - Preferences Tab

struct PreferencesTab: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("retentionDays") private var retentionDays = 90
    @State private var pendingRetentionOldDays = 0
    @State private var pendingExpiredCount = 0
    @State private var showRetentionCleanConfirm = false
    @AppStorage("quickPanelAutoPaste") private var quickPanelAutoPaste = true
    @AppStorage("addNewLineAfterPaste") private var addNewLineAfterPaste = false
    @AppStorage("clipboardMonitoringEnabled") private var clipboardMonitoringEnabled = true
    @AppStorage("showLinkURL") private var showLinkURL = false
    @AppStorage("webPreviewEnabled") private var webPreviewEnabled = true
    @AppStorage("imageLinkPreviewEnabled") private var imageLinkPreviewEnabled = true
    @AppStorage(QuickPanelSettings.launchAnimationEnabledKey) private var quickPanelLaunchAnimationEnabled = true
    @AppStorage(QuickPanelSettings.secondaryRowKey) private var quickPanelSecondaryRow = QuickPanelSecondaryRow.types.rawValue
    @AppStorage(QuickPanelPositionSettings.modeKey) private var quickPanelPositionMode = QuickPanelPositionMode.screenCenter.rawValue
    @AppStorage(QuickPanelPositionSettings.screenTargetKey) private var quickPanelScreenTarget = QuickPanelScreenTarget.active.rawValue
    @AppStorage(QuickPanelPositionSettings.specifiedScreenIDKey) private var quickPanelSpecifiedScreenID = ""
    private let allRetentionOptions = [1, 3, 7, 14, 30, 60, 90, 180, 365]

    private var availableOptions: [Int] { allRetentionOptions }

    private var showForever: Bool { true }
    private var screenOptions: [ScreenOption] { ScreenLocator.options() }
    private var currentPositionMode: QuickPanelPositionMode {
        QuickPanelPositionMode(rawValue: quickPanelPositionMode) ?? .remembered
    }
    private var currentScreenTarget: QuickPanelScreenTarget {
        QuickPanelScreenTarget(rawValue: quickPanelScreenTarget) ?? .active
    }

    var body: some View {
        Form {
            Section(L10n.tr("settings.display")) {
                Picker(L10n.tr("settings.quickPanelSecondaryRow"), selection: $quickPanelSecondaryRow) {
                    ForEach(QuickPanelSecondaryRow.allCases, id: \.rawValue) { option in
                        Text(L10n.tr(option.titleKey)).tag(option.rawValue)
                    }
                }
                HStack {
                    Text(L10n.tr("settings.quickPanelPosition"))
                    Spacer()
                    Menu {
                        positionMenuItem(
                            title: L10n.tr(QuickPanelPositionMode.cursor.titleKey),
                            isSelected: currentPositionMode == .cursor
                        ) {
                            selectQuickPanelPosition(.cursor)
                        }

                        positionMenuItem(
                            title: L10n.tr(QuickPanelPositionMode.menuBarIcon.titleKey),
                            isSelected: currentPositionMode == .menuBarIcon
                        ) {
                            selectQuickPanelPosition(.menuBarIcon)
                        }

                        positionMenuItem(
                            title: L10n.tr(QuickPanelPositionMode.windowCenter.titleKey),
                            isSelected: currentPositionMode == .windowCenter
                        ) {
                            selectQuickPanelPosition(.windowCenter)
                        }

                        Menu(L10n.tr(QuickPanelPositionMode.screenCenter.titleKey)) {
                            positionMenuItem(
                                title: L10n.tr("settings.quickPanelTargetScreen.active"),
                                isSelected: currentPositionMode == .screenCenter && currentScreenTarget == .active
                            ) {
                                selectQuickPanelPosition(.screenCenter, screenTarget: .active)
                            }

                            ForEach(screenOptions) { screen in
                                positionMenuItem(
                                    title: screen.name,
                                    isSelected: currentPositionMode == .screenCenter
                                        && currentScreenTarget == .specified
                                        && quickPanelSpecifiedScreenID == screen.id
                                ) {
                                    selectQuickPanelPosition(.screenCenter, screenTarget: .specified, screenID: screen.id)
                                }
                            }
                        }

                        positionMenuItem(
                            title: L10n.tr(QuickPanelPositionMode.remembered.titleKey),
                            isSelected: currentPositionMode == .remembered
                        ) {
                            selectQuickPanelPosition(.remembered)
                        }
                    } label: {
                        Text(currentPositionTitle)
                            .foregroundStyle(.primary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            Section(L10n.tr("settings.behavior")) {
                Toggle(L10n.tr("settings.clipboardMonitoring"), isOn: $clipboardMonitoringEnabled)
                Toggle(L10n.tr("settings.autoPaste"), isOn: $quickPanelAutoPaste)
                Toggle(L10n.tr("settings.addNewLine"), isOn: $addNewLineAfterPaste)
                Toggle(L10n.tr("settings.quickPanelLaunchAnimation"), isOn: $quickPanelLaunchAnimationEnabled)
                Toggle(L10n.tr("settings.showLinkURL"), isOn: $showLinkURL)
                Toggle(L10n.tr("settings.webPreview"), isOn: $webPreviewEnabled)
                Toggle(L10n.tr("settings.imageLinkPreview"), isOn: $imageLinkPreviewEnabled)
            }

            OCRSettingsSection()

            Section(L10n.tr("settings.history")) {
                Picker(L10n.tr("settings.retentionDays"), selection: $retentionDays) {
                    if showForever {
                        Text(L10n.tr("settings.retentionDays.forever")).tag(0)
                    }
                    ForEach(availableOptions, id: \.self) { days in
                        Text(L10n.tr("settings.retentionDays.days", days)).tag(days)
                    }
                }
                .onChange(of: retentionDays) { oldValue, newValue in
                    prepareRetentionCleanup(oldDays: oldValue, newDays: newValue)
                }
            }
        }
        .formStyle(.grouped)
        .alert(
            L10n.tr("settings.retentionDays.cleanConfirm", pendingExpiredCount),
            isPresented: $showRetentionCleanConfirm
        ) {
            Button(L10n.tr("action.delete"), role: .destructive) {
                // Defer deletion to next run loop iteration — the alert sheet close
                // animation triggers a layout pass that would access zombie SwiftData objects
                DispatchQueue.main.async {
                    executeRetentionCleanup()
                }
            }
            Button(L10n.tr("action.cancel"), role: .cancel) {
                retentionDays = pendingRetentionOldDays
            }
        } message: {
            Text(L10n.tr("settings.retentionDays.cleanWarning"))
        }
        .onAppear {
            ensureSpecifiedScreenSelection()
        }
        .onChange(of: quickPanelPositionMode) {
            ensureSpecifiedScreenSelection()
        }
        .onChange(of: quickPanelScreenTarget) {
            ensureSpecifiedScreenSelection()
        }
    }

    private func prepareRetentionCleanup(oldDays: Int, newDays: Int) {
        guard newDays > 0, (oldDays == 0 || newDays < oldDays) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -newDays, to: Date())!
        let descriptor = FetchDescriptor<ClipItem>()
        guard let allItems = try? modelContext.fetch(descriptor) else { return }
        let preservedGroupNames = SmartGroupRetention.preservedGroupNames(in: modelContext)
        let count = allItems.filter {
            $0.createdAt < cutoff
                && !$0.isPinned
                && !SmartGroupRetention.shouldPreserve(item: $0, preservedGroupNames: preservedGroupNames)
        }.count
        guard count > 0 else { return }

        pendingRetentionOldDays = oldDays
        pendingExpiredCount = count
        showRetentionCleanConfirm = true
    }

    private func executeRetentionCleanup() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!
        let descriptor = FetchDescriptor<ClipItem>()
        guard let allItems = try? modelContext.fetch(descriptor) else { return }
        let preservedGroupNames = SmartGroupRetention.preservedGroupNames(in: modelContext)
        let expiredItems = allItems.filter {
            $0.createdAt < cutoff
                && !$0.isPinned
                && !SmartGroupRetention.shouldPreserve(item: $0, preservedGroupNames: preservedGroupNames)
        }
        guard !expiredItems.isEmpty else { return }

        for item in expiredItems {
            if let groupName = item.groupName, !groupName.isEmpty {
                ClipboardManager.shared.decrementSmartGroup(name: groupName, context: modelContext)
            }
        }
        ClipItemStore.deleteAndNotify(expiredItems, from: modelContext)
    }

    private func ensureSpecifiedScreenSelection() {
        guard currentScreenTarget == .specified else { return }
        guard ScreenLocator.screen(for: quickPanelSpecifiedScreenID) == nil else { return }
        quickPanelSpecifiedScreenID = screenOptions.first?.id ?? ""
    }

    private var currentPositionTitle: String {
        switch currentPositionMode {
        case .remembered:
            return L10n.tr(QuickPanelPositionMode.remembered.titleKey)
        case .cursor:
            return L10n.tr(QuickPanelPositionMode.cursor.titleKey)
        case .menuBarIcon:
            return L10n.tr(QuickPanelPositionMode.menuBarIcon.titleKey)
        case .windowCenter:
            return L10n.tr(QuickPanelPositionMode.windowCenter.titleKey)
        case .screenCenter:
            switch currentScreenTarget {
            case .active:
                return "\(L10n.tr(QuickPanelPositionMode.screenCenter.titleKey)) (\(L10n.tr("settings.quickPanelTargetScreen.active")))"
            case .specified:
                let screenName = screenOptions.first(where: { $0.id == quickPanelSpecifiedScreenID })?.name
                    ?? L10n.tr("settings.quickPanelSpecifiedScreen")
                return "\(L10n.tr(QuickPanelPositionMode.screenCenter.titleKey)) (\(screenName))"
            }
        }
    }

    @ViewBuilder
    private func positionMenuItem(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func selectQuickPanelPosition(
        _ mode: QuickPanelPositionMode,
        screenTarget: QuickPanelScreenTarget = .active,
        screenID: String? = nil
    ) {
        quickPanelPositionMode = mode.rawValue

        if mode == .screenCenter {
            quickPanelScreenTarget = screenTarget.rawValue
            if screenTarget == .specified {
                quickPanelSpecifiedScreenID = screenID ?? screenOptions.first?.id ?? ""
            }
        }
    }
}

struct OCRSettingsSection: View {
    @AppStorage(OCRTaskCoordinator.enableOCRKey) private var ocrEnabled = true
    @AppStorage(OCRTaskCoordinator.autoOCRKey) private var autoProcess = true
    @ObservedObject private var coordinator = OCRTaskCoordinator.shared

    var body: some View {
        Section(L10n.tr("settings.ocr")) {
            Toggle(L10n.tr("settings.ocr.enable"), isOn: $ocrEnabled)
            if ocrEnabled {
                Toggle(L10n.tr("settings.ocr.auto"), isOn: $autoProcess)

                if coordinator.isScanning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(coordinator.scanCompleted), total: Double(max(coordinator.scanTotal, 1)))
                        Text("\(coordinator.scanCompleted) / \(coordinator.scanTotal)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(L10n.tr("settings.ocr.scanExisting")) {
                        OCRTaskCoordinator.shared.scanExistingImages()
                    }
                    .pointerCursor()
                }

                Text(L10n.tr("settings.ocr.hint"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
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
    @AppStorage(UsageTracker.ANALYTICS_ENABLED_KEY) private var analyticsEnabled = true

    var body: some View {
        Form {
            Section(L10n.tr("settings.privacy.sensitive")) {
                Toggle(L10n.tr("settings.privacy.sensitiveDetection"), isOn: $isSensitiveDetectionEnabled)
                Text(L10n.tr("settings.privacy.sensitiveHint"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            IgnoredAppsSection()

            Section(L10n.tr("settings.privacy.analytics")) {
                Toggle(L10n.tr("settings.privacy.analyticsToggle"), isOn: $analyticsEnabled)
                Text(L10n.tr("settings.privacy.analyticsHint"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
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
    private var enabledCount: Int { rules.filter(\.enabled).count }

    var body: some View {
        Form {
            automationContent
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

}

// MARK: - Pro Tab

struct SponsorTab: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "heart.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.pink)

                    Text(L10n.tr("sponsor.title"))
                        .font(.headline)

                    Text(L10n.tr("sponsor.desc"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                Link(destination: URL(string: "https://www.lifedever.com")!) {
                    Label(L10n.tr("sponsor.donate"), systemImage: "cup.and.saucer")
                }
                Link(destination: URL(string: "https://github.com/lifedever/PasteMemo-app")!) {
                    Label(L10n.tr("sponsor.star"), systemImage: "star")
                }
                Link(destination: URL(string: "https://github.com/lifedever/PasteMemo-app/issues")!) {
                    Label(L10n.tr("sponsor.feedback"), systemImage: "bubble.left")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - About Tab

struct AboutTab: View {
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @AppStorage("updateCheckInterval") private var updateCheckInterval = 24

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
                Toggle(L10n.tr("settings.autoCheckUpdates"), isOn: $autoCheckUpdates)
                    .onChange(of: autoCheckUpdates) {
                        if autoCheckUpdates {
                            updateChecker.startPeriodicChecks()
                        } else {
                            updateChecker.stopPeriodicChecks()
                        }
                    }
                if autoCheckUpdates {
                    Picker(L10n.tr("settings.updateCheckInterval"), selection: $updateCheckInterval) {
                        Text(L10n.tr("settings.updateCheckInterval.6h")).tag(6)
                        Text(L10n.tr("settings.updateCheckInterval.12h")).tag(12)
                        Text(L10n.tr("settings.updateCheckInterval.24h")).tag(24)
                        Text(L10n.tr("settings.updateCheckInterval.72h")).tag(72)
                    }
                    .onChange(of: updateCheckInterval) {
                        updateChecker.startPeriodicChecks()
                    }
                }
            }

            Section {
                Link(L10n.tr("about.website"), destination: URL(string: "https://www.lifedever.com/PasteMemo/")!)
                Link(L10n.tr("about.help"), destination: URL(string: "https://www.lifedever.com/PasteMemo/help/")!)
                Link(L10n.tr("menu.reportIssue"), destination: URL(string: "https://github.com/lifedever/PasteMemo-app/issues")!)
            }

            Section {
                HStack {
                    Text(L10n.tr("about.license"))
                    Spacer()
                    Text("GPL-3.0")
                        .foregroundStyle(.secondary)
                }
                Link(L10n.tr("about.sourceCode"), destination: URL(string: "https://github.com/lifedever/PasteMemo-app")!)
            }

            Section {
                Text("© 2026 lifedever.")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
