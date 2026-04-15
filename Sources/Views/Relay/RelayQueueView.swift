import SwiftData
import SwiftUI

struct RelayQueueView: View {
    @Bindable var manager: RelayManager
    @State private var splitTargetIndex: Int?
    @State private var draggingItem: RelayItem?
    @State private var showSettingsPopover = false
    @AppStorage("relayPasteAsPlainText") private var settingPlainText = false
    @AppStorage(RelayPostPasteKey.userDefaultsKey) private var settingPostPasteKey = RelayPostPasteKey.none.rawValue
    @AppStorage("relayAutomationRuleId") private var settingAutomationRuleId = ""
    @AppStorage("relayPreviewEnabled") private var settingPreviewEnabled = false
    @Query(filter: #Predicate<AutomationRule> { $0.enabled == true })
    private var enabledRules: [AutomationRule]

    /// Actions to apply when previewing / rendering list text. Empty when preview is off
    /// or no rule is selected.
    private var previewActions: [RuleAction] {
        guard settingPreviewEnabled, !settingAutomationRuleId.isEmpty else { return [] }
        return enabledRules.first(where: { $0.ruleID == settingAutomationRuleId })?.actions ?? []
    }

    private var hasActiveSettings: Bool {
        settingPlainText
            || (RelayPostPasteKey(rawValue: settingPostPasteKey) ?? .none) != .none
            || !settingAutomationRuleId.isEmpty
    }

    private var settingsTooltip: String {
        var parts: [String] = []
        if settingPlainText {
            parts.append(L10n.tr("relay.settings.plainText"))
        }
        if !settingAutomationRuleId.isEmpty {
            parts.append(L10n.tr("relay.settings.automation"))
        }
        if let key = RelayPostPasteKey(rawValue: settingPostPasteKey), key != .none {
            parts.append(L10n.tr("relay.settings.postPasteKey") + ": " + postPasteKeyDisplay(key))
        }
        if parts.isEmpty {
            return L10n.tr("relay.settings.tooltip.default")
        }
        return L10n.tr("relay.settings.tooltip.active") + ": " + parts.joined(separator: " · ")
    }

    private func postPasteKeyDisplay(_ key: RelayPostPasteKey) -> String {
        switch key {
        case .none: return L10n.tr("relay.settings.postPasteKey.none")
        case .return: return L10n.tr("relay.settings.postPasteKey.return")
        case .tab: return L10n.tr("relay.settings.postPasteKey.tab")
        case .space: return L10n.tr("relay.settings.postPasteKey.space")
        case .up: return L10n.tr("relay.settings.postPasteKey.up")
        case .down: return L10n.tr("relay.settings.postPasteKey.down")
        case .left: return L10n.tr("relay.settings.postPasteKey.left")
        case .right: return L10n.tr("relay.settings.postPasteKey.right")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            queueList
            footerBar
        }
        // Width is controlled by parent (RelayPanelWidthWrapper)
        .background(Color.clear)
        .onChange(of: splitTargetIndex) {
            guard let index = splitTargetIndex, index < manager.items.count else { return }
            SplitWindowController.shared.show(text: manager.items[index].content) { delimiter in
                _ = manager.splitItem(at: index, by: delimiter)
            }
            splitTargetIndex = nil
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: manager.isPaused ? "pause.circle.fill" : "arrow.right.arrow.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(manager.isPaused ? .orange : .primary)
                Text(manager.isPaused ? L10n.tr("relay.paused") : L10n.tr("relay.title"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(manager.currentIndex)/\(manager.items.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                headerButton(icon: "arrow.up.arrow.down", title: L10n.tr("relay.reverse")) {
                    manager.reverseItems()
                }
                .disabled(manager.items.isEmpty)

                headerButton(icon: "trash", title: L10n.tr("relay.clearAll")) {
                    manager.clearAll()
                }
                .disabled(manager.items.isEmpty)

                Spacer()

                Button {
                    showSettingsPopover.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())

                        if hasActiveSettings {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 6, height: 6)
                                .overlay(
                                    Circle()
                                        .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1)
                                )
                                .offset(x: 2, y: -2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(settingsTooltip)
                .popover(isPresented: $showSettingsPopover, arrowEdge: .top) {
                    RelaySettingsPopover()
                        .modelContainer(PasteMemoApp.sharedModelContainer)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(WindowDragArea())
    }

    private func headerButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Queue List

    @ViewBuilder
    private var queueList: some View {
        if manager.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Text(L10n.tr("relay.emptyHint"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(L10n.tr("relay.quickPastePaused"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(manager.items.enumerated()), id: \.element.id) { index, item in
                            RelayQueueRow(item: item, previewActions: previewActions, onDelete: {
                                manager.deleteItem(at: index)
                            }, onSplit: {
                                splitTargetIndex = index
                            }, onEdit: { newContent in
                                manager.updateItem(at: index, content: newContent)
                            })
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onDrag {
                                    draggingItem = item
                                    return NSItemProvider(object: item.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: RelayDropDelegate(
                                    targetIndex: index,
                                    manager: manager,
                                    draggingItem: $draggingItem
                                ))
                                .contextMenu {
                                    if item.content.count > 1 {
                                        Button(L10n.tr("relay.split")) {
                                            splitTargetIndex = index
                                        }
                                    }
                                    Button(L10n.tr("relay.delete"), role: .destructive) {
                                        manager.deleteItem(at: index)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
                .onChange(of: manager.currentIndex) {
                    if let current = manager.currentItem {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(current.id, anchor: .center)
                        }
                    }
                }
                .onChange(of: manager.items.count) {
                    if let last = manager.items.last {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(100))
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $manager.autoExitOnEmpty) {
                        Text(L10n.tr("relay.autoExit.short"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }

                Spacer()

                HStack(spacing: 12) {
                    if manager.currentIndex > 0 {
                        Button {
                            manager.rollback()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(L10n.tr("relay.previous"))
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    if !manager.isQueueExhausted {
                        Button {
                            manager.skip()
                        } label: {
                            HStack(spacing: 3) {
                                Text(L10n.tr("relay.skip"))
                                    .font(.system(size: 11))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    if manager.isPaused {
                        manager.resume()
                    } else {
                        manager.pause()
                    }
                } label: {
                    Text(manager.isPaused ? L10n.tr("relay.resume") : L10n.tr("relay.pause"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(manager.isPaused ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            manager.isPaused ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.primary.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    manager.deactivate()
                } label: {
                    Text(L10n.tr("relay.exit"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    manager.deactivate(clearQueue: true)
                } label: {
                    Text(L10n.tr("relay.clearAndExit"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(manager.items.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

}

// MARK: - Row

private struct RelayQueueRow: View {
    let item: RelayItem
    let previewActions: [RuleAction]
    var onDelete: (() -> Void)?
    var onSplit: (() -> Void)?
    var onEdit: ((String) -> Void)?
    @State private var isHovering = false
    @AppStorage(RelayPostPasteKey.userDefaultsKey) private var postPasteKeyRaw = RelayPostPasteKey.none.rawValue

    private var displayText: String {
        previewActions.isEmpty ? item.content : AutomationEngine.apply(previewActions, to: item.content)
    }

    var body: some View {
        HStack(spacing: 8) {
            stateIndicator
            if item.isImage {
                if let data = item.imageData, let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text("[Image]")
                    .lineLimit(1)
                    .font(.system(size: 13))
                    .foregroundStyle(textColor)
                    .strikethrough(item.state == .skipped, color: .secondary)
            } else if item.isFile {
                Image(systemName: "doc")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 13))
                    .foregroundStyle(textColor)
                    .strikethrough(item.state == .skipped, color: .secondary)
            } else {
                Text(displayText.replacingOccurrences(of: "\n", with: " ↵ "))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 13))
                    .foregroundStyle(textColor)
                    .strikethrough(item.state == .skipped, color: .secondary)
                    .onTapGesture(count: 2) { showEditAlert() }
            }
            Spacer(minLength: 0)
            if item.state == .current, !isHovering, let glyph = postPasteKeyGlyph {
                Text(glyph)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .transition(.opacity)
            }
            if isHovering {
                if !item.isImage, !item.isFile, item.content.count > 1 {
                    Button { onSplit?() } label: {
                        Image(systemName: "scissors")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
                if !item.isImage, !item.isFile {
                    Button { showEditAlert() } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
                Button { onDelete?() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(rowBackground))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }

    private var postPasteKeyGlyph: String? {
        guard let key = RelayPostPasteKey(rawValue: postPasteKeyRaw), key != .none else { return nil }
        switch key {
        case .none: return nil
        case .return: return "⏎"
        case .tab: return "⇥"
        case .space: return "␣"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        }
    }

    private func showEditAlert() {
        RelayManager.shared.pauseHotkeys()
        RelayEditPanel.show(content: item.content) { newContent in
            onEdit?(newContent)
            RelayManager.shared.resumeHotkeys()
        } onCancel: {
            RelayManager.shared.resumeHotkeys()
        }
    }

    private var rowBackground: Color {
        if item.state == .current { return Color.accentColor.opacity(0.12) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch item.state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Color.green, in: Circle())
        case .current:
            Image(systemName: "play.fill")
                .font(.system(size: 6))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Color.accentColor, in: Circle())
        case .skipped:
            Image(systemName: "minus")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 14)
                .background(Color.primary.opacity(0.06), in: Circle())
        case .pending:
            Circle()
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1.5)
                .frame(width: 14, height: 14)
        }
    }

    private var textColor: Color {
        switch item.state {
        case .done, .skipped: .secondary
        case .current: .primary
        case .pending: .primary.opacity(0.8)
        }
    }
}

// MARK: - Drag & Drop

private struct RelayDropDelegate: DropDelegate {
    let targetIndex: Int
    let manager: RelayManager
    @Binding var draggingItem: RelayItem?

    func performDrop(info: DropInfo) -> Bool {
        draggingItem = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingItem,
              let fromIndex = manager.items.firstIndex(where: { $0.id == dragging.id }),
              fromIndex != targetIndex else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            manager.moveItem(from: IndexSet(integer: fromIndex), to: targetIndex > fromIndex ? targetIndex + 1 : targetIndex)
        }
    }
}

// MARK: - Window Drag Area

/// An invisible NSView that handles window dragging via mouseDown+mouseDragged.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableView {
        DraggableView()
    }

    func updateNSView(_ nsView: DraggableView, context: Context) {}
}

private final class DraggableView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}


