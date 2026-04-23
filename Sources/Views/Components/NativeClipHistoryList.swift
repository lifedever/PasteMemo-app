import SwiftUI
import AppKit
import SwiftData

enum NativeClipHistoryScrollAlignment {
    case nearest
    case center
}

enum ClipHistoryListBuilder {
    enum Row: Equatable {
        case header(TimeGroup)
        case item(PersistentIdentifier)
    }

    static func makeRows(from groups: [GroupedItem<ClipItem>]) -> [Row] {
        // 先把按时间分组的数据拍平成线性 header/item 序列，交给 NSTableView 做原生虚拟化。
        var rows: [Row] = []
        rows.reserveCapacity(groups.reduce(0) { $0 + $1.items.count + 1 })
        for group in groups {
            rows.append(.header(group.group))
            rows.append(contentsOf: group.items.map { .item($0.persistentModelID) })
        }
        return rows
    }

    static func rowIndexByItemID(rows: [Row]) -> [PersistentIdentifier: Int] {
        // 维护 itemID -> 行号映射，避免选中同步和程序化滚动时再次线性查找。
        var map: [PersistentIdentifier: Int] = [:]
        map.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if case .item(let id) = row {
                map[id] = index
            }
        }
        return map
    }
}

enum ClipHistorySelectionHelper {
    static func resolvedAnchor<ID>(
        existingAnchor: ID?,
        focusedID: ID?,
        fallbackSelectedID: ID?,
        targetID: ID
    ) -> ID {
        existingAnchor ?? focusedID ?? fallbackSelectedID ?? targetID
    }

    static func rangeSelection<ID: Hashable>(orderedIDs: [ID], anchorID: ID, targetID: ID) -> Set<ID>? {
        guard let anchorIndex = orderedIDs.firstIndex(of: anchorID),
              let targetIndex = orderedIDs.firstIndex(of: targetID) else {
            return nil
        }
        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        return Set(orderedIDs[range])
    }
}

enum ClipHistoryPaginationHelper {
    static func shouldResetPendingLoadMore(previousRowCount: Int, newRowCount: Int, canLoadMore: Bool) -> Bool {
        !canLoadMore || newRowCount != previousRowCount
    }

    static func shouldRequestLoadMore(
        totalRows: Int,
        lastVisibleRow: Int,
        pendingLoadMore: Bool,
        canLoadMore: Bool,
        threshold: Int = 8
    ) -> Bool {
        guard canLoadMore, !pendingLoadMore else { return false }
        return totalRows - lastVisibleRow <= threshold
    }
}

