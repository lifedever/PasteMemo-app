import SwiftData
import SwiftUI

/// 接力浮窗外壳：组装 HeroCard + 可选展开的 QueueList + 撤销 toast overlay。
/// 原来在此文件里的 header / list / footer / row 已拆到独立文件。
struct RelayQueueView: View {
    @Bindable var manager: RelayManager
    /// Sticky "closed" flag. When true, the drawer is always closed regardless of
    /// queue size; user must click "展开" to clear it. When false, the drawer
    /// auto-follows queue size (>=1 item = open, empty = closed).
    @AppStorage("relayDrawerUserSuppressed") private var userSuppressed: Bool = false
    @AppStorage("relayAutomationRuleId") private var settingAutomationRuleId = ""
    @AppStorage("relayPreviewEnabled") private var settingPreviewEnabled = false
    @Query(filter: #Predicate<AutomationRule> { $0.enabled == true })
    private var enabledRules: [AutomationRule]

    /// Actual drawer visibility: auto-follow mode + at least one item in queue.
    private var drawerOpen: Bool {
        !userSuppressed && manager.items.count >= 1
    }

    /// 预览 diff 只在启用预览且规则选中时生效。
    private var previewRule: AutomationRule? {
        guard settingPreviewEnabled, !settingAutomationRuleId.isEmpty else { return nil }
        return enabledRules.first { $0.ruleID == settingAutomationRuleId }
    }

    /// Toggles between "sticky closed" and "auto-follow". Called from the Hero's
    /// drawer chevron button.
    private func toggleDrawer() {
        userSuppressed.toggle()
    }

    var body: some View {
        VStack(spacing: 0) {
            RelayHeroCard(manager: manager, drawerOpen: drawerOpen, onToggleDrawer: toggleDrawer)
            drawerContent
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        )
        .overlay(alignment: .top) {
            if let handle = manager.lastRecirculation {
                RelayUndoToast(
                    message: L10n.tr("relay.deleted.recirculated"),
                    actionTitle: L10n.tr("relay.deleted.undo")
                ) {
                    manager.undoLastRecirculation()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(handle.relayItem.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: manager.lastRecirculation?.relayItem.id)
    }

    /// Drawer stays in the view tree always; its height collapses to 0 when closed.
    /// This keeps Hero's layout slot stable — no move transition, no VStack reflow.
    @ViewBuilder private var drawerContent: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            RelayQueueList(manager: manager, previewRule: previewRule)
        }
        .frame(maxHeight: drawerOpen ? nil : 0, alignment: .top)
        .opacity(drawerOpen ? 1 : 0)
        .clipped()
    }
}

// MARK: - Drag & Drop

struct RelayDropDelegate: DropDelegate {
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
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableView {
        DraggableView()
    }

    func updateNSView(_ nsView: DraggableView, context: Context) {}
}

final class DraggableView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
