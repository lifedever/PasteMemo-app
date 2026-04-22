import SwiftUI
import SwiftData

extension Notification.Name {
    static let automationEnterEdit = Notification.Name("automationEnterEdit")
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
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedRuleID) {
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
                    if let rule = selectedRule, !rule.isBuiltIn {
                        deleteRule(rule)
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedRule?.isBuiltIn ?? true)

                Spacer()
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
        .tag(rule.ruleID)
        .contextMenu {
            if !rule.isBuiltIn {
                Button(L10n.tr("automation.editor.edit")) {
                    selectedRuleID = rule.ruleID
                    NotificationCenter.default.post(name: .automationEnterEdit, object: nil)
                }
            }
            Button(L10n.tr("action.mergeCopy")) {
                duplicateRule(rule)
            }
            if !rule.isBuiltIn {
                Button(L10n.tr("action.delete"), role: .destructive) {
                    deleteRule(rule)
                }
            }
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
        modelContext.delete(rule)
        try? modelContext.save()
        if selectedRuleID == id {
            selectedRuleID = rules.first(where: { $0.ruleID != id })?.ruleID
        }
    }

    private func duplicateRule(_ rule: AutomationRule) {
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
                AutomationRuleEditorView(rule: rule)
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
