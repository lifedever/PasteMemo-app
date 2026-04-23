import SwiftUI
import SwiftData
import UserNotifications

struct AutomationRuleEditorView: View {
    @Bindable var rule: AutomationRule
    @Environment(\.modelContext) private var modelContext
    @State private var isEditing = false
    @State private var draftName = ""
    @State private var draftConditions: [IdentifiedCondition] = []
    @State private var draftActions: [IdentifiedAction] = []
    @State private var draftConditionLogic: ConditionLogic = .all
    @State private var shortcutPickerIndex: Int? = nil

    private var isBuiltIn: Bool { rule.isBuiltIn }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isEditing {
                    editNameSection
                    editConditionsSection
                    editActionsSection
                    editButtonsSection
                } else {
                    enabledHeaderSection
                    viewConditionsSection
                    viewActionsSection
                    settingsSection
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: rule.ruleID) {
            isEditing = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .automationEnterEdit)) { _ in
            if !isBuiltIn { enterEditMode() }
        }
    }

    // MARK: - View Mode

    /// Rule-level on/off stays at the top of the editor so it's the first
    /// thing you see. The subtitle shows both state and trigger mode so a
    /// glance tells you "on + manual only" vs "on + auto" vs "off".
    private var enabledHeaderSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { rule.enabled },
                set: { newValue in
                    if newValue {
                        guard validateRule() else { return }
                    }
                    rule.enabled = newValue
                    saveSettings()
                }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: rule.enabled
                          ? "checkmark.circle.fill"
                          : "circle")
                        .foregroundStyle(rule.enabled ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.tr("automation.rule.enabled"))
                        Text(enabledStatusSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var enabledStatusSubtitle: String {
        guard rule.enabled else {
            return L10n.tr("automation.rule.status.inactive")
        }
        let triggerLabel: String
        switch rule.triggerMode {
        case .automatic: triggerLabel = L10n.tr("automation.rule.triggerMode.automatic")
        case .manual: triggerLabel = L10n.tr("automation.rule.triggerMode.manual")
        }
        return L10n.tr("automation.rule.status.active") + " · " + triggerLabel
    }

    private var viewConditionsSection: some View {
        Section {
            if rule.conditions.isEmpty {
                Text(L10n.tr("automation.condition.empty")).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(rule.conditions.enumerated()), id: \.offset) { _, c in
                    conditionLabel(c)
                }
            }
        } header: {
            conditionSectionHeader
        }
    }

    private var conditionSectionHeader: some View {
        HStack(spacing: 4) {
            Text(L10n.tr("automation.condition.title.prefix"))
            Picker("", selection: Binding(
                get: { rule.conditionLogic },
                set: { rule.conditionLogic = $0; saveSettings() }
            )) {
                Text(L10n.tr("automation.condition.logic.all")).tag(ConditionLogic.all)
                Text(L10n.tr("automation.condition.logic.any")).tag(ConditionLogic.any)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(isBuiltIn || !isEditing)
            Text(L10n.tr("automation.condition.title.suffix"))
        }
    }

    private var viewActionsSection: some View {
        Section(L10n.tr("automation.action.title")) {
            if rule.actions.isEmpty {
                Text(L10n.tr("automation.action.empty")).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(rule.actions.enumerated()), id: \.offset) { _, a in
                    actionLabel(a)
                }
            }
        }
    }

    private var settingsSection: some View {
        Section(L10n.tr("automation.editor.triggerAndNotification")) {
            Picker(L10n.tr("automation.rule.triggerMode"), selection: Binding(
                get: { rule.triggerMode },
                set: { rule.triggerMode = $0; saveSettings() }
            )) {
                Text(L10n.tr("automation.rule.triggerMode.automatic")).tag(TriggerMode.automatic)
                Text(L10n.tr("automation.rule.triggerMode.manual")).tag(TriggerMode.manual)
            }
            .disabled(isBuiltIn)

            if rule.triggerMode != .manual {
                Toggle(L10n.tr("automation.rule.notifyBeforeApply"), isOn: Binding(
                    get: { rule.notifyBeforeApply },
                    set: { rule.notifyBeforeApply = $0; saveSettings() }
                ))
            }

            Toggle(L10n.tr("automation.rule.notifyOnTrigger"), isOn: Binding(
                get: { rule.notifyOnTrigger },
                set: { newValue in
                    rule.notifyOnTrigger = newValue
                    saveSettings()
                    if newValue {
                        requestNotificationPermission { granted in
                            guard !granted else { return }
                            Task { @MainActor in
                                rule.notifyOnTrigger = false
                                saveSettings()
                            }
                        }
                    }
                }
            ))
        }
    }

    // MARK: - Edit Mode

    private var editNameSection: some View {
        Section {
            LabeledContent(L10n.tr("automation.rule.name")) {
                TextField("", text: $draftName)
            }
        }
    }

    private var editButtonsSection: some View {
        Section {
        } footer: {
            HStack(spacing: 12) {
                Spacer()
                Button(L10n.tr("automation.editor.cancel")) { cancelEdit() }
                    .buttonStyle(.bordered)
                Button(L10n.tr("automation.editor.save")) { saveEdit() }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
    }

    private var editConditionSectionHeader: some View {
        HStack(spacing: 4) {
            Text(L10n.tr("automation.condition.title.prefix"))
            Picker("", selection: $draftConditionLogic) {
                Text(L10n.tr("automation.condition.logic.all")).tag(ConditionLogic.all)
                Text(L10n.tr("automation.condition.logic.any")).tag(ConditionLogic.any)
            }
            .pickerStyle(.menu)
            .fixedSize()
            Text(L10n.tr("automation.condition.title.suffix"))
        }
    }

    private var editConditionsSection: some View {
        Section {
            ForEach(draftConditions) { item in
                if let index = draftConditions.firstIndex(where: { $0.id == item.id }) {
                    editConditionRow(item.value, at: index)
                }
            }
            .onMove { draftConditions.move(fromOffsets: $0, toOffset: $1) }
        } header: {
            editConditionSectionHeader
        } footer: {
            addConditionMenu
        }
    }

    private var editActionsSection: some View {
        Section {
            ForEach(draftActions) { item in
                if let index = draftActions.firstIndex(where: { $0.id == item.id }) {
                    editActionRow(item.value, at: index)
                }
            }
            .onMove { draftActions.move(fromOffsets: $0, toOffset: $1) }
        } header: {
            Text(L10n.tr("automation.action.title"))
        } footer: {
            addActionMenu
        }
    }

    // MARK: - Add Menus (inside card)

    private var addConditionMenu: some View {
        HStack {
            Menu(L10n.tr("automation.condition.add")) {
                Button(L10n.tr("automation.condition.contentType")) { draftConditions.append(IdentifiedCondition(value: .contentType(.text))) }
                Button(L10n.tr("automation.condition.anyText")) { draftConditions.append(IdentifiedCondition(value: .anyText)) }
                Button(L10n.tr("automation.condition.regexMatch")) { draftConditions.append(IdentifiedCondition(value: .regexMatch(pattern: ""))) }
                Button(L10n.tr("automation.condition.containsText")) { draftConditions.append(IdentifiedCondition(value: .containsText(text: ""))) }
                Button(L10n.tr("automation.condition.sourceApp")) { draftConditions.append(IdentifiedCondition(value: .sourceApp(bundleIDs: []))) }
            }
            .fixedSize()
            Spacer()
        }
    }

    private var addActionMenu: some View {
        HStack {
        Menu(L10n.tr("automation.action.add")) {
            Section(L10n.tr("automation.action.section.external")) {
                Button(L10n.tr("automation.action.runShortcut")) {
                    draftActions.append(IdentifiedAction(value: .runShortcut(name: "")))
                }
            }
            Section(L10n.tr("automation.action.section.text")) {
                Button(L10n.tr("automation.action.lowercased")) { draftActions.append(IdentifiedAction(value: .lowercased)) }
                Button(L10n.tr("automation.action.uppercased")) { draftActions.append(IdentifiedAction(value: .uppercased)) }
                Button(L10n.tr("automation.action.trimWhitespace")) { draftActions.append(IdentifiedAction(value: .trimWhitespace)) }
                Button(L10n.tr("automation.action.removeBlankLines")) { draftActions.append(IdentifiedAction(value: .removeBlankLines)) }
                Button(L10n.tr("automation.action.stripRichText")) { draftActions.append(IdentifiedAction(value: .stripRichText)) }
            }
            Section(L10n.tr("automation.action.section.url")) {
                Button(L10n.tr("automation.action.urlEncode")) { draftActions.append(IdentifiedAction(value: .urlEncode)) }
                Button(L10n.tr("automation.action.urlDecode")) { draftActions.append(IdentifiedAction(value: .urlDecode)) }
                Button(L10n.tr("automation.action.removeQueryParams")) { draftActions.append(IdentifiedAction(value: .removeQueryParams(patterns: ["utm_*"]))) }
            }
            Section(L10n.tr("automation.action.section.advanced")) {
                Button(L10n.tr("automation.action.regexReplace")) { draftActions.append(IdentifiedAction(value: .regexReplace(pattern: "", replacement: ""))) }
                Button(L10n.tr("automation.action.addPrefix")) { draftActions.append(IdentifiedAction(value: .addPrefix(text: ""))) }
                Button(L10n.tr("automation.action.addSuffix")) { draftActions.append(IdentifiedAction(value: .addSuffix(text: ""))) }
            }
            Section(L10n.tr("automation.action.section.clipboard")) {
                Button(L10n.tr("automation.action.markSensitive")) { draftActions.append(IdentifiedAction(value: .markSensitive)) }
                Button(L10n.tr("automation.action.pin")) { draftActions.append(IdentifiedAction(value: .pin)) }
                Button(L10n.tr("automation.action.skipCapture")) { draftActions.append(IdentifiedAction(value: .skipCapture)) }
                Button(L10n.tr("automation.action.assignGroup")) { draftActions.append(IdentifiedAction(value: .assignGroup(name: ""))) }
            }
        }
        .fixedSize()
            Spacer()
        }
    }

    // MARK: - Condition Label (view mode)

    @ViewBuilder
    private func conditionLabel(_ condition: RuleCondition) -> some View {
        switch condition {
        case .contentType(let type):
            LabeledContent(L10n.tr("automation.condition.contentType")) { Text(type.label) }
        case .anyText:
            Text(L10n.tr("automation.condition.anyText"))
        case .regexMatch(let pattern):
            LabeledContent(L10n.tr("automation.condition.regexMatch")) {
                Text(pattern).textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
            }
        case .containsText(let text):
            LabeledContent(L10n.tr("automation.condition.containsText")) { Text(text) }
        case .sourceApp(let bundleIDs):
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("automation.condition.sourceApp"))
                ForEach(bundleIDs, id: \.self) { bid in
                    HStack(spacing: 6) {
                        appIcon(for: bid)
                        Text(appName(for: bid))
                    }
                }
            }
        }
    }

    // MARK: - Action Label (view mode)

    @ViewBuilder
    private func actionLabel(_ action: RuleAction) -> some View {
        switch action {
        case .lowercased: Text(L10n.tr("automation.action.lowercased"))
        case .uppercased: Text(L10n.tr("automation.action.uppercased"))
        case .trimWhitespace: Text(L10n.tr("automation.action.trimWhitespace"))
        case .removeBlankLines: Text(L10n.tr("automation.action.removeBlankLines"))
        case .stripRichText: Text(L10n.tr("automation.action.stripRichText"))
        case .urlEncode: Text(L10n.tr("automation.action.urlEncode"))
        case .urlDecode: Text(L10n.tr("automation.action.urlDecode"))
        case .removeQueryParams(let p):
            LabeledContent(L10n.tr("automation.action.removeQueryParams")) {
                Text(p.joined(separator: ", ")).font(.system(.caption, design: .monospaced))
            }
        case .regexReplace(let p, let r):
            LabeledContent(L10n.tr("automation.action.regexReplace")) {
                Text("\(p) → \(r)").font(.system(.caption, design: .monospaced))
            }
        case .addPrefix(let t):
            LabeledContent(L10n.tr("automation.action.addPrefix")) { Text(t) }
        case .addSuffix(let t):
            LabeledContent(L10n.tr("automation.action.addSuffix")) { Text(t) }
        case .assignGroup(let name):
            LabeledContent(L10n.tr("automation.action.assignGroup")) {
                let group = (try? modelContext.fetch(FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == name })))?.first
                Label(name, systemImage: group?.icon ?? "folder")
            }
        case .markSensitive:
            Text(L10n.tr("automation.action.markSensitive"))
        case .pin:
            Text(L10n.tr("automation.action.pin"))
        case .skipCapture:
            Text(L10n.tr("automation.action.skipCapture"))
        case .runShortcut(let name):
            LabeledContent(L10n.tr("automation.action.runShortcut")) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text(name.isEmpty ? L10n.tr("automation.action.runShortcut.empty") : name)
                        .foregroundStyle(name.isEmpty ? .tertiary : .primary)
                }
            }
        }
    }

    // MARK: - Edit Condition Row

    @ViewBuilder
    private func editConditionRow(_ condition: RuleCondition, at index: Int) -> some View {
        if case .sourceApp(let bundleIDs) = condition {
            editSourceAppRow(bundleIDs: bundleIDs, at: index)
        } else {
            HStack {
                switch condition {
                case .contentType(let type):
                    Picker(L10n.tr("automation.condition.contentType"), selection: Binding(
                        get: { type },
                        set: { draftConditions[index].value = .contentType($0) }
                    )) {
                        ForEach(ClipContentType.ruleEditorVisibleCases, id: \.self) { t in
                            Text(t.label).tag(t)
                        }
                    }
                case .anyText:
                    Text(L10n.tr("automation.condition.anyText"))
                        .foregroundStyle(.secondary)
                case .regexMatch(let pattern):
                    TextField(L10n.tr("automation.condition.regexMatch"), text: Binding(
                        get: { pattern },
                        set: { draftConditions[index].value = .regexMatch(pattern: $0) }
                    ), prompt: Text(L10n.tr("automation.condition.regexMatch.placeholder")))
                    .font(.system(.body, design: .monospaced))
                case .containsText(let text):
                    TextField(L10n.tr("automation.condition.containsText"), text: Binding(
                        get: { text },
                        set: { draftConditions[index].value = .containsText(text: $0) }
                    ), prompt: Text(L10n.tr("automation.condition.containsText.placeholder")))
                default:
                    EmptyView()
                }
                Spacer()
                Button { draftConditions.remove(at: index) } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func editSourceAppRow(bundleIDs: [String], at index: Int) -> some View {
        VStack(alignment: .leading, spacing: bundleIDs.isEmpty ? 6 : 12) {
            HStack {
                Text(L10n.tr("automation.condition.sourceApp"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { draftConditions.remove(at: index) } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 6) {
            ForEach(bundleIDs, id: \.self) { bid in
                HStack(spacing: 6) {
                    appIcon(for: bid)
                    Text(appName(for: bid))
                    Spacer()
                    Button {
                        var ids = bundleIDs
                        ids.removeAll { $0 == bid }
                        draftConditions[index].value = .sourceApp(bundleIDs: ids)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary.opacity(0.5))
                    }
                    .buttonStyle(.borderless)
                }
            }
            }
            Button(L10n.tr("automation.condition.sourceApp.add")) {
                browseForApp(at: index, existing: bundleIDs)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    // MARK: - Edit Action Row

    @ViewBuilder
    private func editActionRow(_ action: RuleAction, at index: Int) -> some View {
        HStack {
            switch action {
            case .lowercased: Text(L10n.tr("automation.action.lowercased"))
            case .uppercased: Text(L10n.tr("automation.action.uppercased"))
            case .trimWhitespace: Text(L10n.tr("automation.action.trimWhitespace"))
            case .removeBlankLines: Text(L10n.tr("automation.action.removeBlankLines"))
            case .stripRichText: Text(L10n.tr("automation.action.stripRichText"))
            case .urlEncode: Text(L10n.tr("automation.action.urlEncode"))
            case .urlDecode: Text(L10n.tr("automation.action.urlDecode"))
            case .removeQueryParams(let patterns):
                TextField(L10n.tr("automation.action.removeQueryParams"), text: Binding(
                    get: { patterns.joined(separator: ", ") },
                    set: { draftActions[index].value = .removeQueryParams(patterns: $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
                ), prompt: Text(L10n.tr("automation.action.removeQueryParams.placeholder")))
                .font(.system(.body, design: .monospaced))
            case .regexReplace(let pattern, let replacement):
                TextField(L10n.tr("automation.action.regexReplace"), text: Binding(
                    get: { pattern },
                    set: { draftActions[index].value = .regexReplace(pattern: $0, replacement: replacement) }
                ), prompt: Text(L10n.tr("automation.action.regexReplace.placeholder")))
                .font(.system(.body, design: .monospaced))
                TextField(L10n.tr("automation.action.regexReplace.to"), text: Binding(
                    get: { replacement },
                    set: { draftActions[index].value = .regexReplace(pattern: pattern, replacement: $0) }
                ), prompt: Text(L10n.tr("automation.action.regexReplace.to.placeholder")))
                .font(.system(.body, design: .monospaced))
            case .addPrefix(let text):
                TextField(L10n.tr("automation.action.addPrefix"), text: Binding(
                    get: { text },
                    set: { draftActions[index].value = .addPrefix(text: $0) }
                ), prompt: Text(L10n.tr("automation.action.addPrefix.placeholder")))
            case .addSuffix(let text):
                TextField(L10n.tr("automation.action.addSuffix"), text: Binding(
                    get: { text },
                    set: { draftActions[index].value = .addSuffix(text: $0) }
                ), prompt: Text(L10n.tr("automation.action.addSuffix.placeholder")))
            case .assignGroup(let name):
                Text(L10n.tr("automation.action.assignGroup"))
                Spacer()
                Picker("", selection: Binding(
                    get: { name },
                    set: { draftActions[index].value = .assignGroup(name: $0) }
                )) {
                    let groups = (try? modelContext.fetch(FetchDescriptor<SmartGroup>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
                    ForEach(groups, id: \.name) { group in
                        Label(group.name, systemImage: group.icon).tag(group.name)
                    }
                }
                .fixedSize()
            case .markSensitive:
                Text(L10n.tr("automation.action.markSensitive"))
            case .pin:
                Text(L10n.tr("automation.action.pin"))
            case .skipCapture:
                Text(L10n.tr("automation.action.skipCapture"))
            case .runShortcut(let name):
                TextField(L10n.tr("automation.action.runShortcut"), text: Binding(
                    get: { name },
                    set: { draftActions[index].value = .runShortcut(name: $0) }
                ), prompt: Text(L10n.tr("automation.action.runShortcut.placeholder")))
                Button {
                    shortcutPickerIndex = index
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("automation.action.runShortcut.pick"))
                .popover(isPresented: Binding(
                    get: { shortcutPickerIndex == index },
                    set: { if !$0 { shortcutPickerIndex = nil } }
                )) {
                    ShortcutPickerPopover { picked in
                        draftActions[index].value = .runShortcut(name: picked)
                        shortcutPickerIndex = nil
                    }
                }
                Button {
                    ShortcutRunner.openShortcutInApp(name: name)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(L10n.tr("automation.action.runShortcut.openInApp"))
            }
            Spacer()
            Button { draftActions.remove(at: index) } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Actions

    private func enterEditMode() {
        draftName = rule.name
        draftConditions = rule.conditions.map { IdentifiedCondition(value: $0) }
        draftActions = rule.actions.map { IdentifiedAction(value: $0) }
        draftConditionLogic = rule.conditionLogic
        isEditing = true
    }

    private func cancelEdit() { isEditing = false }

    private func saveEdit() {
        rule.name = draftName
        rule.conditions = draftConditions.map(\.value)
        rule.actions = draftActions.map(\.value)
        rule.conditionLogic = draftConditionLogic
        rule.updatedAt = Date()
        try? modelContext.save()
        isEditing = false
    }

    private func requestNotificationPermission(completion: @Sendable @escaping (Bool) -> Void) {
        guard Bundle.main.bundleIdentifier != nil else {
            completion(false)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                if !granted {
                    let alert = NSAlert()
                    alert.messageText = L10n.tr("automation.notification.permissionDenied")
                    alert.informativeText = L10n.tr("automation.notification.permissionDeniedMessage")
                    alert.addButton(withTitle: L10n.tr("automation.notification.openSettings"))
                    alert.addButton(withTitle: L10n.tr("action.cancel"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                    }
                }
                completion(granted)
            }
        }
    }

    private func validateRule() -> Bool {
        guard !rule.conditions.isEmpty, !rule.actions.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L10n.tr("automation.validation.incomplete")
            alert.informativeText = L10n.tr("automation.validation.incompleteMessage")
            alert.runModal()
            return false
        }
        return true
    }

    private func saveSettings() {
        rule.updatedAt = Date()
        try? modelContext.save()
    }

    // MARK: - App Helpers

    private func appIcon(for bundleID: String) -> some View {
        let icon: NSImage = {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }()
        return Image(nsImage: icon).resizable().frame(width: 20, height: 20)
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    private func browseForApp(at index: Int, existing: [String]) {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("automation.condition.sourceApp.select")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        var ids = existing
        for url in panel.urls {
            if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier, !ids.contains(bid) {
                ids.append(bid)
            }
        }
        draftConditions[index].value = .sourceApp(bundleIDs: ids)
    }
}

// MARK: - Identified Wrappers

struct IdentifiedCondition: Identifiable {
    let id = UUID()
    var value: RuleCondition
}

struct IdentifiedAction: Identifiable {
    let id = UUID()
    var value: RuleAction
}

// MARK: - Shortcut picker popover
//
// Fetches the Shortcuts list fresh every time it's opened, so a Shortcut the
// user just created in Shortcuts.app shows up without relaunching PasteMemo.

private struct ShortcutPickerPopover: View {
    let onPick: (String) -> Void
    @State private var shortcuts: [String] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text(L10n.tr("automation.action.runShortcut.loading"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shortcuts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .foregroundStyle(.tertiary)
                        .font(.title2)
                    Text(L10n.tr("automation.action.runShortcut.empty"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(shortcuts, id: \.self) { name in
                            Button {
                                onPick(name)
                            } label: {
                                HStack {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.purple)
                                        .font(.caption)
                                    Text(name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(width: 260, height: 280)
        .task {
            loading = true
            shortcuts = await ShortcutRunner.listAvailableShortcuts()
            loading = false
        }
    }
}
