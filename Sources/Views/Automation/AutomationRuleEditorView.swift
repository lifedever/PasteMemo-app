import SwiftUI
import SwiftData
import UserNotifications

/// The rule as a vertical flow: 当 (trigger) → 如果 (conditions) → 就 (actions) → 然后 (output),
/// one rail down the left, a node card per step. View mode shows it read-only with the
/// enabled switch in the title row; edit mode swaps controls into the same cards and
/// shows Cancel / Save at the bottom. Edits collect in drafts until Save.
struct AutomationRuleEditorView: View {
    @Bindable var rule: AutomationRule
    @ObservedObject var session: RuleEditorSession
    @Environment(\.modelContext) private var modelContext
    @State private var draftName = ""
    @State private var draftTrigger: TriggerMode = .automatic
    @State private var draftLogic: ConditionLogic = .all
    @State private var draftOutput: RuleOutputMode = .replaceItem
    @State private var draftOutputParam = ""
    @State private var draftNotifyBefore = false
    @State private var draftNotifyOn = false
    @State private var conditions: [IdentifiedCondition] = []
    @State private var actions: [IdentifiedAction] = []
    @State private var shortcutPickerIndex: Int? = nil
    @State private var expandedOverrides: Set<UUID> = []
    @State private var previewInput = ""
    @State private var isEditing = false
    @FocusState private var nameFocused: Bool

    /// Built-in names are L10n keys; the field shows the translation.
    private var displayName: String { rule.isBuiltIn ? L10n.tr(rule.name) : rule.name }

    /// Async actions (Run Shortcut, AI rewrite) and panel-bound ones (Close Quick Panel)
    /// can't run on the capture path — it would silently no-op. Such rules are locked to
    /// manual triggering. (issue #71 review)
    private var ruleRequiresManual: Bool {
        actions.contains { $0.value.requiresManualTrigger }
    }