struct NativeClipHistoryList<RowContent: View, HeaderContent: View, ContextMenuContent: View, PaletteContent: View>: NSViewRepresentable {
    let rows: [ClipHistoryListBuilder.Row]
    let rowIndexByItemID: [PersistentIdentifier: Int]
    let itemsByID: [PersistentIdentifier: ClipItem]
    let canLoadMore: Bool
    let selectedItemIDs: Set<PersistentIdentifier>
    let focusedItemID: PersistentIdentifier?
    let scrollTargetID: PersistentIdentifier?
    let showCommandPalette: Bool
    let allowMultipleSelection: Bool
    let scrollAlignment: NativeClipHistoryScrollAlignment
    let itemRowHeight: CGFloat
    let headerRowHeight: CGFloat
    let onItemTap: (PersistentIdentifier) -> Void
    let onItemRightClick: (PersistentIdentifier) -> Void
    let onCommandPaletteDismiss: () -> Void
    let onLoadMore: () -> Void
    let rowContent: (ClipItem, Bool) -> RowContent
    let headerContent: (TimeGroup) -> HeaderContent
    let contextMenu: (ClipItem) -> ContextMenuContent
    let commandPaletteContent: (ClipItem) -> PaletteContent

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let tableView = NativeClipHistoryTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        // 行间留一点点空隙，减少大量相邻行挤在一起的压迫感。
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.allowsMultipleSelection = allowMultipleSelection
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("NativeClipHistoryColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        context.coordinator.install(scrollView: scrollView, tableView: tableView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let structureChanged = context.coordinator.applyRows(rows)
        context.coordinator.applyPaginationState(canLoadMore: canLoadMore)
        context.coordinator.applySelection(selectedItemIDs)
        context.coordinator.applyScrollTarget(scrollTargetID)
        // 结构变化时 NSTableView 会通过 viewFor 用最新 rootView 重建 cell；
        // 只有结构没变但 selection / focus / palette 变化时才需要手动刷新可见行。
        if !structureChanged {
            context.coordinator.updateVisibleRowsIfNeeded()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeClipHistoryList

        private weak var scrollView: NSScrollView?
        private weak var tableView: NativeClipHistoryTableView?
        private var lastAppliedRows: [ClipHistoryListBuilder.Row] = []
        private var pendingLoadMore = false
        private var lastScrolledTargetID: PersistentIdentifier?
        // 缓存上一次同步到 cell 的行级状态，避免每次 updateNSView 都重刷整个可见区。
        private var lastSelectedItemIDs: Set<PersistentIdentifier> = []
        private var lastFocusedItemID: PersistentIdentifier?
        private var lastShowCommandPalette = false

        init(parent: NativeClipHistoryList) {
            self.parent = parent
        }

        fileprivate func install(scrollView: NSScrollView, tableView: NativeClipHistoryTableView) {
            self.scrollView = scrollView
            self.tableView = tableView
            tableView.onBoundsChanged = { [weak self] in
                self?.maybeTriggerLoadMore()
            }
        }

        func teardown() {
            tableView?.delegate = nil
            tableView?.dataSource = nil
            tableView?.onBoundsChanged = nil
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row < parent.rows.count else { return false }
            if case .item = parent.rows[row] {
                return true
            }
            return false
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < parent.rows.count else { return 0 }
            switch parent.rows[row] {
            case .header:
                return parent.headerRowHeight
            case .item:
                return parent.itemRowHeight
            }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < parent.rows.count else { return nil }

            let container = NativeClipHistoryRowContainerView()
            let hostingView = NSHostingView(rootView: makeRowView(for: row))
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            container.host(hostingView)
            return container
        }

        /// - Returns: `true` 当且仅当表格结构真的被更新（insert/remove/reload）。
        ///   结构变时 NSTableView 会通过 viewFor 用最新 rootView 重建 cell，
        ///   调用方可据此跳过后续的可见行手动刷新。
        @discardableResult
        func applyRows(_ rows: [ClipHistoryListBuilder.Row]) -> Bool {
            guard let tableView else {
                lastAppliedRows = rows
                return false
            }

            let previousRows = lastAppliedRows
            let previousCount = previousRows.count
            let newCount = rows.count
            guard rows != previousRows else { return false }

            lastAppliedRows = rows

            // 尾部分页是这里最常见的更新形态，优先走增量插入/删除，避免整表 reload。
            if newCount > previousCount,
               previousCount > 0,
               rows.starts(with: previousRows) {
                let inserted = IndexSet(integersIn: previousCount..<newCount)
                tableView.beginUpdates()
                tableView.insertRows(at: inserted, withAnimation: [])
                tableView.endUpdates()
            } else if previousCount > newCount,
                      previousCount > 0,
                      Array(previousRows.prefix(newCount)) == rows {
                let removed = IndexSet(integersIn: newCount..<previousCount)
                tableView.beginUpdates()
                tableView.removeRows(at: removed, withAnimation: [])
                tableView.endUpdates()
            } else {
                tableView.reloadData()
            }

            if pendingLoadMore,
               ClipHistoryPaginationHelper.shouldResetPendingLoadMore(
                   previousRowCount: previousCount,
                   newRowCount: newCount,
                   canLoadMore: parent.canLoadMore
               ) {
                pendingLoadMore = false
            }

            // 等 NSTableView 这轮 insert/remove/reload 的 layout 落地后，
            // 再重新根据可见区判断要不要续页。applyRows 本身已在主线程，
            // 这里只是把 check 推到下一个 runloop tick。
            DispatchQueue.main.async { [weak self] in
                self?.maybeTriggerLoadMore()
            }
            return true
        }

        func applyPaginationState(canLoadMore: Bool) {
            if !canLoadMore {
                pendingLoadMore = false
            }
        }

        func applySelection(_ selectedItemIDs: Set<PersistentIdentifier>) {
            guard let tableView else { return }
            let rows = IndexSet(selectedItemIDs.compactMap { parent.rowIndexByItemID[$0] })
            // 这里只同步选中态，不顺带滚动，避免列表刷新时把用户视口强行拉走。
            guard tableView.selectedRowIndexes != rows else { return }
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }

        func applyScrollTarget(_ scrollTargetID: PersistentIdentifier?) {
            guard tableView != nil else { return }
            guard let scrollTargetID,
                  let row = parent.rowIndexByItemID[scrollTargetID]
            else {
                lastScrolledTargetID = nil
                return
            }
            // 只有滚动目标真的变化时才触发程序化滚动，用来修复 quick panel 之前的“偶发回顶”。
            guard lastScrolledTargetID != scrollTargetID else { return }
            lastScrolledTargetID = scrollTargetID
            scrollToRow(row)
        }

        /// 只在 selection / focus / palette 之类影响 cell 渲染的行级状态真变了时才刷新，
        /// 避免搜索输入等高频 SwiftUI 更新都无谓地重建每个可见行的 rootView。
        func updateVisibleRowsIfNeeded() {
            let needsUpdate = lastSelectedItemIDs != parent.selectedItemIDs
                || lastFocusedItemID != parent.focusedItemID
                || lastShowCommandPalette != parent.showCommandPalette
            guard needsUpdate else { return }
            lastSelectedItemIDs = parent.selectedItemIDs
            lastFocusedItemID = parent.focusedItemID
            lastShowCommandPalette = parent.showCommandPalette
            refreshVisibleRows()
        }

        private func refreshVisibleRows() {
            guard let tableView else { return }
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            guard visibleRange.length > 0 else { return }
            let upper = visibleRange.location + visibleRange.length
            for row in visibleRange.location..<upper {
                guard row < parent.rows.count,
                      let container = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeClipHistoryRowContainerView,
                      let hostingView = container.hostedView
                else { continue }
                hostingView.rootView = makeRowView(for: row)
            }
        }

        private func makeRowView(for row: Int) -> AnyView {
            guard row < parent.rows.count else {
                return AnyView(EmptyView())
            }

            switch parent.rows[row] {
            case .header(let group):
                return AnyView(self.parent.headerContent(group))
            case .item(let id):
                guard let item = self.parent.itemsByID[id], !item.isDeleted else {
                    return AnyView(EmptyView())
                }
                return AnyView(
                    self.parent.rowContent(item, self.parent.selectedItemIDs.contains(id))
                        .contentShape(Rectangle())
                        .popover(
                            isPresented: Binding(
                                get: { [self] in
                                    self.parent.showCommandPalette &&
                                    self.parent.selectedItemIDs.contains(id) &&
                                    self.parent.focusedItemID == id
                                },
                                set: { [self] in
                                    if !$0 { self.parent.onCommandPaletteDismiss() }
                                }
                            ),
                            arrowEdge: .trailing
                        ) {
                            self.parent.commandPaletteContent(item)
                        }
                        .contextMenu {
                            self.parent.contextMenu(item)
                        }
                        .onTapGesture { [self] in
                            self.parent.onItemTap(id)
                        }
                        .onRightClick { [self] in
                            self.parent.onItemRightClick(id)
                        }
                )
            }
        }

        private func maybeTriggerLoadMore() {
            guard let tableView else { return }
            guard parent.canLoadMore else {
                pendingLoadMore = false
                return
            }
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.length > 0 else { return }
            let lastVisibleRow = visibleRows.location + visibleRows.length - 1
            guard ClipHistoryPaginationHelper.shouldRequestLoadMore(
                totalRows: parent.rows.count,
                lastVisibleRow: lastVisibleRow,
                pendingLoadMore: pendingLoadMore,
                canLoadMore: parent.canLoadMore
            ) else { return }
            // 接近底部时只触发一次分页，等本轮 rows 真正增长后再放开下一次触发。
            pendingLoadMore = true
            parent.onLoadMore()
        }

        private func scrollToRow(_ row: Int) {
            guard let tableView else { return }
            tableView.scrollRowToVisible(row)

            // 主界面保留原来接近 ScrollViewReader(anchor: .center) 的定位语义；
            // quick panel 则保持 nearest，只要可见即可，避免滚动感过重。
            guard parent.scrollAlignment == .center,
                  let scrollView
            else { return }

            let rowRect = tableView.rect(ofRow: row)
            guard !rowRect.isEmpty else { return }

            let clipView = scrollView.contentView
            let visibleRect = clipView.documentVisibleRect
            let maxY = max(0, tableView.bounds.height - visibleRect.height)
            let centeredY = rowRect.midY - (visibleRect.height / 2)
            let targetY = min(max(0, centeredY), maxY)
            guard abs(targetY - clipView.bounds.origin.y) > 1 else { return }

            clipView.animator().setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
        }

    }
}

private final class NativeClipHistoryTableView: NSTableView {
    var onBoundsChanged: (@MainActor () -> Void)?
    private var observingClipView = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clipView = enclosingScrollView?.contentView, !observingClipView else { return }
        enclosingScrollView?.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
        observingClipView = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        // boundsDidChange 通知已经在主线程，直接回调，不需要再 hop 一次 Task。
        MainActor.assumeIsolated { onBoundsChanged?() }
    }
}

private final class NativeClipHistoryRowContainerView: NSTableCellView {
    // 保留一个明确的引用，行级状态变化时可以直接写 rootView 更新内容，
    // 不用靠在 subviews 里试探 / 维护一份外部 dict。
    private(set) weak var hostedView: NSHostingView<AnyView>?

    func host(_ hostingView: NSHostingView<AnyView>) {
        subviews.forEach { $0.removeFromSuperview() }
        addSubview(hostingView)
        hostedView = hostingView
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
