import SwiftUI
import SwiftData
import AppKit

enum SidebarFilter: Equatable {
    case all
    case pinned
    case sensitive
    case type(ClipContentType)
    case app(String)
    case group(String)

    @MainActor
    var title: String {
        switch self {
        case .all: return L10n.tr("filter.all")
        case .pinned: return L10n.tr("filter.pinned")
        case .sensitive: return L10n.tr("filter.sensitive")
        case .type(let t): return t.label
        case .app(let name): return name.isEmpty ? L10n.tr("filter.other") : name
        case .group(let name): return name
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject var clipboardManager: ClipboardManager
    @Environment(\.modelContext) private var modelContext
    @State private var store = ClipItemStore()
    @State private var searchText = ""
    @State private var selectedFilter: SidebarFilter = .all
    @State private var selectedItems: Set<ClipItem.ID> = []
    @State private var typeOrder: [ClipContentType] = ClipContentType.visibleCases
    @State private var draggingType: ClipContentType?
    @State private var draggingGroup: String?

    private var selectedItem: ClipItem? {
        guard selectedItems.count == 1, let id = selectedItems.first else { return nil }
        return store.items.first { $0.persistentModelID == id }
    }
    @Environment(\.openWindow) private var openWindow
    @State private var showDeleteConfirm = false
    @State private var isClearing = false
    @State private var clearTitle = ""
    @State private var clearProgress: Double = 0
    @State private var clearProgressText = ""
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var scrollTarget: ClipItem.ID?
    @State private var relaySplitText: String?
    @State private var showCommandPalette = false
    @State private var cachedGroupedItems: [GroupedItem<ClipItem>] = []
    @State private var cachedHistoryRows: [ClipHistoryListBuilder.Row] = []
    @State private var cachedHistoryRowIndexByID: [PersistentIdentifier: Int] = [:]
    @State private var cachedHistoryItemMap: [PersistentIdentifier: ClipItem] = [:]
    @State private var cachedVisualOrderedItems: [ClipItem] = []
    @AppStorage("hideDockIcon") private var hideDockIcon = false
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    private var sourceApps: [String] { store.sourceApps }

    private func bundleIDForApp(_ appName: String) -> String? {
        store.items.first { $0.sourceApp == appName }?.sourceAppBundleID
    }

    private var filteredItems: [ClipItem] { store.items.filter { !$0.isDeleted } }

    private func rebuildHistoryCache() {
        // 主界面滚动时如果每次 body 重算都重新分组/建索引，会比 quick panel 明显更卡。
        // 这里把历史列表需要的派生数据一次性缓存，后续滚动只读缓存结果。
        cachedGroupedItems = groupItemsByTime(filteredItems)
        cachedHistoryRows = ClipHistoryListBuilder.makeRows(from: cachedGroupedItems)
        cachedHistoryRowIndexByID = ClipHistoryListBuilder.rowIndexByItemID(rows: cachedHistoryRows)
        cachedVisualOrderedItems = cachedGroupedItems.flatMap(\.items)
        cachedHistoryItemMap = Dictionary(cachedVisualOrderedItems.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { _, last in last })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            clipListView
        } detail: {
            detailView
        }
        .searchable(text: $searchText, prompt: L10n.tr("search.placeholder"))
        .onChange(of: selectedFilter) {
            selectedItems.removeAll()
            selectionAnchor = nil
            syncStoreFilter()
        }
        .onChange(of: searchText) {
            selectedItems.removeAll()
            selectionAnchor = nil
            store.searchText = searchText
        }
        .onChange(of: store.items) {
            rebuildHistoryCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("clearSelection"))) { _ in
            selectedItems.removeAll()
            selectionAnchor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("deleteSelectedFromDetail"))) { _ in
            deleteSelectedItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("copyItemFromDetail"))) { _ in
            ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("action.copied"), icon: .success))
        }
        .onAppear {
            store.sortPinnedFirst = true
            store.isActive = true
            store.configure(modelContext: modelContext)
            rebuildHistoryCache()
            if alwaysOnTop {
                DispatchQueue.main.async {
                    for window in NSApp.windows where window.canBecomeMain {
                        window.level = .floating
                    }
                }
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard let window = event.window, window.canBecomeMain,
                      !HotkeyManager.shared.isQuickPanelVisible else { return event }

                let firstResponder = window.firstResponder
                let isSearchFieldEditing: Bool = {
                    guard let textView = firstResponder as? NSTextView else { return false }
                    return textView.delegate is NSSearchField || textView.delegate is NSTextField
                }()

                // Check if an editable text view has focus (e.g. NativeTextView in edit mode)
                let isEditableTextViewActive: Bool = {
                    guard let textView = firstResponder as? NSTextView else { return false }
                    return textView.isEditable
                }()

                // When command palette is shown, only handle Cmd+K toggle, let palette handle the rest
                if showCommandPalette {
                    if event.keyCode == 40, event.modifierFlags.contains(.command) {
                        showCommandPalette = false
                        return nil
                    }
                    return event
                }

                // Arrow Down (125) / Arrow Up (126): list navigation
                if event.keyCode == 125 || event.keyCode == 126, !isEditableTextViewActive {
                    let direction: MoveDirection = event.keyCode == 125 ? .down : .up
                    let hasShift = event.modifierFlags.contains(.shift)
                    moveSelection(direction: direction, extendSelection: hasShift)
                    return nil
                }

                // Check if any text/web view has selected text
                let hasTextSelection: Bool = {
                    guard let r = firstResponder else { return false }
                    if let textView = r as? NSTextView {
                        return textView.selectedRange().length > 0
                    }
                    // WebView: assume it has selection if focused (can't easily check)
                    let className = String(describing: type(of: r))
                    if className.contains("Web") || className.contains("WK") { return true }
                    return false
                }()

                // Cmd+C: copy selected text if any, otherwise copy whole item
                if event.keyCode == 8, event.modifierFlags.contains(.command) {
                    if hasTextSelection { return event }  // let system handle
                    guard !isSearchFieldEditing, !selectedItems.isEmpty else { return event }
                    if selectedItems.count > 1 {
                        copySelectedToClipboard()
                    } else if let item = store.items.first(where: { selectedItems.contains($0.persistentModelID) }) {
                        copyToClipboard(item)
                    }
                    return nil
                }

                // Cmd+F: focus search field
                if event.keyCode == 3, event.modifierFlags.contains(.command) {
                    if let themeFrame = window.contentView?.superview,
                       let searchField = themeFrame.findSubview(ofType: NSSearchField.self) {
                        window.makeFirstResponder(searchField)
                    }
                    return nil
                }

                // Cmd+K: command palette
                if event.keyCode == 40, event.modifierFlags.contains(.command), !selectedItems.isEmpty {
                    showCommandPalette.toggle()
                    return nil
                }

                guard !isSearchFieldEditing, !isEditableTextViewActive else { return event }

                // Delete key
                if event.keyCode == 51, !selectedItems.isEmpty {
                    deleteSelectedItems()
                    return nil
                }
                // Space: Quick Look
                if event.keyCode == 49, selectedItems.count == 1,
                   let item = store.items.first(where: { selectedItems.contains($0.persistentModelID) }) {
                    QuickLookHelper.shared.toggle(item: item)
                    return nil
                }
                // Cmd+A: select all
                if event.keyCode == 0, event.modifierFlags.contains(.command) {
                    selectedItems = Set(filteredItems.map(\.persistentModelID))
                    return nil
                }
                return event
            }
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                guard let window = event.window, window.canBecomeMain,
                      !HotkeyManager.shared.isQuickPanelVisible else { return event }
                OptionKeyMonitor.shared.isOptionPressed = event.modifierFlags.contains(.option)
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
            if let monitor = flagsMonitor {
                NSEvent.removeMonitor(monitor)
                flagsMonitor = nil
            }
            OptionKeyMonitor.shared.isOptionPressed = false
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { clipboardManager.togglePause() } label: {
                    Label(
                        clipboardManager.isPaused ? L10n.tr("menu.resume") : L10n.tr("menu.pause"),
                        systemImage: clipboardManager.isPaused ? "play.circle" : "pause.circle"
                    )
                }
                .help(clipboardManager.isPaused ? L10n.tr("menu.resume") : L10n.tr("menu.pause"))
                .disabled(RelayManager.shared.isActive)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    if RelayManager.shared.isActive {
                        RelayManager.shared.deactivate()
                    } else {
                        RelayManager.shared.activate()
                    }
                } label: {
                    Label(
                        RelayManager.shared.isActive ? L10n.tr("relay.exitRelay") : L10n.tr("relay.startRelay"),
                        systemImage: "arrow.right.arrow.left"
                    )
                }
                .help(RelayManager.shared.isActive ? L10n.tr("relay.exitRelay") : L10n.tr("relay.startRelay"))
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    AppAction.shared.openSettings?()
                } label: {
                    Label(L10n.tr("settings.title"), systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button { showDeleteConfirm = true } label: {
                    Label(L10n.tr("action.clearAll"), systemImage: "trash")
                }
            }
        }
        .overlay {
        }
        .localized()
        .sheet(isPresented: $isClearing) {
            VStack(spacing: 16) {
                Text(clearTitle)
                    .font(.headline)
                ProgressView(value: clearProgress, total: 1.0)
                    .progressViewStyle(.linear)
                Text(clearProgressText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(30)
            .frame(width: 300)
            .interactiveDismissDisabled()
        }
        .alert(L10n.tr("action.clearAll"), isPresented: $showDeleteConfirm) {
            Button(L10n.tr("action.delete"), role: .destructive) {
                let descriptor = FetchDescriptor<ClipItem>(
                    predicate: #Predicate { !$0.isPinned }
                )
                if let items = try? modelContext.fetch(descriptor) {
                    let preserved = SmartGroupRetention.preservedGroupNames(in: modelContext)
                    let deletable = SmartGroupRetention.filterDeletableItems(items, preservedGroupNames: preserved)
                    runBulkClear(title: L10n.tr("action.clearAll"), items: deletable)
                }
            }
            Button(L10n.tr("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("action.clearConfirm"))
        }
        .onAppear {
            AppAction.shared.openMainWindow = { [openWindow] in
                openWindow(id: "main")
                if !UserDefaults.standard.bool(forKey: "hideDockIcon") {
                    NSApp.setActivationPolicy(.regular)
                }
                NSApp.activate(ignoringOtherApps: true)
                UsageTracker.pingIfNeeded(source: .main)
            }
        }
        .onChange(of: relaySplitText) {
            guard let text = relaySplitText else { return }
            SplitWindowController.shared.show(text: text) { delimiter in
                guard let parts = RelaySplitter.split(text, by: delimiter) else { return }
                RelayManager.shared.addToQueue(texts: parts)
            }
            relaySplitText = nil
        }
    }

    // MARK: - Sidebar

    private func syncStoreFilter() {
        store.pinnedOnly = false
        store.sensitiveOnly = false
        store.filterType = nil
        store.sourceApp = nil
        store.groupName = nil
        switch selectedFilter {
        case .all: break
        case .pinned: store.pinnedOnly = true
        case .sensitive: store.sensitiveOnly = true
        case .type(let t): store.filterType = t
        case .app(let name):
            store.sourceApp = name.isEmpty ? .unknown : .named(name)
        case .group(let name):
            store.groupName = name
        }
        store.applyFilters()
    }

    private var sidebar: some View {
        List {
            Section {
                sidebarRow(L10n.tr("filter.all"), icon: "tray.full", badge: store.sidebarCounts.all, isActive: selectedFilter == .all) {
                    selectedFilter = .all
                }

                let pinCount = store.sidebarCounts.pinned
                if pinCount > 0 {
                    sidebarRow(L10n.tr("filter.pinned"), icon: "pin", badge: pinCount, isActive: selectedFilter == .pinned) {
                        selectedFilter = .pinned
                    }
                }

                let sensitiveCount = store.sidebarCounts.sensitive
                if sensitiveCount > 0 {
                    sidebarRow(L10n.tr("filter.sensitive"), icon: "lock.shield", badge: sensitiveCount, isActive: selectedFilter == .sensitive) {
                        selectedFilter = .sensitive
                    }
                }
            }

            Section(L10n.tr("filter.types")) {
                ForEach(typeOrder, id: \.self) { type in
                    let count = store.sidebarCounts.byType[type] ?? 0
                    if count > 0 {
                        sidebarRow(type.label, icon: type.icon, badge: count, isActive: selectedFilter == .type(type)) {
                            selectedFilter = .type(type)
                        }
                        .contextMenu {
                            Button(L10n.tr("action.clearScope.type"), role: .destructive) {
                                clearItems(inScope: .type(type))
                            }
                        }
                        .onDrag {
                            draggingType = type
                            return NSItemProvider(object: type.rawValue as NSString)
                        }
                        .onDrop(of: [.text], delegate: TypeDropDelegate(
                            target: type,
                            dragging: $draggingType,
                            types: $typeOrder
                        ))
                    }
                }
            }

            if !store.sidebarCounts.byGroup.isEmpty {
                Section(L10n.tr("filter.groups")) {
                    ForEach(store.sidebarCounts.byGroup, id: \.name) { group in
                        sidebarRow(group.name, icon: group.icon, badge: group.count, showsPreservedBadge: group.preservesItems, isActive: selectedFilter == .group(group.name)) {
                            selectedFilter = .group(group.name)
                        }
                        .contextMenu {
                            Button(L10n.tr("action.editGroup")) {
                                editGroup(name: group.name)
                            }
                            Button(L10n.tr("action.changeIcon")) {
                                changeGroupIcon(name: group.name)
                            }
                            Divider()
                            Button(L10n.tr("action.clearScope.group"), role: .destructive) {
                                clearItems(inScope: .group(group.name))
                            }
                            .disabled(group.preservesItems)
                            .help(group.preservesItems ? L10n.tr("action.clearScope.group.disabledHelp") : "")
                            Button(L10n.tr("action.deleteGroup"), role: .destructive) {
                                let alert = NSAlert()
                                alert.messageText = L10n.tr("action.deleteGroup")
                                alert.informativeText = L10n.tr("action.deleteGroupConfirm", group.name)
                                alert.alertStyle = .warning
                                alert.addButton(withTitle: L10n.tr("action.delete"))
                                alert.addButton(withTitle: L10n.tr("action.cancel"))
                                guard alert.runModal() == .alertFirstButtonReturn else { return }
                                if selectedFilter == .group(group.name) {
                                    selectedFilter = .all
                                }
                                AppMenuActions.deleteGroup(name: group.name, context: modelContext)
                            }
                        }
                        .onDrag {
                            draggingGroup = group.name
                            return NSItemProvider(object: group.name as NSString)
                        }
                        .onDrop(of: [.text], delegate: GroupDropDelegate(
                            target: group.name,
                            dragging: $draggingGroup,
                            store: store,
                            modelContext: modelContext
                        ))
                    }
                }
            }

            Section(L10n.tr("filter.apps")) {
                ForEach(sourceApps, id: \.self) { appName in
                    let isUnknown = appName.isEmpty
                    let count = store.sidebarCounts.byApp[isUnknown ? nil : appName] ?? 0
                    let displayName = isUnknown ? L10n.tr("filter.other") : appName
                    appSidebarRow(displayName, badge: count, isActive: selectedFilter == .app(appName)) {
                        selectedFilter = .app(appName)
                    }
                    .contextMenu {
                        Button(L10n.tr("action.clearScope.app"), role: .destructive) {
                            clearItems(inScope: .app(appName))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
    }

    private func appSidebarRow(_ appName: String, badge: Int = 0, isActive: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            if let icon = appIcon(forBundleID: bundleIDForApp(appName), name: appName) {
                Image(nsImage: icon)
                    .renderingMode(.original)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app")
                    .foregroundStyle(isActive ? .white : .secondary)
                    .frame(width: 16)
            }
            Text(appName)
                .foregroundStyle(isActive ? .white : .primary)
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(isActive ? .white : .secondary)
                    .background(
                        isActive
                            ? Color.white.opacity(0.25)
                            : Color.primary.opacity(0.08),
                        in: Capsule()
                    )
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
    }

    private func sidebarRow(_ title: String, icon: String, badge: Int = 0, showsPreservedBadge: Bool = false, isActive: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(isActive ? .white : .secondary)
                .frame(width: 18)
            Text(title)
                .foregroundStyle(isActive ? .white : .primary)
            if showsPreservedBadge {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isActive ? .white.opacity(0.95) : .secondary)
                    .help(L10n.tr("group.preserveItems.badge"))
            }
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(isActive ? .white : .secondary)
                    .background(
                        isActive
                            ? Color.white.opacity(0.25)
                            : Color.primary.opacity(0.08),
                        in: Capsule()
                    )
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
    }

    // MARK: - Clip List

    private var groupedFilteredItems: [GroupedItem<ClipItem>] {
        cachedGroupedItems
    }

    private var historyRows: [ClipHistoryListBuilder.Row] {
        cachedHistoryRows
    }

    private var historyRowIndexByID: [PersistentIdentifier: Int] {
        cachedHistoryRowIndexByID
    }

    private var historyItemMap: [PersistentIdentifier: ClipItem] {
        cachedHistoryItemMap
    }

    /// Items in visual display order (matching grouped section rendering)
    private var visualOrderedItems: [ClipItem] {
        cachedVisualOrderedItems
    }

    private var clipListView: some View {
        NativeClipHistoryList(
            rows: historyRows,
            rowIndexByItemID: historyRowIndexByID,
            itemsByID: historyItemMap,
            canLoadMore: store.hasMore,
            selectedItemIDs: selectedItems,
            focusedItemID: navigationCursor ?? selectedItems.first,
            scrollTargetID: scrollTarget,
            showCommandPalette: showCommandPalette,
            allowMultipleSelection: true,
            scrollAlignment: .center,
            itemRowHeight: 48,
            headerRowHeight: 28,
            onItemTap: { id in
                guard let item = historyItemMap[id] else { return }
                handleRowClick(item)
            },
            onItemRightClick: { id in
                if !selectedItems.contains(id) {
                    selectedItems = [id]
                    navigationCursor = id
                    selectionAnchor = id
                }
            },
            onCommandPaletteDismiss: {
                showCommandPalette = false
            },
            onLoadMore: {
                store.loadMore()
            },
            rowContent: { item, isSelected in
                mainListRowContent(item: item, isSelected: isSelected)
            },
            headerContent: { group in
                Text(group.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
            },
            contextMenu: { item in
                mainListContextMenu(item: item)
            },
            commandPaletteContent: { item in
                CommandPaletteContent(
                    item: item,
                    isMultiSelected: selectedItems.count > 1,
                    manualRules: manualRulesForPalette(item: item),
                    preservedGroupNames: SmartGroupRetention.preservedGroupNames(in: modelContext),
                    onAction: { handleMainCommandAction($0, item: item) },
                    onDismiss: { showCommandPalette = false }
                )
            }
        )
        .onChange(of: scrollTarget) { _, target in
            guard target != nil else { return }
            // 只把 scrollTarget 当成一次性脉冲使用，交给原生列表消费后立即清掉。
            DispatchQueue.main.async {
                scrollTarget = nil
            }
        }
        .navigationTitle(selectedFilter.title)
        .navigationSubtitle("\(store.totalCount) \(L10n.tr("stats.clips"))")
        .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 450)
    }

    private func mainListRowContent(item: ClipItem, isSelected: Bool) -> some View {
        ClipItemListRow(
            item: item,
            isSelected: isSelected,
            groupIcon: store.sidebarCounts.byGroup.first { $0.name == item.groupName }?.icon,
            searchText: searchText
        )
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
            )
            .padding(.trailing, 4)
    }

    @ViewBuilder
    private func mainListContextMenu(item: ClipItem) -> some View {
        if item.isDeleted { EmptyView() } else {
            Button(item.isPinned ? L10n.tr("action.unpin") : L10n.tr("action.pin")) {
                if selectedItems.contains(item.persistentModelID), selectedItems.count > 1 {
                    let items = selectedClipItems
                    let shouldPin = !items.contains(where: \.isPinned)
                    for i in items { i.isPinned = shouldPin }
                } else {
                    item.isPinned.toggle()
                }
                ClipItemStore.saveAndNotify(modelContext)
                selectedItems.removeAll()
            }
            Button(item.isSensitive ? L10n.tr("sensitive.unmarkSensitive") : L10n.tr("sensitive.markSensitive")) {
                if selectedItems.contains(item.persistentModelID), selectedItems.count > 1 {
                    let items = selectedClipItems
                    let hasSensitive = items.contains(where: \.isSensitive)
                    for i in items { i.isSensitive = !hasSensitive }
                } else {
                    item.isSensitive.toggle()
                }
                ClipItemStore.saveAndNotify(modelContext)
            }
            Button(L10n.tr("action.mergeCopy")) {
                if selectedItems.contains(item.persistentModelID), selectedItems.count > 1 {
                    copySelectedToClipboard()
                } else {
                    copyToClipboard(item)
                }
            }
            if selectedItems.count > 1, selectedClipItems.allSatisfy({ $0.contentType.isMergeable }) {
                Button(L10n.tr("action.merge")) { mergeSelectedItems() }
            }
            if ProManager.AUTOMATION_ENABLED {
                let applicableRules = fetchEnabledAutomationRules()
                    .filter { $0.triggerMode == .manual && $0.matches(item: item) }
                if !applicableRules.isEmpty {
                    Divider()
                    Menu(L10n.tr("cmd.automation")) {
                        ForEach(applicableRules) { rule in
                            Button(rule.isBuiltIn ? L10n.tr(rule.name) : rule.name) {
                                applyAutomationRule(rule, to: item)
                            }
                        }
                    }
                }
            }
            Divider()
            let targetItems = selectedItems.contains(item.persistentModelID) ? selectedClipItems : [item]
            let groupNames = Set(targetItems.compactMap(\.groupName))
            let currentGroup = groupNames.count == 1 ? groupNames.first : nil
            Menu(L10n.tr("action.assignGroup")) {
                ForEach(store.sidebarCounts.byGroup, id: \.name) { group in
                    if group.name == currentGroup {
                        Button {} label: {
                            Label(group.name, systemImage: "checkmark")
                        }
                    } else {
                        Button(group.name) {
                            assignToGroup(items: targetItems, name: group.name)
                        }
                    }
                }
                if !store.sidebarCounts.byGroup.isEmpty {
                    Divider()
                }
                Button(L10n.tr("action.newGroup")) {
                    showNewGroupAlert(for: targetItems)
                }
            }
            if targetItems.contains(where: { $0.groupName != nil }) {
                Button(L10n.tr("action.removeFromGroup")) {
                    removeFromGroup(items: targetItems)
                }
            }
            Divider()
            if selectedItems.count > 1 {
                Button(L10n.tr("relay.addToQueue")) {
                    RelayManager.shared.addToQueue(clipItems: selectedClipItems)
                }
            } else if !item.content.isEmpty || item.imageData != nil {
                Button(L10n.tr("relay.addToQueue")) {
                    RelayManager.shared.addToQueue(clipItems: [item])
                }
                Button(L10n.tr("relay.splitAndRelay")) {
                    relaySplitText = item.content
                }
            }
            Divider()
            Button(L10n.tr("action.delete"), role: .destructive) {
                if !selectedItems.contains(item.persistentModelID) {
                    selectedItems = [item.persistentModelID]
                }
                deleteSelectedItems()
            }
        }
    }

    private func handleRowClick(_ item: ClipItem) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let id = item.persistentModelID
        let previousCursor = navigationCursor
        navigationCursor = id

        if flags.contains(.command) {
            // Cmd+Click: toggle this item in selection
            if selectedItems.contains(id) {
                selectedItems.remove(id)
                if selectionAnchor == id {
                    selectionAnchor = previousCursor == id ? nil : previousCursor
                }
            } else {
                selectedItems.insert(id)
                selectionAnchor = selectionAnchor ?? id
            }
        } else if flags.contains(.shift) {
            // Shift+Click: range select
            let items = visualOrderedItems
            let anchor = ClipHistorySelectionHelper.resolvedAnchor(
                existingAnchor: selectionAnchor,
                focusedID: previousCursor,
                fallbackSelectedID: selectedItems.first,
                targetID: id
            )
            guard let selection = ClipHistorySelectionHelper.rangeSelection(
                orderedIDs: items.map(\.persistentModelID),
                anchorID: anchor,
                targetID: id
            ) else {
                selectedItems = [id]
                selectionAnchor = id
                return
            }
            selectedItems = selection
            selectionAnchor = anchor
        } else {
            if selectedItems == [id] {
                selectedItems.removeAll()
                selectionAnchor = nil
            } else {
                selectedItems = [id]
                selectionAnchor = id
            }
        }
    }

    private enum MoveDirection { case up, down }

    @State private var navigationCursor: ClipItem.ID?
    @State private var selectionAnchor: ClipItem.ID?

    private func moveSelection(direction: MoveDirection, extendSelection: Bool = false) {
        let items = visualOrderedItems
        guard !items.isEmpty else { return }

        let cursorID = navigationCursor ?? selectedItems.first
        let nextIndex: Int
        if let cursorID, let currentIndex = items.firstIndex(where: { $0.persistentModelID == cursorID }) {
            switch direction {
            case .up: nextIndex = max(0, currentIndex - 1)
            case .down: nextIndex = min(items.count - 1, currentIndex + 1)
            }
        } else {
            nextIndex = direction == .down ? 0 : items.count - 1
        }

        let targetID = items[nextIndex].persistentModelID
        navigationCursor = targetID
        if extendSelection {
            let anchor = selectionAnchor ?? cursorID ?? targetID
            selectionAnchor = anchor
            guard let anchorIdx = items.firstIndex(where: { $0.persistentModelID == anchor }) else { return }
            let range = min(anchorIdx, nextIndex)...max(anchorIdx, nextIndex)
            selectedItems = Set(items[range].map(\.persistentModelID))
        } else {
            selectedItems = [targetID]
            selectionAnchor = nil
        }
        scrollTarget = targetID
    }

    private func mergeSelectedItems() {
        let items = selectedClipItems.sorted { $0.createdAt < $1.createdAt }
        guard items.count > 1, items.allSatisfy({ $0.contentType.isMergeable }) else { return }
        let merged = items.map(\.content).joined(separator: "\n")
        let newItem = ClipItem(content: merged, contentType: .text)
        modelContext.insert(newItem)
        ClipItemStore.deleteAndNotify(items, from: modelContext)
        let newID = newItem.persistentModelID
        selectedItems = [newID]
        navigationCursor = newID
        scrollTarget = newID
    }

    private func handleMainCommandAction(_ action: CommandAction, item: ClipItem?) {
        showCommandPalette = false
        guard let item = item ?? selectedClipItems.first else { return }
        switch action {
        case .paste:
            copyToClipboard(item)
        case .pasteAndDestroy:
            // Main window has no target app to paste into, so fall back to
            // "copy to clipboard, then destroy history" — users can then paste
            // elsewhere and the sensitive entry is gone regardless.
            if !item.isPinned && !item.isFavorite,
               !isItemInPreservedGroup(item) {
                copyToClipboard(item)
                let context = modelContext
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    DeleteUndoCoordinator.shared.scheduleUndoableDelete(items: [item], context: context)
                }
            }
        case .cmdEnter:
            if item.contentType == .link,
               let url = URL(string: item.content.trimmingCharacters(in: .whitespacesAndNewlines)) {
                NSWorkspace.shared.open(url)
            } else {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(item.content, forType: .string)
                ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("action.copied"), icon: .success))
            }
        case .copy:
            if selectedItems.count > 1 {
                copySelectedToClipboard()
            } else {
                copyToClipboard(item)
            }
        case .retryOCR:
            if item.contentType == .image, item.imageData != nil {
                OCRTaskCoordinator.shared.retry(itemID: item.itemID)
            }
        case .openInPreview:
            QuickLookHelper.shared.openInPreviewApp(item: item)
        case .addToRelay:
            let items = selectedItems.count > 1 ? selectedClipItems : [item]
            RelayManager.shared.addToQueue(clipItems: items)
        case .splitAndRelay:
            if !item.content.isEmpty { relaySplitText = item.content }
        case .pin:
            if selectedItems.count > 1 {
                let items = selectedClipItems
                let shouldPin = !items.contains(where: \.isPinned)
                for i in items { i.isPinned = shouldPin }
            } else {
                item.isPinned.toggle()
            }
            ClipItemStore.saveAndNotify(modelContext)
        case .toggleSensitive:
            if selectedItems.count > 1 {
                let items = selectedClipItems
                let hasSensitive = items.contains(where: \.isSensitive)
                for i in items { i.isSensitive = !hasSensitive }
            } else {
                item.isSensitive.toggle()
            }
            ClipItemStore.saveAndNotify(modelContext)
        case .copyColorFormat(let format, _):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(format, forType: .string)
            ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("action.copied"), icon: .success))
        case .showInFinder:
            let paths = item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
            if let first = paths.first {
                NSWorkspace.shared.selectFile(first, inFileViewerRootedAtPath: "")
            }
        case .transform(let ruleAction):
            let processed = AutomationEngine.shared.applyAction(ruleAction, to: item.content)
            let contentChanged = processed != item.content
            item.content = processed
            item.displayTitle = ClipItem.buildTitle(content: processed, contentType: item.contentType)
            if contentChanged || ruleAction == .stripRichText {
                item.richTextData = nil
                item.richTextType = nil
            }
            ClipItemStore.saveAndNotify(modelContext)
        case .delete:
            deleteSelectedItems()
        case .runRule(let ruleID, _):
            let descriptor = FetchDescriptor<AutomationRule>(
                predicate: #Predicate { $0.ruleID == ruleID }
            )
            if let rule = try? modelContext.fetch(descriptor).first {
                applyAutomationRule(rule, to: item)
            }
        }
    }

    /// Manual-trigger rules surfaced inline in the ⌘K palette. Capped to 5.
    private func manualRulesForPalette(item: ClipItem) -> [AutomationRule] {
        guard ProManager.AUTOMATION_ENABLED else { return [] }
        let descriptor = FetchDescriptor<AutomationRule>(
            predicate: #Predicate { $0.enabled },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let enabled = (try? modelContext.fetch(descriptor)) ?? []
        let filtered = enabled.filter {
            $0.triggerMode == .manual && $0.matches(item: item)
        }
        return Array(filtered.prefix(5))
    }

    private func isItemInPreservedGroup(_ item: ClipItem) -> Bool {
        guard let group = item.groupName, !group.isEmpty else { return false }
        let preserved = SmartGroupRetention.preservedGroupNames(in: modelContext)
        return preserved.contains(group)
    }

    private func copySelectedToClipboard() {
        let items = selectedClipItems.sorted { $0.createdAt < $1.createdAt }
        guard !items.isEmpty else { return }
        let merged = items.map(\.content).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(merged, forType: .string)
        ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("action.copied"), icon: .success))
    }

    private func copyToClipboard(_ item: ClipItem) {
        clipboardManager.writeToPasteboard(item)
        ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("action.copied"), icon: .success))
    }

    private func fetchEnabledAutomationRules() -> [AutomationRule] {
        let descriptor = FetchDescriptor<AutomationRule>(
            predicate: #Predicate { $0.enabled },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func applyAutomationRule(_ rule: AutomationRule, to item: ClipItem) {
        let items: [ClipItem]
        if selectedItems.contains(item.persistentModelID), selectedItems.count > 1 {
            items = selectedClipItems
        } else {
            items = [item]
        }

        let actions = rule.actions
        guard !actions.isEmpty else { return }

        // runShortcut is async, targets a single clip, and writes its output to
        // the pasteboard (so the next capture becomes a new item). It bypasses
        // the in-place text mutation path entirely.
        if actions.contains(where: { if case .runShortcut = $0 { return true }; return false }) {
            Task { @MainActor in
                await runRuleViaShortcut(rule, on: items.first ?? item)
            }
            return
        }

        let hasSpecialActions = actions.contains { action in
            switch action {
            case .stripRichText, .assignGroup, .markSensitive, .pin, .skipCapture: return true
            default: return false
            }
        }

        ClipItemStore.isBulkOperation = true
        for target in items {
            let processed = AutomationEngine.executeActions(actions, on: target.content)
            let contentChanged = processed != target.content
            guard contentChanged || hasSpecialActions else { continue }
            target.content = processed
            target.displayTitle = ClipItem.buildTitle(content: processed, contentType: target.contentType)
            // Clear rich text if content changed — the stale rich formatting
            // no longer matches the new plain text and would leak through the
            // preview pane (which prefers rich content when present).
            if contentChanged || actions.contains(.stripRichText) {
                target.richTextData = nil
                target.richTextType = nil
            }
            if actions.contains(.markSensitive) {
                target.isSensitive = true
            }
            if actions.contains(.pin) {
                target.isPinned = true
            }
            if let groupAction = actions.first(where: {
                if case .assignGroup = $0 { return true }
                return false
            }), case .assignGroup(let name) = groupAction, !name.isEmpty {
                target.groupName = name
                ClipboardManager.shared.upsertSmartGroup(name: name, context: modelContext)
            }
            // skipCapture is only meaningful during clipboard capture, not manual apply
        }
        ClipItemStore.saveAndNotify(modelContext)
        ClipItemStore.isBulkOperation = false

        ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("automation.applied"), icon: .success))
    }

    @MainActor
    private func runRuleViaShortcut(_ rule: AutomationRule, on item: ClipItem) async {
        // Run the shortcut (plus any preceding text transforms). The Shortcut
        // itself is responsible for whatever output handling it wants — copy
        // to clipboard, post to a webhook, speak, write a file… PasteMemo just
        // pipes the clip in and triggers. We never touch NSPasteboard here.
        var currentContent = item.content
        let currentImageData = item.imageData
        let currentContentType = item.contentType

        for action in rule.actions {
            if case .runShortcut(let name) = action {
                do {
                    _ = try await ShortcutRunner.run(
                        name: name,
                        content: currentContent,
                        imageData: currentImageData,
                        contentType: currentContentType
                    )
                } catch {
                    ShortcutErrorNotifier.show(name: name, error: error)
                    return
                }
            } else {
                currentContent = action.execute(on: currentContent)
            }
        }

        let displayName = rule.isBuiltIn ? L10n.tr(rule.name) : rule.name
        ShortcutNotifier.showSuccess(ruleName: displayName)
    }

    private func changeGroupIcon(name: String) {
        let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == name })
        guard let group = try? modelContext.fetch(descriptor).first else { return }
        guard let result = GroupEditorPanel.show(name: group.name, icon: group.icon, preservesItems: group.preservesItems) else { return }
        group.icon = result.icon
        group.preservesItems = result.preservesItems
        try? modelContext.save()
        store.refreshSidebarCounts()
    }

    private func editGroup(name: String) {
        let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == name })
        guard let group = try? modelContext.fetch(descriptor).first else { return }
        let oldName = group.name
        AppMenuActions.showEditGroupAlert(group: group, context: modelContext)
        // Update ClipItem.groupName if name changed
        if group.name != oldName {
            let itemDescriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.groupName == oldName })
            if let items = try? modelContext.fetch(itemDescriptor) {
                for item in items { item.groupName = group.name }
            }
            try? modelContext.save()
            if selectedFilter == .group(oldName) {
                selectedFilter = .group(group.name)
            }
        }
        store.refreshSidebarCounts()
    }

    private func assignToGroup(items: [ClipItem], name: String) {
        for item in items {
            let oldGroup = item.groupName
            item.groupName = name
            ClipboardManager.shared.upsertSmartGroup(name: name, context: modelContext)
            if let oldGroup, !oldGroup.isEmpty {
                ClipboardManager.shared.decrementSmartGroup(name: oldGroup, context: modelContext)
            }
        }
        try? modelContext.save()
        store.refreshSidebarCounts()
    }

    private func removeFromGroup(items: [ClipItem]) {
        for item in items {
            guard let name = item.groupName, !name.isEmpty else { continue }
            item.groupName = nil
            ClipboardManager.shared.decrementSmartGroup(name: name, context: modelContext)
        }
        try? modelContext.save()
        store.refreshSidebarCounts()
    }

    private func showNewGroupAlert(for items: [ClipItem]) {
        guard let result = GroupEditorPanel.show() else { return }
        // Ensure group exists (upsert)
        let name = result.name
        let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == name })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.icon = result.icon
            existing.preservesItems = result.preservesItems
        } else {
            let maxOrder = (try? modelContext.fetch(FetchDescriptor<SmartGroup>()))?.map(\.sortOrder).max() ?? -1
            let group = SmartGroup(name: result.name, icon: result.icon, sortOrder: maxOrder + 1, preservesItems: result.preservesItems)
            modelContext.insert(group)
        }
        try? modelContext.save()
        assignToGroup(items: items, name: result.name)
    }

    /// Right-click "Clear items under this filter" handler. Honors the same
    /// safety rules as global Clear All: skips pinned items and items in groups
    /// flagged as `preservesItems`.
    private func clearItems(inScope scope: SidebarFilter) {
        let preserved = SmartGroupRetention.preservedGroupNames(in: modelContext)
        let descriptor: FetchDescriptor<ClipItem>
        switch scope {
        case .type(let type):
            let raw = type.rawValue
            descriptor = FetchDescriptor<ClipItem>(
                predicate: #Predicate { !$0.isPinned && $0.contentTypeRaw == raw }
            )
        case .group(let name):
            descriptor = FetchDescriptor<ClipItem>(
                predicate: #Predicate { !$0.isPinned && $0.groupName == name }
            )
        case .app(let appName):
            if appName.isEmpty {
                descriptor = FetchDescriptor<ClipItem>(
                    predicate: #Predicate { !$0.isPinned && $0.sourceApp == nil }
                )
            } else {
                descriptor = FetchDescriptor<ClipItem>(
                    predicate: #Predicate { !$0.isPinned && $0.sourceApp == appName }
                )
            }
        case .all, .pinned, .sensitive:
            return
        }

        guard let fetched = try? modelContext.fetch(descriptor) else { return }
        let deletable = SmartGroupRetention.filterDeletableItems(fetched, preservedGroupNames: preserved)
        guard !deletable.isEmpty else {
            let info = NSAlert()
            info.messageText = L10n.tr("action.clearScope.empty")
            info.alertStyle = .informational
            info.addButton(withTitle: L10n.tr("action.confirm"))
            info.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.tr("action.clearScope.title", scope.title)
        alert.informativeText = L10n.tr("action.clearScope.confirm", deletable.count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("action.delete"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if selectedFilter == scope {
            selectedFilter = .all
        }
        runBulkClear(title: L10n.tr("action.clearScope.title", scope.title), items: deletable)
    }

    /// Show a non-blocking progress sheet (when the set is large enough to feel
    /// laggy) and dispatch deletion through the batched async path. Smaller sets
    /// fall through to the synchronous path so the sheet doesn't flash.
    private func runBulkClear(title: String, items: [ClipItem]) {
        guard !items.isEmpty else { return }
        let total = items.count
        if total < Self.bulkClearProgressThreshold {
            ClipItemStore.deleteAndNotify(items, from: modelContext)
            return
        }
        clearTitle = title
        clearProgress = 0
        clearProgressText = "0 / \(total)"
        isClearing = true
        Task { @MainActor in
            await ClipItemStore.deleteAndNotifyBatched(items, from: modelContext) { done, total in
                clearProgress = Double(done) / Double(max(total, 1))
                clearProgressText = "\(done) / \(total)"
            }
            isClearing = false
        }
    }

    private static let bulkClearProgressThreshold = 200

    private func deleteSelectedItems() {
        let items = visualOrderedItems
        let visibleIDs = Set(items.map(\.persistentModelID))
        let idsToDelete = selectedItems.intersection(visibleIDs)
        guard !idsToDelete.isEmpty else { return }

        // Find the lowest index among deleted items for successor selection
        let firstDeletedIdx = items.firstIndex { idsToDelete.contains($0.persistentModelID) }

        let itemsToDelete = items.filter { idsToDelete.contains($0.persistentModelID) }
        DeleteUndoCoordinator.shared.scheduleUndoableDelete(items: itemsToDelete, context: modelContext)

        // Select next item after deletion
        let remaining = items.filter { !idsToDelete.contains($0.persistentModelID) }
        if !remaining.isEmpty, let idx = firstDeletedIdx {
            let nextIdx = min(idx, remaining.count - 1)
            let nextID = remaining[nextIdx].persistentModelID
            selectedItems = [nextID]
            navigationCursor = nextID
            selectionAnchor = nextID
            scrollTarget = nextID
        } else {
            selectedItems.removeAll()
            navigationCursor = nil
            selectionAnchor = nil
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        if selectedItems.count == 1, let item = selectedItem {
            ClipDetailView(item: item, clipboardManager: clipboardManager)
        } else if selectedItems.count > 1 {
            multiSelectView
        } else {
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .opacity(0.6)
                Text(L10n.tr("detail.select"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(L10n.tr("detail.selectHint"))
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Multi-Select View

    private var selectedClipItems: [ClipItem] {
        let ids = selectedItems
        return filteredItems.filter { ids.contains($0.persistentModelID) }
    }

    @ViewBuilder
    private var multiSelectView: some View {
        let items = selectedClipItems
        let hasPinned = items.contains(where: \.isPinned)
        let hasSensitive = items.contains(where: \.isSensitive)
        let hasGrouped = items.contains(where: { $0.groupName != nil })
        let allMergeable = items.allSatisfy { $0.contentType.isMergeable }

        VStack(spacing: 0) {
            Spacer()

            Text(L10n.tr("detail.multiSelected", selectedItems.count))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.6))
                .padding(.bottom, 12)

            // Type summary chips
            multiSelectTypeChips(items)
                .padding(.bottom, 24)

            // Action list
            VStack(spacing: 0) {
                multiActionRow(L10n.tr("action.mergeCopy"), icon: "doc.on.doc") {
                    copySelectedToClipboard()
                }
                multiActionRow(hasPinned ? L10n.tr("action.unpin") : L10n.tr("action.pin"), icon: hasPinned ? "pin.slash" : "pin") {
                    let newValue = !hasPinned
                    for item in items { item.isPinned = newValue }
                    ClipItemStore.saveAndNotify(modelContext)
                }
                multiActionRow(hasSensitive ? L10n.tr("sensitive.unmarkSensitive") : L10n.tr("sensitive.markSensitive"), icon: hasSensitive ? "lock.open" : "lock.shield") {
                    let newValue = !hasSensitive
                    for item in items { item.isSensitive = newValue }
                    ClipItemStore.saveAndNotify(modelContext)
                }
                if allMergeable {
                    multiActionRow(L10n.tr("action.merge"), icon: "arrow.triangle.merge") {
                        mergeSelectedItems()
                    }
                }
                multiActionGroupMenu(items: items)
                if hasGrouped {
                    multiActionRow(L10n.tr("action.removeFromGroup"), icon: "folder.badge.minus") {
                        removeFromGroup(items: items)
                    }
                }
                multiActionRow(L10n.tr("relay.addToQueue"), icon: "arrow.right.arrow.left") {
                    RelayManager.shared.addToQueue(clipItems: items)
                }

                // Separator before delete
                Divider().padding(.vertical, 4)

                Button {
                    deleteSelectedItems()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .frame(width: 18)
                        Text(L10n.tr("action.deleteSelected", selectedItems.count))
                            .font(.system(size: 12))
                        Spacer()
                    }
                    .foregroundStyle(.red)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 200)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func multiActionRow(_ title: String, icon: String, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func multiActionGroupMenu(items: [ClipItem]) -> some View {
        Menu {
            ForEach(store.sidebarCounts.byGroup, id: \.name) { group in
                Button(group.name) { assignToGroup(items: items, name: group.name) }
            }
            if !store.sidebarCounts.byGroup.isEmpty { Divider() }
            Button(L10n.tr("action.newGroup")) { showNewGroupAlert(for: items) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(L10n.tr("action.assignGroup"))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    @ViewBuilder
    private func multiSelectTypeChips(_ items: [ClipItem]) -> some View {
        let counts = items.reduce(into: [ClipContentType: Int]()) { $0[$1.contentType, default: 0] += 1 }
        let sorted = counts.sorted { $0.value > $1.value }

        WrappingHStack(spacing: 6, lineSpacing: 6) {
            ForEach(sorted, id: \.key) { type, count in
                HStack(spacing: 4) {
                    Image(systemName: type.icon)
                        .font(.system(size: 10))
                    Text(type.label)
                        .font(.system(size: 11, weight: .medium))
                    Text("\(count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }

    private func multiSelectCard(item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: item.contentType.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(item.contentType.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if item.contentType == .image, let data = item.imageData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 95)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(cardTitle(for: item))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 200, height: 150)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func cardColor(for item: ClipItem) -> Color {
        switch item.contentType {
        case .text: return .blue
        case .link: return .purple
        case .image: return .green
        case .file: return .orange
        case .video: return .pink
        case .audio: return .cyan
        default: return .gray
        }
    }

    private func cardTitle(for item: ClipItem) -> String {
        switch item.contentType {
        case .link: return item.linkTitle ?? item.content
        case .file, .video, .audio, .document, .archive, .application:
            return URL(fileURLWithPath: item.content.components(separatedBy: "\n").first ?? "").lastPathComponent
        default:
            return item.content.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
    }
}

// MARK: - List Row

struct ClipItemListRow: View {
    let item: ClipItem
    var isSelected: Bool = false
    var groupIcon: String?
    var searchText: String = ""

    var body: some View {
        ClipRow(item: item, isSelected: isSelected, groupIcon: groupIcon, searchText: searchText)
            .padding(.vertical, 2)
            .transaction { $0.animation = nil }
    }
}

@MainActor
func formatTimeAgo(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    switch interval {
    case ..<60: return L10n.tr("time.now")
    case ..<3600: return L10n.tr("time.minutes", Int(interval / 60))
    case ..<86400: return L10n.tr("time.hours", Int(interval / 3600))
    case ..<604_800: return L10n.tr("time.days", Int(interval / 86400))
    case ..<2_592_000: return L10n.tr("time.weeks", Int(interval / 604_800))
    case ..<31_536_000: return L10n.tr("time.months", Int(interval / 2_592_000))
    default: return L10n.tr("time.years", Int(interval / 31_536_000))
    }
}

struct TypeDropDelegate: DropDelegate {
    let target: ClipContentType
    @Binding var dragging: ClipContentType?
    @Binding var types: [ClipContentType]

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        ClipContentType.saveTypeOrder(types)
        NotificationCenter.default.post(name: .typeOrderDidChange, object: nil)
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let source = dragging, source != target,
              let fromIdx = types.firstIndex(of: source),
              let toIdx = types.firstIndex(of: target)
        else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            types.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil
    }
}

struct GroupDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let store: ClipItemStore
    let modelContext: ModelContext

    func performDrop(info: DropInfo) -> Bool {
        guard dragging != nil else { return false }
        dragging = nil
        // Persist new sort order to SmartGroup table
        let descriptor = FetchDescriptor<SmartGroup>(sortBy: [SortDescriptor(\.sortOrder)])
        guard let groups = try? modelContext.fetch(descriptor) else { return true }
        let currentOrder = store.sidebarCounts.byGroup.map(\.name)
        for (idx, name) in currentOrder.enumerated() {
            groups.first { $0.name == name }?.sortOrder = idx
        }
        try? modelContext.save()
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let source = dragging, source != target else { return }
        var groups = store.sidebarCounts.byGroup
        guard let fromIdx = groups.firstIndex(where: { $0.name == source }),
              let toIdx = groups.firstIndex(where: { $0.name == target })
        else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            groups.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: toIdx > fromIdx ? toIdx + 1 : toIdx)
            store.sidebarCounts.byGroup = groups
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil
    }
}

// MARK: - NSView Helpers

extension NSView {
    func findSubview<T: NSView>(ofType type: T.Type) -> T? {
        for sub in subviews {
            if let match = sub as? T { return match }
            if let match = sub.findSubview(ofType: type) { return match }
        }
        return nil
    }
}

// MARK: - WrappingHStack

/// Flow layout that wraps children onto additional lines when they don't fit
/// on one row. Used by the multi-select type chips so 10+ types don't get
/// squeezed into vertical single-glyph columns.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var alignment: HorizontalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        return computeLayout(maxWidth: maxWidth, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(maxWidth: bounds.width, subviews: subviews)
        for (idx, frame) in result.frames.enumerated() {
            subviews[idx].place(
                at: CGPoint(x: bounds.minX + frame.origin.x, y: bounds.minY + frame.origin.y),
                proposal: ProposedViewSize(width: frame.size.width, height: frame.size.height)
            )
        }
    }

    private func computeLayout(maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for (idx, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let needsNewRow = !rows.last!.isEmpty && rowWidth + spacing + size.width > maxWidth
            if needsNewRow {
                totalHeight += rowHeight + lineSpacing
                rows.append([])
                rowWidth = 0
                rowHeight = 0
            }
            rows[rows.count - 1].append((idx, size))
            rowWidth += (rows.last!.count == 1 ? 0 : spacing) + size.width
            rowHeight = max(rowHeight, size.height)
            contentWidth = max(contentWidth, rowWidth)
        }
        totalHeight += rowHeight

        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0
        for row in rows {
            let rowTotalWidth = row.reduce(CGFloat(0)) { $0 + $1.size.width } + spacing * CGFloat(max(row.count - 1, 0))
            let rowRowHeight = row.map(\.size.height).max() ?? 0
            var x: CGFloat
            switch alignment {
            case .leading:
                x = 0
            case .trailing:
                x = max(0, maxWidth - rowTotalWidth)
            default:
                x = max(0, (maxWidth - rowTotalWidth) / 2)
            }
            for entry in row {
                frames[entry.index] = CGRect(
                    x: x,
                    y: y + (rowRowHeight - entry.size.height) / 2,
                    width: entry.size.width,
                    height: entry.size.height
                )
                x += entry.size.width + spacing
            }
            y += rowRowHeight + lineSpacing
        }
        return (CGSize(width: contentWidth, height: totalHeight), frames)
    }
}