    private var isDirty: Bool {
        draftName != displayName
            || draftTrigger != rule.triggerMode
            || draftLogic != rule.conditionLogic
            || draftOutput != rule.outputMode
            || draftOutputParam != rule.outputParam
            || draftNotifyBefore != rule.notifyBeforeApply
            || draftNotifyOn != rule.notifyOnTrigger
            || conditions.map(\.value) != rule.conditions
            || actions.map(\.value) != rule.actions
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                titleRow
                timeline
                previewCard
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            if isEditing { saveBar } else { viewBar }
        }
        .onAppear {
            load()
            session.save = { save() }
            session.discard = { load() }
        }
        .onChange(of: rule.ruleID) { load() }
        .onChange(of: isDirty) { _, dirty in session.isDirty = isEditing && dirty }
        .onChange(of: isEditing) { _, editing in session.isDirty = editing && isDirty }
        .onChange(of: actions.map(\.value)) { _, _ in
            // Never leave a manual-only rule on "automatic" where it would silently never fire.
            if ruleRequiresManual { draftTrigger = .manual }
        }
        .onReceive(NotificationCenter.default.publisher(for: .automationEnterEdit)) { _ in
            beginEditing()
        }
    }

    // MARK: - Title row

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            if isEditing {
                TextField(L10n.tr("automation.rule.name"), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($nameFocused)
            } else {
                Text(displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                statusBadge
                Spacer()
                Toggle("", isOn: Binding(
                    get: { rule.enabled },
                    set: { newValue in
                        if newValue {
                            guard validateRule() else { return }
                        }
                        rule.enabled = newValue
                        rule.updatedAt = Date()
                        try? modelContext.save()
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(L10n.tr("automation.rule.enabled"))
            }
        }
    }

    private var statusBadge: some View {
        let on = rule.enabled
        let text = on
            ? L10n.tr("automation.rule.status.active") + " · " + (rule.triggerMode == .automatic
                ? L10n.tr("automation.rule.triggerMode.automatic") : L10n.tr("automation.rule.triggerMode.manual"))
            : L10n.tr("automation.rule.status.inactive")
        return Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15)))
            .foregroundStyle(on ? Color.green : Color.secondary)
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            flowNode(symbol: "bolt.fill", label: L10n.tr("automation.flow.when"), detail: nil, isLast: false) {
                triggerCard
            }
            flowNode(symbol: "line.3.horizontal.decrease", label: L10n.tr("automation.flow.if"),
                     detail: conditionsDetail, isLast: false) {
                conditionsCard
            }
            flowNode(symbol: "play.fill", label: L10n.tr("automation.flow.then"),
                     detail: L10n.tr("automation.flow.inOrder"), isLast: false) {
                actionsCard
            }
            flowNode(symbol: "arrow.down.to.line", label: L10n.tr("automation.flow.finally"), detail: nil, isLast: true) {
                resultCard
            }
        }
    }

    /// One step: icon circle + rail on the left, a small label and the card on the right.
    private func flowNode<Content: View>(symbol: String, label: String, detail: String?, isLast: Bool,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 28, height: 28)
                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let detail {
                        Text("·").foregroundStyle(.quaternary)
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 28)
                content()
                    .padding(.bottom, isLast ? 0 : 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Card chrome shared by every node.
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func cardRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 14)
    }

    private var conditionsDetail: String {
        let logic = isEditing ? draftLogic : rule.conditionLogic
        return L10n.tr(logic == .all ? "automation.flow.allConditions" : "automation.flow.anyCondition")
    }

    // MARK: - Node 1: trigger

    private var triggerCard: some View {
        card {
            if isEditing {
                cardRow {
                    Picker("", selection: $draftTrigger) {
                        Text(L10n.tr("automation.rule.triggerMode.automatic")).tag(TriggerMode.automatic)
                        Text(L10n.tr("automation.rule.triggerMode.manual")).tag(TriggerMode.manual)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(ruleRequiresManual)
                    .fixedSize()
                    Spacer()
                }
                cardRow {
                    Text(triggerHelp)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if draftTrigger == .automatic {
                    rowDivider
                    cardRow {
                        Toggle(L10n.tr("automation.rule.notifyBeforeApply"), isOn: $draftNotifyBefore)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
            } else {
                cardRow {
                    Text(rule.triggerMode == .automatic
                         ? L10n.tr("automation.rule.triggerMode.automatic.help")
                         : L10n.tr("automation.rule.triggerMode.manual.help"))
                }
                if rule.triggerMode == .automatic, rule.notifyBeforeApply {
                    rowDivider
                    cardRow {
                        Text(L10n.tr("automation.rule.notifyBeforeApply"))
                        Spacer()
                        Text(onOff(true)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var triggerHelp: String {
        if ruleRequiresManual { return L10n.tr("automation.rule.triggerMode.shortcutManualOnly") }
        return draftTrigger == .automatic
            ? L10n.tr("automation.rule.triggerMode.automatic.help")
            : L10n.tr("automation.rule.triggerMode.manual.help")
    }

    // MARK: - Node 2: conditions

    private var conditionsCard: some View {
        card {
            if isEditing {
                cardRow {
                    Text(L10n.tr("automation.condition.title.prefix"))
                    Picker("", selection: $draftLogic) {
                        Text(L10n.tr("automation.condition.logic.all")).tag(ConditionLogic.all)
                        Text(L10n.tr("automation.condition.logic.any")).tag(ConditionLogic.any)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    Text(L10n.tr("automation.condition.title.suffix"))
                    Spacer()
                }
                rowDivider
                if conditions.isEmpty {
                    cardRow { Text(L10n.tr("automation.condition.empty")).foregroundStyle(.tertiary) }
                }
                ForEach(Array(conditions.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { rowDivider }
                    cardRow { conditionRow(item.value, at: index) }
                }
                rowDivider
                cardRow { addConditionMenu }
            } else {
                if rule.conditions.isEmpty {
                    cardRow { Text(L10n.tr("automation.condition.empty")).foregroundStyle(.tertiary) }
                }
                ForEach(Array(rule.conditions.enumerated()), id: \.offset) { index, condition in
                    if index > 0 { rowDivider }
                    cardRow { readOnlyCondition(condition) }
                }
            }
        }
    }

    // MARK: - Node 3: actions

    private var actionsCard: some View {
        card {
            if isEditing {
                if actions.isEmpty {
                    cardRow { Text(L10n.tr("automation.action.empty")).foregroundStyle(.tertiary) }
                }
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { rowDivider }
                    cardRow { actionRow(item.value, at: index, editable: true) }
                }
                rowDivider
                cardRow { addActionMenu }
            } else {
                if rule.actions.isEmpty {
                    cardRow { Text(L10n.tr("automation.action.empty")).foregroundStyle(.tertiary) }
                }
                ForEach(Array(rule.actions.enumerated()), id: \.offset) { index, action in
                    if index > 0 { rowDivider }
                    cardRow { actionRow(action, at: index, editable: false) }
                }
            }
        }
    }

    /// Numbered action row; the number says "in order" better than a caption could.
    private func actionRow(_ action: RuleAction, at index: Int, editable: Bool) -> some View {
        let icon = Self.icon(for: action)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(icon.tint)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(icon.tint.opacity(0.15)))
                Image(systemName: icon.name)
                    .foregroundStyle(icon.tint)
                    .frame(width: 16)
                Text(Self.title(for: action))
                    .fontWeight(.medium)
                Spacer()
                if editable {
                    Button { actions.move(fromOffsets: [index], toOffset: index - 1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    Button { actions.move(fromOffsets: [index], toOffset: index + 2) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == actions.count - 1)
                    removeButton { actions.remove(at: index) }
                }
            }
            Group {
                if editable {
                    actionParameters(action, at: index)
                } else {
                    readOnlyParameters(action)
                }
            }
            .padding(.leading, 28)
        }
    }

    // MARK: - Node 4: result

    private var resultCard: some View {
        card {
            if isEditing {
                cardRow {
                    Picker(L10n.tr("automation.rule.outputMode"), selection: $draftOutput) {
                        ForEach(RuleOutputMode.allCases, id: \.self) { mode in
                            Text(L10n.tr("automation.rule.outputMode.\(mode.rawValue)")).tag(mode)
                        }
                    }
                    .fixedSize()
                    Spacer()
                }
                if draftOutput == .saveToFile {
                    cardRow { outputFolderRow }
                } else if draftOutput == .postWebhook {
                    cardRow {
                        TextField("", text: $draftOutputParam,
                                  prompt: Text(L10n.tr("automation.output.webhook.placeholder")))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                    }
                    cardRow {
                        Text(L10n.tr("automation.output.webhook.help"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if draftTrigger == .automatic, draftOutput.mirrorsToPasteboardOnCapture {
                    cardRow {
                        Text(L10n.tr("automation.rule.outputMode.help"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                rowDivider
                cardRow {
                    Toggle(L10n.tr("automation.rule.notifyOnTrigger"), isOn: $draftNotifyOn)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            } else {
                cardRow {
                    Text(L10n.tr("automation.rule.outputMode.\(rule.outputMode.rawValue)"))
                    if rule.outputMode.needsParameter {
                        Spacer()
                        Text(rule.outputParam)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                rowDivider
                cardRow {
                    Text(L10n.tr("automation.rule.notifyOnTrigger"))
                    Spacer()
                    Text(onOff(rule.notifyOnTrigger)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var outputFolderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(draftOutputParam.isEmpty
                 ? L10n.tr("automation.output.folder.empty")
                 : (draftOutputParam as NSString).abbreviatingWithTildeInPath)
                .foregroundStyle(draftOutputParam.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(L10n.tr("automation.output.folder.choose")) { chooseOutputFolder() }
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let current = RuleOutputDelivery.folderURL(from: draftOutputParam) {
            panel.directoryURL = current
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draftOutputParam = url.path
    }

    // MARK: - Preview

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("automation.preview"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            card {
                cardRow {
                    TextField("", text: $previewInput, prompt: Text(L10n.tr("automation.preview.input")), axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .lineLimit(2...6)
                }
                rowDivider
                cardRow {
                    Button(L10n.tr("automation.preview.useClipboard")) {
                        previewInput = NSPasteboard.general.string(forType: .string) ?? ""
                    }
                    .controlSize(.small)
                    Spacer()
                }
                if !previewInput.isEmpty {
                    rowDivider
                    cardRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("automation.preview.output"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(previewOutput)
                                .textSelection(.enabled)
                            if actions.contains(where: { $0.value.isAsync }) {
                                Text(L10n.tr("automation.preview.asyncSkipped"))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bars

    private func beginEditing() {
        load()
        isEditing = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private var viewBar: some View {
        HStack {
            Spacer()
            Button(L10n.tr("automation.editor.edit")) { beginEditing() }
                .keyboardShortcut("e", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            if isDirty {
                Text(L10n.tr("automation.editor.unsaved"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.tr("automation.editor.cancel")) { load() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.tr("automation.editor.save")) { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Load / save

    private func load() {
        draftName = displayName
        draftTrigger = rule.triggerMode
        draftLogic = rule.conditionLogic
        draftOutput = rule.outputMode
        draftOutputParam = rule.outputParam
        draftNotifyBefore = rule.notifyBeforeApply
        draftNotifyOn = rule.notifyOnTrigger
        conditions = rule.conditions.map { IdentifiedCondition(value: $0) }
        actions = rule.actions.map { IdentifiedAction(value: $0) }
        previewInput = ""
        isEditing = false
        session.isDirty = false
    }

    /// Commit every draft field. Turning notifications on asks for permission and backs
    /// the toggle out if it's refused.
    private func save() {
        guard validateOutput() else { return }
        let wantsNotification = draftNotifyOn && !rule.notifyOnTrigger
        if rule.isBuiltIn {
            // Renaming a built-in makes it the user's own rule; remember the original key
            // so seeding doesn't bring the stock copy back next to it.
            if draftName != displayName {
                BuiltInRules.markDeleted(rule.name)
                rule.isBuiltIn = false
                rule.name = draftName
            }
        } else {
            rule.name = draftName
        }
        rule.conditionLogic = draftLogic
        rule.conditions = conditions.map(\.value)
        rule.actions = actions.map(\.value)
        rule.triggerMode = ruleRequiresManual ? .manual : draftTrigger
        draftTrigger = rule.triggerMode
        rule.outputMode = draftOutput
        rule.outputParam = draftOutput.needsParameter
            ? draftOutputParam.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        draftOutputParam = rule.outputParam
        rule.notifyBeforeApply = draftNotifyBefore
        rule.notifyOnTrigger = draftNotifyOn
        rule.updatedAt = Date()
        try? modelContext.save()
        isEditing = false
        if wantsNotification {
            requestNotificationPermission { granted in
                guard !granted else { return }
                Task { @MainActor in
                    rule.notifyOnTrigger = false
                    draftNotifyOn = false
                    try? modelContext.save()
                }
            }
        }
    }

    // MARK: - Row pieces (shared by both modes)

    private var addConditionMenu: some View {
        HStack {
            NativePullDownButton(title: L10n.tr("automation.condition.add")) {
                [
                    .submenu(L10n.tr("automation.condition.section.content"), symbol: "doc.text", [
                        conditionItem("automation.condition.anyText", .anyText),
                        conditionItem("automation.condition.contentType", .contentType(.text)),
                        conditionItem("automation.condition.containsText", .containsText(text: "")),
                        conditionItem("automation.condition.regexMatch", .regexMatch(pattern: "")),
                        conditionItem("automation.condition.contentLength", .contentLength(min: nil, max: nil)),
                        conditionItem("automation.condition.lineCount", .lineCount(min: nil, max: nil)),
                    ]),
                    .submenu(L10n.tr("automation.condition.section.app"), symbol: "app", [
                        conditionItem("automation.condition.sourceApp", .sourceApp(bundleIDs: [])),
                        conditionItem("automation.condition.targetApp", .targetApp(bundleIDs: [])),
                    ]),
                    .submenu(L10n.tr("automation.condition.section.state"), symbol: "tag", [
                        conditionItem("automation.condition.isPinned", .isPinned),
                        conditionItem("automation.condition.isSensitive", .isSensitive),
                        conditionItem("automation.condition.inGroup", .inGroup(name: "")),
                    ]),
                    .submenu(L10n.tr("automation.condition.section.time"), symbol: "clock", [
                        conditionItem("automation.condition.timeOfDay", .timeOfDay(startMinute: 9 * 60, endMinute: 18 * 60)),
                        conditionItem("automation.condition.weekday", .weekday(days: [2, 3, 4, 5, 6])),
                    ]),
                ]
            }
            .fixedSize()
            Spacer()
        }
    }

    private func conditionItem(_ key: String, _ condition: RuleCondition) -> NativeMenuItem {
        .item(L10n.tr(key)) { conditions.append(IdentifiedCondition(value: condition)) }
    }

    /// One editable condition. A negated condition is stored as `.not(base)` and edited
    /// as `base` plus the "not met" switch; `set` writes the wrapper back.
    @ViewBuilder
    private func conditionRow(_ condition: RuleCondition, at index: Int) -> some View {
        let (base, negated) = condition.unwrappedNegation
        let set: (RuleCondition) -> Void = { conditions[index].value = negated ? .not($0) : $0 }
        switch base {
        case .sourceApp(let bundleIDs):
            appListRow(titleKey: "automation.condition.sourceApp", bundleIDs: bundleIDs, condition: condition, at: index) {
                set(.sourceApp(bundleIDs: $0))
            }
        case .targetApp(let bundleIDs):
            appListRow(titleKey: "automation.condition.targetApp", bundleIDs: bundleIDs, condition: condition, at: index,
                       note: L10n.tr("automation.condition.targetApp.help")) {
                set(.targetApp(bundleIDs: $0))
            }
        default:
            HStack {
                conditionControls(base, set: set)
                Spacer(minLength: 8)
                negateToggle(condition, at: index)
                removeButton { conditions.remove(at: index) }
            }
        }
    }

    @ViewBuilder
    private func conditionControls(_ condition: RuleCondition, set: @escaping (RuleCondition) -> Void) -> some View {
        switch condition {
        case .contentType(let type):
            Picker(L10n.tr("automation.condition.contentType"), selection: Binding(
                get: { type },
                set: { set(.contentType($0)) }
            )) {
                ForEach(ClipContentType.ruleEditorVisibleCases, id: \.self) { t in
                    Text(t.label).tag(t)
                }
            }
        case .anyText:
            Text(L10n.tr("automation.condition.anyText"))
        case .regexMatch(let pattern):
            TextField(L10n.tr("automation.condition.regexMatch"), text: Binding(
                get: { pattern },
                set: { set(.regexMatch(pattern: $0)) }
            ), prompt: Text(L10n.tr("automation.condition.regexMatch.placeholder")))
            .font(.system(.body, design: .monospaced))
        case .containsText(let text):
            TextField(L10n.tr("automation.condition.containsText"), text: Binding(
                get: { text },
                set: { set(.containsText(text: $0)) }
            ), prompt: Text(L10n.tr("automation.condition.containsText.placeholder")))
        case .contentLength(let min, let max):
            rangeFields(titleKey: "automation.condition.contentLength", min: min, max: max) {
                set(.contentLength(min: $0, max: $1))
            }
        case .lineCount(let min, let max):
            rangeFields(titleKey: "automation.condition.lineCount", min: min, max: max) {
                set(.lineCount(min: $0, max: $1))
            }
        case .isPinned:
            Text(L10n.tr("automation.condition.isPinned"))
        case .isSensitive:
            Text(L10n.tr("automation.condition.isSensitive"))
        case .inGroup(let name):
            // Same shape as the "move to group" action's picker — no `.fixedSize()`.
            Picker(L10n.tr("automation.condition.inGroup"), selection: Binding(
                get: { name },
                set: { set(.inGroup(name: $0)) }
            )) {
                let groups = (try? modelContext.fetch(FetchDescriptor<SmartGroup>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
                Text(L10n.tr("automation.condition.inGroup.any")).tag("")
                ForEach(groups, id: \.name) { group in
                    Label(group.name, systemImage: group.icon).tag(group.name)
                }
            }
        case .timeOfDay(let start, let end):
            Text(L10n.tr("automation.condition.timeOfDay"))
            DatePicker("", selection: minuteBinding(start) { set(.timeOfDay(startMinute: $0, endMinute: end)) },
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
            Text("–").foregroundStyle(.secondary)
            DatePicker("", selection: minuteBinding(end) { set(.timeOfDay(startMinute: start, endMinute: $0)) },
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .fixedSize()
        case .weekday(let days):
            Text(L10n.tr("automation.condition.weekday"))
            weekdayToggles(days) { set(.weekday(days: $0)) }
        case .sourceApp, .targetApp, .not:
            EmptyView()
        }
    }

    /// "Not met" switch: flips the row between `base` and `.not(base)`. Takes the
    /// row's condition instead of reading `conditions[index]` while rendering.
    private func negateToggle(_ condition: RuleCondition, at index: Int) -> some View {
        let (base, negated) = condition.unwrappedNegation
        return Toggle(L10n.tr("automation.condition.negated"), isOn: Binding(
            get: { negated },
            set: { conditions[index].value = $0 ? .not(base) : base }
        ))
        .toggleStyle(.button)
        .controlSize(.small)
    }

    private var negationBadge: some View {
        Text(L10n.tr("automation.condition.negated"))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
            .foregroundStyle(.orange)
    }

    private func rangeFields(titleKey: String, min: Int?, max: Int?, set: @escaping (Int?, Int?) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(L10n.tr(titleKey))
            optionalNumberField(min, placeholderKey: "automation.condition.range.min") { set($0, max) }
            Text("–").foregroundStyle(.secondary)
            optionalNumberField(max, placeholderKey: "automation.condition.range.max") { set(min, $0) }
        }
    }

    private func optionalNumberField(_ value: Int?, placeholderKey: String, set: @escaping (Int?) -> Void) -> some View {
        TextField("", text: Binding(
            get: { value.map(String.init) ?? "" },
            set: { text in
                let digits = String(text.filter { $0.isASCII && $0.isNumber }.prefix(9))
                set(digits.isEmpty ? nil : Int(digits))
            }
        ), prompt: Text(L10n.tr(placeholderKey)))
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 64)
    }

    private func minuteBinding(_ minute: Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }
        )
    }

    /// Weekdays in the user's calendar order (Monday first in most regions).
    private static var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private static func weekdayName(_ day: Int) -> String {
        Calendar.current.shortStandaloneWeekdaySymbols[day - 1]
    }

    private func weekdayToggles(_ days: [Int], set: @escaping ([Int]) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(Self.orderedWeekdays, id: \.self) { day in
                Toggle(Self.weekdayName(day), isOn: Binding(
                    get: { days.contains(day) },
                    set: { on in
                        var next = Set(days)
                        if on { next.insert(day) } else { next.remove(day) }
                        set(next.sorted())
                    }
                ))
                .toggleStyle(.button)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func appListRow(titleKey: String, bundleIDs: [String], condition: RuleCondition, at index: Int,
                            note: String? = nil, set: @escaping ([String]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: bundleIDs.isEmpty ? 6 : 10) {
            HStack {
                Text(L10n.tr(titleKey))
                Spacer()
                negateToggle(condition, at: index)
                removeButton { conditions.remove(at: index) }
            }
            if let note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if bundleIDs.isEmpty {
                Text(L10n.tr("automation.condition.sourceApp.empty"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            ForEach(bundleIDs, id: \.self) { bid in
                HStack(spacing: 6) {
                    appIcon(for: bid)
                    Text(appName(for: bid))
                    Spacer()
                    Button {
                        set(bundleIDs.filter { $0 != bid })
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary.opacity(0.5))
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button(L10n.tr("automation.condition.sourceApp.add")) {
                browseForApp(existing: bundleIDs, set: set)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }
    /// Grouped submenus: the flat five-section list ran out of room once the
    /// action count passed twenty.
    private var addActionMenu: some View {
        HStack {
            NativePullDownButton(title: L10n.tr("automation.action.add")) {
                [
                    .submenu(L10n.tr("automation.action.section.text"), symbol: "textformat", [
                        actionItem(.lowercased), actionItem(.uppercased), actionItem(.trimWhitespace),
                        actionItem(.removeBlankLines), actionItem(.stripRichText), actionItem(.removeHTMLTags),
                    ]),
                    .submenu(L10n.tr("automation.action.section.format"), symbol: "arrow.left.arrow.right", [
                        actionItem(.jsonFormat), actionItem(.jsonMinify),
                        actionItem(.base64Encode), actionItem(.base64Decode),
                        actionItem(.toCamelCase), actionItem(.toSnakeCase),
                        actionItem(.toHalfWidth), actionItem(.toFullWidth), actionItem(.simplifiedToTraditional),
                    ]),
                    .submenu(L10n.tr("automation.action.section.lines"), symbol: "list.bullet", [
                        actionItem(.removeDuplicateLines), actionItem(.sortLines(ascending: true)),
                        actionItem(.joinLines(separator: " ")),
                    ]),
                    .submenu(L10n.tr("automation.action.section.extract"), symbol: "text.viewfinder", [
                        actionItem(.extractVerificationCode), actionItem(.extractLinks),
                        actionItem(.convertColor(format: ColorFormat.hex.rawValue)), actionItem(.runOCR),
                    ]),
                    .submenu(L10n.tr("automation.action.section.url"), symbol: "link", [
                        actionItem(.urlEncode), actionItem(.urlDecode), actionItem(.removeQueryParams(patterns: ["utm_*"])),
                    ]),
                    .submenu(L10n.tr("automation.action.section.advanced"), symbol: "slider.horizontal.3", [
                        actionItem(.regexReplace(pattern: "", replacement: "")), actionItem(.addPrefix(text: "")), actionItem(.addSuffix(text: "")),
                    ]),
                    .submenu(L10n.tr("automation.action.section.external"), symbol: "sparkles", [
                        actionItem(.aiTransform(prompt: "", thinking: nil, temperature: nil, timeoutSeconds: nil)), actionItem(.runShortcut(name: "")),
                    ]),
                    .submenu(L10n.tr("automation.action.section.open"), symbol: "arrow.up.forward.square", [
                        actionItem(.openLink), actionItem(.openInPreview), actionItem(.showInFinder),
                        actionItem(.addToRelay), actionItem(.splitToRelay(delimiter: "\n")),
                    ]),
                    .submenu(L10n.tr("automation.action.section.clipboard"), symbol: "tag", [
                        actionItem(.pin), actionItem(.unpin), actionItem(.markSensitive), actionItem(.unmarkSensitive),
                        actionItem(.assignGroup(name: "")), actionItem(.skipCapture), actionItem(.deleteItem),
                    ]),
                    .submenu(L10n.tr("automation.action.section.flow"), symbol: "flag", [
                        actionItem(.stopProcessing), actionItem(.closeQuickPanel),
                        actionItem(.playSound(name: SoundManager.SYSTEM_SOUNDS[0].storageKey)),
                    ]),
                ]
            }
            .fixedSize()
            Spacer()
        }
    }
    private func actionItem(_ action: RuleAction) -> NativeMenuItem {
        .item(Self.title(for: action)) { actions.append(IdentifiedAction(value: action)) }
    }
    /// Menu / card title: the action name without its parameter.
    private static func title(for action: RuleAction) -> String {
        switch action {
        case .assignGroup: L10n.tr("automation.action.assignGroup")
        case .runShortcut: L10n.tr("automation.action.runShortcut")
        case .convertColor: L10n.tr("automation.action.convertColor")
        default: action.displayLabel
        }
    }
    private static func icon(for action: RuleAction) -> (name: String, tint: Color) {
        switch action {
        case .aiTransform: ("sparkles", .purple)
        case .runShortcut: ("square.stack.3d.up.fill", .purple)
        case .runOCR: ("text.viewfinder", .blue)
        case .convertColor: ("paintpalette", .blue)
        case .openLink: ("link", .gray)
        case .openInPreview: ("eye", .gray)
        case .showInFinder: ("folder", .gray)
        case .addToRelay: ("arrow.right.arrow.left", .gray)
        case .splitToRelay: ("scissors", .gray)
        case .deleteItem: ("trash", .red)
        case .playSound: ("speaker.wave.2", .gray)
        default:
            switch action.kind {
            case .transform: ("textformat", .blue)
            case .metadata: ("tag", .orange)
            case .sideEffect: ("flag", .gray)
            case .external: ("arrow.up.forward.app", .purple)
            }
        }
    }
    @ViewBuilder
    private func actionParameters(_ action: RuleAction, at index: Int) -> some View {
        switch action {
        case .aiTransform(let prompt, let thinking, let temperature, let timeout):
            promptEditor(text: Binding(
                get: { prompt },
                set: { actions[index].value = .aiTransform(prompt: $0, thinking: thinking, temperature: temperature, timeoutSeconds: timeout) }
            ))
            aiOverrides(index: index, id: actions[index].id, prompt: prompt, thinking: thinking, temperature: temperature, timeout: timeout)
        
            if !AIProviderSettings.isConfigured {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L10n.tr("automation.ai.notConfigured"))
                    Button(L10n.tr("automation.ai.openSettings")) {
                        openSettings(category: .aiService)
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

        case .regexReplace(let pattern, let replacement):
            TextField(L10n.tr("automation.action.regexReplace.pattern"), text: Binding(
                get: { pattern },
                set: { actions[index].value = .regexReplace(pattern: $0, replacement: replacement) }
            ), prompt: Text(L10n.tr("automation.action.regexReplace.placeholder")))
            .font(.system(.body, design: .monospaced))
            TextField(L10n.tr("automation.action.regexReplace.to"), text: Binding(
                get: { replacement },
                set: { actions[index].value = .regexReplace(pattern: pattern, replacement: $0) }
            ), prompt: Text(L10n.tr("automation.action.regexReplace.to.placeholder")))
            .font(.system(.body, design: .monospaced))
        

        case .removeQueryParams(let patterns):
            TextField("", text: Binding(
                get: { patterns.joined(separator: ", ") },
                set: { actions[index].value = .removeQueryParams(patterns: $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
            ), prompt: Text(L10n.tr("automation.action.removeQueryParams.placeholder")))
            .labelsHidden()
            .font(.system(.body, design: .monospaced))
        

        case .addPrefix(let text):
            parameterField(text: text, placeholder: "automation.action.addPrefix.placeholder") {
                actions[index].value = .addPrefix(text: $0)
            }

        case .addSuffix(let text):
            parameterField(text: text, placeholder: "automation.action.addSuffix.placeholder") {
                actions[index].value = .addSuffix(text: $0)
            }

        case .assignGroup(let name):
            // No `.fixedSize()` here: an empty-label Picker with it sizes itself to its
            // whole inlined option list and blows up the row. (issue #71 review)
            Picker("", selection: Binding(
                get: { name },
                set: { actions[index].value = .assignGroup(name: $0) }
            )) {
                let groups = (try? modelContext.fetch(FetchDescriptor<SmartGroup>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
                Text(L10n.tr("automation.action.assignGroup.placeholder")).tag("")
                ForEach(groups, id: \.name) { group in
                    Label(group.name, systemImage: group.icon).tag(group.name)
                }
            }
            .labelsHidden()
        

        case .runShortcut(let name):
            HStack {
                TextField("", text: Binding(
                    get: { name },
                    set: { actions[index].value = .runShortcut(name: $0) }
                ), prompt: Text(L10n.tr("automation.action.runShortcut.placeholder")))
                .labelsHidden()
                Button {
                    shortcutPickerIndex = index
                } label: {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("automation.action.runShortcut.pick"))
                .popover(isPresented: Binding(
                    get: { shortcutPickerIndex == index },
                    set: { if !$0 { shortcutPickerIndex = nil } }
                )) {
                    ShortcutPickerPopover { picked in
                        actions[index].value = .runShortcut(name: picked)
                        shortcutPickerIndex = nil
                    }
                }
                Button {
                    ShortcutRunner.openShortcutInApp(name: name)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(L10n.tr("automation.action.runShortcut.openInApp"))
            }


        case .convertColor(let format):
            Picker("", selection: Binding(
                get: { format },
                set: { actions[index].value = .convertColor(format: $0) }
            )) {
                ForEach(ColorFormat.allCases, id: \.rawValue) { f in
                    Text(f.rawValue).tag(f.rawValue)
                }
            }
            .labelsHidden()

        case .splitToRelay(let delimiter):
            delimiterPicker(delimiter, at: index)

        case .sortLines(let ascending):
            Picker("", selection: Binding(
                get: { ascending },
                set: { actions[index].value = .sortLines(ascending: $0) }
            )) {
                Text(L10n.tr("automation.action.sortLines.ascending")).tag(true)
                Text(L10n.tr("automation.action.sortLines.descending")).tag(false)
            }
            .labelsHidden()

        case .joinLines(let separator):
            joinSeparatorPicker(separator, at: index)

        case .playSound(let name):
            Picker("", selection: Binding(
                get: { name },
                set: {
                    actions[index].value = .playSound(name: $0)
                    SoundManager.play(storageKey: $0)
                }
            )) {
                ForEach(SoundManager.ALL_SOUNDS, id: \.storageKey) { source in
                    Text(source.displayName).tag(source.storageKey)
                }
            }
            .labelsHidden()

        default:
            EmptyView()
        }
    }

    /// What goes between joined lines: space / nothing / comma / 、, or any other text.
    private static let joinPresets: [(value: String, key: String)] = [
        (" ", "automation.action.joinLines.space"),
        ("", "automation.action.joinLines.none"),
        (", ", "relay.delimiter.comma"),
        ("、", "relay.delimiter.chineseComma"),
    ]

    @ViewBuilder
    private func joinSeparatorPicker(_ separator: String, at index: Int) -> some View {
        let isCustom = !Self.joinPresets.contains { $0.value == separator }
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { isCustom ? "\u{0}custom" : separator },
                set: { picked in
                    actions[index].value = .joinLines(separator: picked == "\u{0}custom" ? " | " : picked)
                }
            )) {
                ForEach(Self.joinPresets, id: \.value) { preset in
                    Text(L10n.tr(preset.key)).tag(preset.value)
                }
                Text(L10n.tr("relay.delimiter.custom")).tag("\u{0}custom")
            }
            .labelsHidden()
            if isCustom {
                TextField("", text: Binding(
                    get: { separator },
                    set: { actions[index].value = .joinLines(separator: $0) }
                ))
                .labelsHidden()
                .frame(width: 80)
            }
        }
    }

    /// Newline / comma / 、 presets, or any other text.
    @ViewBuilder
    private func delimiterPicker(_ delimiter: String, at index: Int) -> some View {
        let presets = RelaySplitter.PRESET_DELIMITERS.map(\.value)
        let isCustom = !delimiter.isEmpty && !presets.contains(delimiter)
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { isCustom ? "\u{0}custom" : (delimiter.isEmpty ? "\n" : delimiter) },
                set: { picked in
                    actions[index].value = .splitToRelay(delimiter: picked == "\u{0}custom" ? "|" : picked)
                }
            )) {
                ForEach(RelaySplitter.PRESET_DELIMITERS, id: \.self) { preset in
                    Text(L10n.tr(preset.displayName)).tag(preset.value)
                }
                Text(L10n.tr("relay.delimiter.custom")).tag("\u{0}custom")
            }
            .labelsHidden()
            if isCustom {
                TextField("", text: Binding(
                    get: { delimiter },
                    set: { actions[index].value = .splitToRelay(delimiter: $0) }
                ))
                .labelsHidden()
                .frame(width: 80)
            }
        }
    }
    /// Per-action model knobs in a collapsible card. Collapsed, the header line sums up
    /// what's pinned; each row has a "follow global / custom" picker and shows its
    /// control only when custom.
    @ViewBuilder
    private func aiOverrides(index: Int, id: UUID, prompt: String, thinking: AIThinkingMode?, temperature: Double?, timeout: Double?) -> some View {
        let set: (AIThinkingMode?, Double?, Double?) -> Void = { th, te, to in
            actions[index].value = .aiTransform(prompt: prompt, thinking: th, temperature: te, timeoutSeconds: to)
        }
        let expanded = expandedOverrides.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expanded { expandedOverrides.remove(id) } else { expandedOverrides.insert(id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(L10n.tr("automation.action.aiTransform.overrides"))
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(overrideSummary(thinking: thinking, temperature: temperature, timeout: timeout))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if expanded {
                Divider()
                VStack(spacing: 0) {
                    overrideRow(L10n.tr("settings.aiService.thinking")) {
                        Picker("", selection: Binding(
                            get: { thinking?.rawValue ?? "" },
                            set: { set(AIThinkingMode(rawValue: $0), temperature, timeout) }
                        )) {
                            Text(L10n.tr("automation.action.aiTransform.followGlobal")).tag("")
                            Divider()
                            Text(L10n.tr("settings.aiService.thinking.auto")).tag(AIThinkingMode.auto.rawValue)
                            Text(L10n.tr("settings.aiService.thinking.off")).tag(AIThinkingMode.off.rawValue)
                            Text(L10n.tr("settings.aiService.thinking.on")).tag(AIThinkingMode.on.rawValue)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Divider().padding(.leading, 10)
                    overrideRow(L10n.tr("settings.aiService.temperature")) {
                        if let temperature {
                            Slider(value: Binding(get: { temperature }, set: { set(thinking, $0, timeout) }), in: 0...1, step: 0.1)
                                .frame(width: 120)
                            Text(String(format: "%.1f", temperature))
                                .monospacedDigit()
                                .frame(width: 26, alignment: .trailing)
                        }
                        followPicker(isCustom: temperature != nil) { custom in
                            set(thinking, custom ? AIProviderSettings.temperature : nil, timeout)
                        }
                    }
                    Divider().padding(.leading, 10)
                    overrideRow(L10n.tr("settings.aiService.timeout")) {
                        if let timeout {
                            TextField("", value: Binding(
                                get: { Int(timeout) },
                                set: { set(thinking, temperature, Double(min(max($0, 5), 600))) }
                            ), format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 48)
                            Text(L10n.tr("settings.aiService.timeout.unit"))
                                .foregroundStyle(.secondary)
                        }
                        followPicker(isCustom: timeout != nil) { custom in
                            set(thinking, temperature, custom ? AIProviderSettings.timeoutSeconds : nil)
                        }
                    }
                }
                .font(.callout)
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .quaternarySystemFill)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
    private func overrideRow<Trailing: View>(_ label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
    private func followPicker(isCustom: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        Picker("", selection: Binding(get: { isCustom }, set: onChange)) {
            Text(L10n.tr("automation.action.aiTransform.followGlobal")).tag(false)
            Text(L10n.tr("settings.aiService.preset.custom")).tag(true)
        }
        .labelsHidden()
        .fixedSize()
    }
    private func overrideSummary(thinking: AIThinkingMode?, temperature: Double?, timeout: Double?) -> String {
        var parts: [String] = []
        if let thinking {
            parts.append(L10n.tr("settings.aiService.thinking") + " " + L10n.tr("settings.aiService.thinking.\(thinking.rawValue)"))
        }
        if let temperature { parts.append(L10n.tr("settings.aiService.temperature") + " " + String(format: "%.1f", temperature)) }
        if let timeout { parts.append(L10n.tr("settings.aiService.timeout") + " " + L10n.tr("settings.aiService.timeout.seconds", Int(timeout))) }
        return parts.isEmpty ? L10n.tr("automation.action.aiTransform.followGlobal") : parts.joined(separator: " · ")
    }
    @ViewBuilder
    private func parameterField(text: String, placeholder: String, set: @escaping (String) -> Void) -> some View {
        TextField("", text: Binding(get: { text }, set: set), prompt: Text(L10n.tr(placeholder)))
            .labelsHidden()
    
    }
    /// Multi-line prompt box. A one-line field made writing an instruction miserable.
    private func promptEditor(text: Binding<String>) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .frame(minHeight: 84)
            if text.wrappedValue.isEmpty {
                Text(L10n.tr("automation.action.aiTransform.placeholder"))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }
    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }
    private func onOff(_ value: Bool) -> String {
        L10n.tr(value ? "automation.editor.on" : "automation.editor.off")
    }
    @ViewBuilder
    private func readOnlyCondition(_ condition: RuleCondition) -> some View {
        let (base, negated) = condition.unwrappedNegation
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if negated { negationBadge }
            readOnlyBaseCondition(base)
        }
    }

    @ViewBuilder
    private func readOnlyBaseCondition(_ condition: RuleCondition) -> some View {
        switch condition {
        case .contentType(let type):
            LabeledContent(L10n.tr("automation.condition.contentType")) { Text(type.label) }
        case .anyText:
            Text(L10n.tr("automation.condition.anyText"))
        case .regexMatch(let pattern):
            LabeledContent(L10n.tr("automation.condition.regexMatch")) {
                Text(pattern).font(.system(.body, design: .monospaced))
            }
        case .containsText(let text):
            LabeledContent(L10n.tr("automation.condition.containsText")) { Text(text) }
        case .sourceApp(let bundleIDs), .targetApp(let bundleIDs):
            VStack(alignment: .leading, spacing: 6) {
                if case .targetApp = condition {
                    Text(L10n.tr("automation.condition.targetApp"))
                } else {
                    Text(L10n.tr("automation.condition.sourceApp"))
                }
                ForEach(bundleIDs, id: \.self) { bid in
                    HStack(spacing: 6) {
                        appIcon(for: bid)
                        Text(appName(for: bid))
                    }
                }
            }
        case .contentLength(let min, let max):
            LabeledContent(L10n.tr("automation.condition.contentLength")) { Text(Self.rangeText(min, max)) }
        case .lineCount(let min, let max):
            LabeledContent(L10n.tr("automation.condition.lineCount")) { Text(Self.rangeText(min, max)) }
        case .isPinned:
            Text(L10n.tr("automation.condition.isPinned"))
        case .isSensitive:
            Text(L10n.tr("automation.condition.isSensitive"))
        case .inGroup(let name):
            LabeledContent(L10n.tr("automation.condition.inGroup")) {
                Text(name.isEmpty ? L10n.tr("automation.condition.inGroup.any") : name)
            }
        case .timeOfDay(let start, let end):
            LabeledContent(L10n.tr("automation.condition.timeOfDay")) {
                Text(Self.clockText(start) + " – " + Self.clockText(end)).monospacedDigit()
            }
        case .weekday(let days):
            LabeledContent(L10n.tr("automation.condition.weekday")) {
                Text(Self.orderedWeekdays.filter(days.contains).map(Self.weekdayName).joined(separator: " "))
            }
        case .not:
            // `unwrappedNegation` already peeled every `.not` off.
            EmptyView()
        }
    }

    private static func rangeText(_ min: Int?, _ max: Int?) -> String {
        switch (min, max) {
        case let (min?, max?): return "\(min) – \(max)"
        case let (min?, nil): return "≥ \(min)"
        case let (nil, max?): return "≤ \(max)"
        case (nil, nil): return L10n.tr("automation.condition.range.any")
        }
    }

    private static func clockText(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    @ViewBuilder
    private func readOnlyParameters(_ action: RuleAction) -> some View {
        switch action {
        case .aiTransform(let prompt, let thinking, let temperature, let timeout):
            Text(prompt.isEmpty ? L10n.tr("automation.action.aiTransform.placeholder") : prompt)
                .font(.callout)
                .foregroundStyle(prompt.isEmpty ? .tertiary : .secondary)
                .textSelection(.enabled)
            if thinking != nil || temperature != nil || timeout != nil {
                Text(L10n.tr("automation.action.aiTransform.overrides") + "：" + overrideSummary(thinking: thinking, temperature: temperature, timeout: timeout))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !AIProviderSettings.isConfigured {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L10n.tr("automation.ai.notConfigured"))
                    Button(L10n.tr("automation.ai.openSettings")) { openSettings(category: .aiService) }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .regexReplace(let pattern, let replacement):
            Text("\(pattern) → \(replacement)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        case .removeQueryParams(let patterns):
            Text(patterns.joined(separator: ", "))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        case .addPrefix(let text), .addSuffix(let text):
            Text(text).font(.callout).foregroundStyle(.secondary)
        case .assignGroup(let name):
            let group = (try? modelContext.fetch(FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == name })))?.first
            Label(name, systemImage: group?.icon ?? "folder").font(.callout).foregroundStyle(.secondary)
        case .runShortcut(let name):
            Text(name.isEmpty ? L10n.tr("automation.action.runShortcut.empty") : name)
                .font(.callout)
                .foregroundStyle(name.isEmpty ? .tertiary : .secondary)
        case .convertColor(let format):
            Text(format).font(.callout).foregroundStyle(.secondary)
        case .splitToRelay(let delimiter):
            let preset = RelaySplitter.PRESET_DELIMITERS.first { $0.value == (delimiter.isEmpty ? "\n" : delimiter) }
            Text(preset.map { L10n.tr($0.displayName) } ?? "“\(delimiter)”")
                .font(.callout).foregroundStyle(.secondary)
        case .playSound(let name):
            Text(SoundManager.SoundSource.from(storageKey: name).displayName)
                .font(.callout).foregroundStyle(.secondary)
        case .sortLines(let ascending):
            Text(L10n.tr(ascending ? "automation.action.sortLines.ascending" : "automation.action.sortLines.descending"))
                .font(.callout).foregroundStyle(.secondary)
        case .joinLines(let separator):
            let preset = Self.joinPresets.first { $0.value == separator }
            Text(preset.map { L10n.tr($0.key) } ?? "“\(separator)”")
                .font(.callout).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
    /// Synchronous transforms only. Conditions about the stored clip or the paste target
    /// are skipped — typed text has neither, and failing on that would only ever say
    /// "not matched".
    private var previewOutput: String {
        let type = ClipboardManager.shared.detectContentType(previewInput).type
        let checked = conditions.map(\.value).filter { !$0.needsClipContext }
        let matched = checked.isEmpty || AutomationEngine.matchesConditions(
            checked, logic: draftLogic, content: previewInput, contentType: type, sourceApp: nil
        )
        guard matched else { return L10n.tr("automation.preview.notMatched") }
        let sync = actions.map(\.value).filter { $0.kind == .transform && !$0.isAsync }
        return AutomationEngine.executeActions(sync, on: previewInput)
    }
    // MARK: - Helpers

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

    /// Enabling needs conditions plus something to do: an action, or an output that
    /// goes somewhere (save to folder / webhook) on its own.
    private func validateRule() -> Bool {
        let hasWork = !rule.actions.isEmpty || rule.outputMode.needsParameter
        guard !rule.conditions.isEmpty, hasWork else {
            let alert = NSAlert()
            alert.messageText = L10n.tr("automation.validation.incomplete")
            alert.informativeText = L10n.tr("automation.validation.incompleteMessage")
            alert.runModal()
            return false
        }
        return true
    }

    /// A folder that exists / an http(s) URL, before the draft is saved.
    private func validateOutput() -> Bool {
        let message: String
        switch draftOutput {
        case .saveToFile where RuleOutputDelivery.folderURL(from: draftOutputParam) == nil:
            message = L10n.tr("automation.output.folder.invalid")
        case .postWebhook where RuleOutputDelivery.webhookURL(from: draftOutputParam) == nil:
            message = L10n.tr("automation.output.webhook.invalidURL")
        default:
            return true
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        return false
    }

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

    private func browseForApp(existing: [String], set: ([String]) -> Void) {
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
        set(ids)
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
