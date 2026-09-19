import SwiftUI
import SwiftData

extension Notification.Name {
    static let automationEnterEdit = Notification.Name("automationEnterEdit")
}

/// Lets the sidebar ask the editor "anything unsaved?" before switching rules, and
/// save or discard on the user's behalf.
@MainActor
final class RuleEditorSession: ObservableObject {
    @Published var isDirty = false
    var save: () -> Void = {}
    var discard: () -> Void = {}

    /// Standard document-style prompt. Returns false when the user cancels.
    func confirmLeaving() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.tr("automation.editor.unsaved")
        alert.informativeText = L10n.tr("automation.editor.unsavedMessage")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("automation.editor.save"))
        alert.addButton(withTitle: L10n.tr("automation.editor.dontSave"))
        alert.addButton(withTitle: L10n.tr("automation.editor.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(); return true
        case .alertSecondButtonReturn: discard(); return true
        default: return false
        }
    }
}

enum AutomationManagerWindow {
    @MainActor
    static func show() {
        AppAction.shared.openAutomationManager?()
    }
}

struct AutomationManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AutomationRule.sortOrder) private var rules: [AutomationRule]
    @State private var selectedRuleID: String?
    @StateObject private var session = RuleEditorSession()

    /// What the sidebar highlights. Kept apart from `selectedRuleID` so a cancelled
    /// switch can snap the highlight back (assigning the same value to a binding
    /// doesn't make the List re-sync).
    @State private var listSelection: String?

    private var builtInRules: [AutomationRule] { rules.filter(\.isBuiltIn) }
    private var customRules: [AutomationRule] { rules.filter { !$0.isBuiltIn } }
    private var customAutoRules: [AutomationRule] {
        customRules.filter { $0.enabled && $0.triggerMode == .automatic }
    }
    private var customManualRules: [AutomationRule] {
        customRules.filter { $0.enabled && $0.triggerMode == .manual }
    }
    private var customDisabledRules: [AutomationRule] {
        customRules.filter { !$0.enabled }
    }
    private var selectedRule: AutomationRule? { rules.first { $0.ruleID == selectedRuleID } }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .onAppear {
            if selectedRuleID == nil { selectedRuleID = rules.first?.ruleID }
            listSelection = selectedRuleID
        }
        .onChange(of: listSelection) { _, newValue in
            guard newValue != selectedRuleID else { return }
            if session.confirmLeaving() {
                selectedRuleID = newValue
            } else {
                listSelection = selectedRuleID
            }
        }
        .onChange(of: selectedRuleID) { _, newValue in
            if listSelection != newValue { listSelection = newValue }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $listSelection) {
            Section(L10n.tr("automation.section.builtIn")) {
                ForEach(builtInRules) { rule in
                    ruleRow(rule)
                }
            }
            if customRules.isEmpty {
                Section(L10n.tr("automation.section.custom")) {
                    Text(L10n.tr("automation.section.empty"))
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
            } else {
                if !customAutoRules.isEmpty {
                    Section(L10n.tr("settings.automation.auto")) {
                        ForEach(customAutoRules) { rule in
                            ruleRow(rule)
                        }
                    }
                }
                if !customManualRules.isEmpty {
                    Section(L10n.tr("settings.automation.manual")) {
                        ForEach(customManualRules) { rule in
                            ruleRow(rule)
                        }
                    }
                }
                if !customDisabledRules.isEmpty {
                    Section(L10n.tr("automation.section.disabled")) {
                        ForEach(customDisabledRules) { rule in
                            ruleRow(rule)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 4) {
                Button(action: addRule) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)

                Button {
                    if let rule = selectedRule {
                        deleteRule(rule)
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedRule == nil)

                Spacer()

                NativePullDownButton(title: "", symbolName: "ellipsis.circle", bordered: false) {
                    [.item(L10n.tr("automation.builtIn.restore"), symbol: "arrow.counterclockwise", enabled: !BuiltInRules.deletedNames.isEmpty) {
                        BuiltInRules.restoreDeleted(context: modelContext)
                    }]
                }
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func ruleRow(_ rule: AutomationRule) -> some View {
        HStack {
            Circle()
                .fill(rule.enabled ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
            Text(rule.isBuiltIn ? L10n.tr(rule.name) : rule.name)
                .lineLimit(1)
        }
        // Stretch to the row's full width so the right-click overlay covers the whole
        // row, not just the dot and the text.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(rule.ruleID)
        .nativeContextMenu(onSelect: { listSelection = rule.ruleID }) {
            var items: [NativeMenuItem] = []
            items.append(.item(L10n.tr("automation.editor.edit"), symbol: "pencil") {
                selectedRuleID = rule.ruleID
                NotificationCenter.default.post(name: .automationEnterEdit, object: nil)
            })
            items.append(.item(L10n.tr("action.mergeCopy"), symbol: "doc.on.doc") { duplicateRule(rule) })
            items.append(.separator)
            items.append(.item(L10n.tr("action.delete"), symbol: "trash", destructive: true) { deleteRule(rule) })
            return items
        }
    }

    private func deleteRule(_ rule: AutomationRule) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("automation.delete.confirm")
        alert.informativeText = L10n.tr("automation.delete.confirmMessage")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("action.delete"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let id = rule.ruleID
        if id == selectedRuleID { session.discard() }
        if rule.isBuiltIn { BuiltInRules.markDeleted(rule.name) }
        modelContext.delete(rule)
        try? modelContext.save()
        if selectedRuleID == id {
            selectedRuleID = rules.first(where: { $0.ruleID != id })?.ruleID
        }
    }

    private func duplicateRule(_ rule: AutomationRule) {
        guard session.confirmLeaving() else { return }
        let nextOrder = (rules.map(\.sortOrder).max() ?? 0) + 1
        let copy = AutomationRule(
            name: rule.isBuiltIn ? L10n.tr(rule.name) + " - Copy" : rule.name + " - Copy",
            enabled: false,
            isBuiltIn: false,
            sortOrder: nextOrder,
            triggerMode: rule.triggerMode,
            conditions: rule.conditions,
            actions: rule.actions
        )
        modelContext.insert(copy)
        try? modelContext.save()
        selectedRuleID = copy.ruleID
    }

    // MARK: - Detail

    private var detailView: some View {
        Group {
            if let rule = selectedRule {
                AutomationRuleEditorView(rule: rule, session: session)
            } else {
                ContentUnavailableView(
                    L10n.tr("automation.editor.selectRule"),
                    systemImage: "gearshape.2"
                )
            }
        }
    }

    // MARK: - Actions

    private func addRule() {
        guard session.confirmLeaving() else { return }
        let nextOrder = (rules.map(\.sortOrder).max() ?? 0) + 1
        let rule = AutomationRule(
            name: L10n.tr("automation.rule.newName"),
            enabled: false,
            isBuiltIn: false,
            sortOrder: nextOrder,
            triggerMode: .automatic
        )
        modelContext.insert(rule)
        try? modelContext.save()
        selectedRuleID = rule.ruleID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .automationEnterEdit, object: nil)
        }
    }

}
