import SwiftUI
import SwiftData

struct SnippetDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var snippet: SnippetItem
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: snippet.contentType.icon)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 10) {
                        TextField(L10n.tr("snippet.titlePlaceholder"), text: $snippet.title)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 18, weight: .semibold))
                        HStack(spacing: 12) {
                            Picker(L10n.tr("snippet.typeLabel"), selection: Binding(
                                get: { snippet.contentType },
                                set: {
                                    snippet.contentType = $0
                                    saveSnippet()
                                }
                            )) {
                                ForEach(ClipContentType.visibleCases, id: \.self) { type in
                                    Text(type.label).tag(type)
                                }
                            }
                            .pickerStyle(.menu)

                            Toggle(L10n.tr("action.pin"), isOn: $snippet.isPinned)
                                .toggleStyle(.checkbox)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("snippet.groupLabel"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text(snippet.groupName ?? L10n.tr("snippet.groupNone"))
                            .font(.system(size: 13))
                            .foregroundStyle(snippet.groupName == nil ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                        Button(L10n.tr("snippet.groupChoose")) {
                            chooseGroup()
                        }

                        if snippet.groupName != nil {
                            Button(L10n.tr("snippet.groupClear")) {
                                snippet.groupName = nil
                                saveSnippet()
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("snippet.tagsLabel"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(L10n.tr("snippet.tagsPlaceholder"), text: Binding(
                        get: { snippet.tagsText },
                        set: {
                            snippet.tagsText = $0
                            saveSnippet()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("snippet.contentLabel"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $snippet.content)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 260)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                }

                HStack(spacing: 12) {
                    Label(snippet.usageCount == 0 ? L10n.tr("snippet.unused") : L10n.tr("snippet.usedCount", snippet.usageCount), systemImage: "chart.bar")
                    Label(formatTimeAgo(snippet.lastUsedAt), systemImage: "clock")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Button(role: .destructive, action: onDelete) {
                    Label(L10n.tr("snippet.delete"), systemImage: "trash")
                }
            }
            .padding(20)
        }
        .onChange(of: snippet.title) { saveSnippet() }
        .onChange(of: snippet.content) { saveSnippet() }
        .onChange(of: snippet.groupName) { saveSnippet() }
        .onChange(of: snippet.isPinned) { saveSnippet() }
        .onChange(of: snippet.tagsRaw) { saveSnippet() }
    }

    private func saveSnippet() {
        SnippetLibrary.saveAndNotify(modelContext)
    }

    private func chooseGroup() {
        let existingName = snippet.groupName ?? ""
        GroupEditorPanel.show(name: existingName, icon: "folder") { result in
            guard let result else { return }
            snippet.groupName = result.name
            saveSnippet()
        }
    }
}
