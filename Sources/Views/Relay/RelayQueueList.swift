import SwiftUI

/// 抽屉里的队列列表：标题（"队列 N"）+ 反转 / 清空 按钮 + 滚动列表（含拖放重排）。
struct RelayQueueList: View {
    @Bindable var manager: RelayManager
    let previewRule: AutomationRule?
    @State private var splitTargetIndex: Int?
    @State private var draggingItem: RelayItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            if manager.items.isEmpty {
                RelayEmptyState()
            } else {
                list
            }
        }
        .onChange(of: splitTargetIndex) {
            guard let index = splitTargetIndex, index < manager.items.count else { return }
            SplitWindowController.shared.show(text: manager.items[index].content) { delimiter in
                _ = manager.splitItem(at: index, by: delimiter)
            }
            splitTargetIndex = nil
        }
    }

    private var header: some View {
        HStack {
            Text(String(format: L10n.tr("relay.queue.heading"), manager.items.count))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            headerButton(icon: "arrow.up.arrow.down", title: L10n.tr("relay.reverse"), tint: .secondary) {
                manager.reverseItems()
            }
            .disabled(manager.items.isEmpty)
            headerButton(icon: "trash", title: L10n.tr("relay.clearAll"), tint: .red) {
                manager.clearAll()
            }
            .disabled(manager.items.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(manager.items.enumerated()), id: \.element.id) { index, item in
                        RelayRow(
                            item: item,
                            previewRule: previewRule,
                            onDelete: { manager.deleteItem(at: index) },
                            onSplit: { splitTargetIndex = index }
                        )
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
                        .onTapGesture(count: 2) {
                            manager.jumpTo(index: index)
                        }
                        .contextMenu {
                            if item.state != .current {
                                Button(L10n.tr("relay.setCurrent")) {
                                    manager.jumpTo(index: index)
                                }
                            }
                            if item.content.count > 1 {
                                Button(L10n.tr("relay.split")) { splitTargetIndex = index }
                            }
                            Button(L10n.tr("relay.delete"), role: .destructive) {
                                manager.deleteItem(at: index)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .frame(maxHeight: 400)
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

    private func headerButton(icon: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 11))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
