import SwiftUI
import SwiftData
import Quartz

private enum QuickFilter: Equatable {
    case all
    case pinned
    case type(ClipContentType)
}

private let PANEL_WIDTH: CGFloat = 750
private let PANEL_HEIGHT: CGFloat = 510
private let LIST_WIDTH: CGFloat = 340

struct QuickPanelView: View {
    @EnvironmentObject var clipboardManager: ClipboardManager
    @Environment(\.modelContext) private var modelContext
    @State private var store = ClipItemStore()
    @State private var searchText = ""
    @State private var groupSuggestionIndex = -1
    @State private var selectedGroupFilter: String?
    @State private var isAppFilter = false
    @State private var selectedItemIDs: Set<PersistentIdentifier> = []
    @State private var selectedFilter: QuickFilter = .all
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @FocusState private var isSearchFocused: Bool
    @State private var lastClickedID: PersistentIdentifier?
    @State private var lastClickTime: Date = .distantPast
    @State private var lastNavigatedID: PersistentIdentifier?
    @State private var selectionAnchor: PersistentIdentifier?
    @State private var showAllShortcuts = false
    @State private var relaySplitText: String?
    @State private var showCopiedToast = false
    @State private var showCommandPalette = false
    @State private var targetApp: NSRunningApplication?
    @State private var isPanelPinned = false
    @State private var scrollResetToken = UUID()
    @State private var lastSeenFirstItemID: String?
    @State private var cachedGroupedItems: [GroupedItem<ClipItem>] = []
    @State private var cachedDisplayOrder: [ClipItem] = []
    @State private var cachedItemMap: [PersistentIdentifier: ClipItem] = [:]
    @State private var cachedIDSet: Set<PersistentIdentifier> = []
    @AppStorage("quickPanelAutoPaste") private var quickPanelAutoPaste = true

    private var filteredItems: [ClipItem] { store.items }

    private var groupedItems: [GroupedItem<ClipItem>] { cachedGroupedItems }

    /// Flat list in display order (matches what user sees on screen)
    private var displayOrderItems: [ClipItem] { cachedDisplayOrder }

    private var defaultItem: ClipItem? {
        cachedDisplayOrder.first
    }

    private func rebuildGroupedItems() {
        cachedGroupedItems = groupItemsByTime(filteredItems, separatePinned: false)
        cachedDisplayOrder = cachedGroupedItems.flatMap(\.items)
        cachedItemMap = Dictionary(cachedDisplayOrder.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { _, last in last })
        cachedIDSet = Set(cachedItemMap.keys)
    }

    /// Single selected ID for backward compat
    private var selectedItemID: PersistentIdentifier? {
        selectedItemIDs.count == 1 ? selectedItemIDs.first : selectedItemIDs.first
    }

    private var isMultiSelected: Bool { selectedItemIDs.count > 1 }

    private var currentItems: [ClipItem] {
        guard !store.items.isEmpty else { return [] }
        let ids = selectedItemIDs
        return cachedDisplayOrder.filter { ids.contains($0.persistentModelID) && !$0.isDeleted && $0.modelContext != nil }
    }

    private var currentItem: ClipItem? {
        guard !isMultiSelected else { return nil }
        // store.items is cleared by deleteAndNotify before deletion — this is the
        // only reliable signal; isDeleted is NOT safe on zombie SwiftData objects
        guard !store.items.isEmpty else { return nil }
        guard let id = selectedItemIDs.first else { return defaultItem }
        guard let item = cachedItemMap[id], !item.isDeleted, item.modelContext != nil else { return nil }
        return item
    }

    private func selectItem(_ id: PersistentIdentifier) {
        selectedItemIDs = [id]
        lastNavigatedID = id
    }

    private func handleItemClick(_ id: PersistentIdentifier) {
        let now = Date()
        let isDoubleClick = lastClickedID == id && now.timeIntervalSince(lastClickTime) < 0.3

        if isDoubleClick {
            selectItem(id)
            handlePaste()
            lastClickedID = nil
            lastClickTime = .distantPast
            return
        }

        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            toggleItemInSelection(id)
        } else if flags.contains(.shift) {
            extendSelectionTo(id)
        } else {
            selectItem(id)
        }
        isSearchFocused = true
        lastClickedID = id
        lastClickTime = now
    }

    private func toggleItemInSelection(_ id: PersistentIdentifier) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    private func extendSelectionTo(_ id: PersistentIdentifier) {
        let items = displayOrderItems
        guard let lastID = selectedItemIDs.first,
              let lastIdx = items.firstIndex(where: { $0.persistentModelID == lastID }),
              let clickIdx = items.firstIndex(where: { $0.persistentModelID == id }) else {
            selectItem(id)
            return
        }
        let range = min(lastIdx, clickIdx)...max(lastIdx, clickIdx)
        selectedItemIDs = Set(items[range].map(\.persistentModelID))
    }

    var body: some View {
        ZStack(alignment: .top) {
        VStack(spacing: 0) {
            searchBar
            tabBar
            Divider().opacity(0.3)
            if filteredItems.isEmpty {
                emptyStateView
            } else {
                HStack(spacing: 0) {
                    clipList
                    Divider().opacity(0.3)
                    previewPane
                }
            }
            Divider().opacity(0.3)
            footerBar
        }
        .frame(minWidth: 500, minHeight: 350)
        .overlay {
            if showCopiedToast {
                VStack {
                    Spacer()
                    Text(L10n.tr("action.copied"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.75), in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .padding(.bottom, 50)
                }
                .animation(.easeInOut(duration: 0.2), value: showCopiedToast)
            }
            // Command palette is now shown via popover on the selected row
        }
        // Floating group suggestions overlay
        if isShowingSuggestions {
            VStack(spacing: 0) {
                Spacer().frame(height: 48)
                HStack {
                    groupSuggestions
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
                        .frame(maxWidth: 260)
                    Spacer()
                }
                .padding(.horizontal, 16)
                Spacer()
            }
            .allowsHitTesting(true)
        }
        } // ZStack
        .onAppear {
            store.configure(modelContext: modelContext)
            rebuildGroupedItems()
            if let id = defaultItem?.persistentModelID { selectedItemIDs = [id]; lastNavigatedID = id }
            installKeyMonitor()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                isSearchFocused = true
            }
        }
        .onDisappear {
            removeKeyMonitor()
            store.isActive = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickPanelDidShow)) { _ in
            showCommandPalette = false
            searchText = ""
            selectedGroupFilter = nil
            isAppFilter = false
            selectedFilter = .all
            isPanelPinned = false
            store.isActive = true
            store.configure(modelContext: modelContext)
            // Reset filters if new content arrived
            let latestItemID = store.queryFirstItemID()
            if latestItemID != lastSeenFirstItemID {
                store.resetFilters()
                lastSeenFirstItemID = latestItemID
            }
            // Always rebuild and select first item on panel open
            rebuildGroupedItems()
            scrollResetToken = UUID()
            if let id = cachedDisplayOrder.first?.persistentModelID {
                selectedItemIDs = [id]
                lastNavigatedID = id
            }
            targetApp = QuickPanelWindowController.shared.previousApp
            isSearchFocused = true
        }
        .onChange(of: searchText) {
            if selectedGroupFilter != nil {
                // Group tag is active — search text is just keyword
                store.searchText = searchText
            } else if searchText.hasPrefix(Self.GROUP_SEARCH_PREFIX) {
                // Typing / for group selection — don't search yet
                store.searchText = ""
                store.groupName = nil
            } else {
                store.groupName = nil
                store.searchText = searchText
            }
            // Default-select the first suggestion row when typing `/`,
            // so Enter immediately picks the top group/app.
            groupSuggestionIndex = totalSuggestionCount > 0 ? 0 : -1
        }
        .onChange(of: selectedFilter) {
            store.pinnedOnly = false
            store.filterType = nil
            switch selectedFilter {
            case .all: break
            case .pinned: store.pinnedOnly = true
            case .type(let t): store.filterType = t
            }
            store.applyFilters()
        }
        .onChange(of: store.items) {
            rebuildGroupedItems()
            guard selectedItemIDs.isEmpty || selectedItemIDs.isDisjoint(with: cachedIDSet) else { return }
            let firstID = defaultItem?.persistentModelID
            if let firstID { selectedItemIDs = [firstID] } else { selectedItemIDs.removeAll() }
            lastNavigatedID = firstID
        }
        .onChange(of: relaySplitText) {
            guard let text = relaySplitText else { return }
            SplitWindowController.shared.show(text: text) { delimiter in
                guard let parts = RelaySplitter.split(text, by: delimiter) else { return }
                RelayManager.shared.enqueue(texts: parts)
                if !RelayManager.shared.isActive {
                    RelayManager.shared.activate()
                }
            }
            relaySplitText = nil
        }
        .localized()
    }

    // MARK: - Search

    private static let GROUP_SEARCH_PREFIX = "/"

    private enum SuggestionItem: Equatable {
        case group(name: String, icon: String, count: Int)
        case app(name: String, count: Int)

        static func == (lhs: SuggestionItem, rhs: SuggestionItem) -> Bool {
            switch (lhs, rhs) {
            case (.group(let a, _, _), .group(let b, _, _)): return a == b
            case (.app(let a, _), .app(let b, _)): return a == b
            default: return false
            }
        }
    }

    private var isShowingSuggestions: Bool {
        guard selectedGroupFilter == nil else { return false }
        guard searchText.hasPrefix(Self.GROUP_SEARCH_PREFIX) else { return false }
        return !currentSuggestionGroups.isEmpty || !currentSuggestionApps.isEmpty
    }

    private var currentSuggestionGroups: [(name: String, icon: String, count: Int)] {
        guard searchText.hasPrefix(Self.GROUP_SEARCH_PREFIX) else { return [] }
        let query = String(searchText.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
        return store.sidebarCounts.byGroup.filter { group in
            guard group.count > 0 else { return false }
            return query.isEmpty || group.name.lowercased().contains(query)
        }
    }

    private var currentSuggestionApps: [(name: String, count: Int)] {
        guard searchText.hasPrefix(Self.GROUP_SEARCH_PREFIX) else { return [] }
        let query = String(searchText.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
        let apps = store.sourceApps
            .filter { !$0.isEmpty }
            .compactMap { name -> (name: String, count: Int)? in
                let count = store.sidebarCounts.byApp[name] ?? 0
                guard count > 0 else { return nil }
                guard query.isEmpty || name.lowercased().contains(query) else { return nil }
                return (name: name, count: count)
            }
            .sorted { $0.count > $1.count }
        return query.isEmpty ? Array(apps.prefix(5)) : apps
    }

    private var totalSuggestionCount: Int {
        currentSuggestionGroups.count + currentSuggestionApps.count
    }

    @ViewBuilder
    private var groupSuggestions: some View {
        let groups = currentSuggestionGroups
        let apps = currentSuggestionApps
        if !groups.isEmpty || !apps.isEmpty {
            VStack(spacing: 0) {
                if !groups.isEmpty {
                    suggestionSectionHeader(L10n.tr("filter.groups"))
                    ForEach(Array(groups.enumerated()), id: \.element.name) { idx, group in
                        suggestionRow(
                            icon: group.icon, name: group.name, count: group.count,
                            isSelected: idx == groupSuggestionIndex
                        ) {
                            selectSuggestion(.group(name: group.name, icon: group.icon, count: group.count))
                        }
                    }
                }
                if !apps.isEmpty {
                    if !groups.isEmpty { Divider().padding(.vertical, 2) }
                    suggestionSectionHeader(L10n.tr("filter.apps"))
                    let offset = groups.count
                    ForEach(Array(apps.enumerated()), id: \.element.name) { idx, app in
                        suggestionRow(
                            icon: "app.dashed", appName: app.name, name: app.name, count: app.count,
                            isSelected: (offset + idx) == groupSuggestionIndex
                        ) {
                            selectSuggestion(.app(name: app.name, count: app.count))
                        }
                    }
                }
            }
        }
    }

    private func suggestionSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func suggestionRow(icon: String, appName: String? = nil, name: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let appName, let nsIcon = appIcon(forBundleID: nil, name: appName) {
                    Image(nsImage: nsIcon)
                        .resizable()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .frame(width: 18)
                }
                Text(name)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        isSelected ? Color.white.opacity(0.2) : Color.primary.opacity(0.08),
                        in: Capsule()
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func selectSuggestion(_ item: SuggestionItem) {
        searchText = ""
        groupSuggestionIndex = -1
        switch item {
        case .group(let name, _, _):
            selectedGroupFilter = name
            isAppFilter = false
            store.groupName = name
            store.sourceApp = nil
        case .app(let name, _):
            selectedGroupFilter = name
            isAppFilter = true
            store.groupName = nil
            store.sourceApp = .named(name)
        }
        store.searchText = ""
        store.applyFilters()
    }

    private func clearGroupFilter() {
        selectedGroupFilter = nil
        store.groupName = nil
        store.sourceApp = nil
        store.applyFilters()
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)

            if let filterName = selectedGroupFilter {
                let groupIcon = store.sidebarCounts.byGroup.first { $0.name == filterName }?.icon ?? "folder"
                HStack(spacing: 4) {
                    if isAppFilter, let nsIcon = appIcon(forBundleID: nil, name: filterName) {
                        Image(nsImage: nsIcon)
                            .resizable()
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: isAppFilter ? "app.dashed" : groupIcon)
                            .font(.system(size: 10))
                    }
                    Text(filterName)
                        .font(.system(size: 12))
                    Button {
                        clearGroupFilter()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
            }

            TextField(L10n.tr("quick.search"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isSearchFocused)

            if !searchText.isEmpty || selectedGroupFilter != nil {
                Button { searchText = ""; clearGroupFilter(); if let id = defaultItem?.persistentModelID { selectedItemIDs = [id] } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
            }

            Button {
                isPanelPinned.toggle()
                QuickPanelWindowController.shared.isPinned = isPanelPinned
            } label: {
                Image(systemName: isPanelPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(height: 20)
                    .padding(.horizontal, 6)
                    .background(isPanelPinned ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPanelPinned ? L10n.tr("quickPanel.unpin") : L10n.tr("quickPanel.pin"))

            Text("\(store.totalCount)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(height: 20)
                .padding(.horizontal, 6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                badge(L10n.tr("filter.pinned"), isActive: selectedFilter == .pinned) {
                    selectedFilter = selectedFilter == .pinned ? .all : .pinned
                    isSearchFocused = true
                }
                badge(L10n.tr("filter.all"), isActive: selectedFilter == .all) {
                    selectedFilter = .all; isSearchFocused = true
                }
                ForEach(availableContentTypes, id: \.self) { type in
                    badge(type.label, isActive: selectedFilter == .type(type)) {
                        selectedFilter = selectedFilter == .type(type) ? .all : .type(type)
                        isSearchFocused = true
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
    }

    private func badge(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isActive ? .medium : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(isActive ? .white : Color(nsColor: .secondaryLabelColor))
                .background(
                    isActive ? Color.accentColor : Color.primary.opacity(0.06),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var clipList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groupedItems, id: \.group) { group in
                            Text(group.group.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                                .id("group_\(group.group.rawValue)")

                            ForEach(group.items) { item in
                                if item.isDeleted { EmptyView() } else {
                                let itemID = item.persistentModelID
                                let itemContentType = item.contentType
                                let shortcutIdx = shortcutIndex(for: item)
                                QuickClipRow(item: item, isSelected: selectedItemIDs.contains(itemID), shortcutIndex: shortcutIdx, searchText: searchText)
                                    .id(itemID)
                                    .contentShape(Rectangle())
                                    .popover(
                                        isPresented: Binding(
                                            get: { showCommandPalette && selectedItemIDs.contains(itemID) && (lastNavigatedID ?? selectedItemIDs.first) == itemID },
                                            set: { if !$0 { showCommandPalette = false; isSearchFocused = true } }
                                        ),
                                        arrowEdge: .trailing
                                    ) {
                                        CommandPaletteContent(
                                            item: item,
                                            isMultiSelected: isMultiSelected,
                                            onAction: { handleCommandAction($0) },
                                            onDismiss: { showCommandPalette = false; isSearchFocused = true }
                                        )
                                    }
                                    .onAppear {
                                        if item.id == filteredItems.last?.id { store.loadMore() }
                                    }
                                    .onTapGesture {
                                        handleItemClick(itemID)
                                    }
                                    .onRightClick {
                                        if !selectedItemIDs.contains(itemID) {
                                            selectedItemIDs = [itemID]
                                            lastNavigatedID = itemID
                                        }
                                    }
                                    .contextMenu {
                                        if isMultiSelected, selectedItemIDs.contains(itemID) {
                                            let items = currentItems
                                            let hasPinned = items.contains(where: \.isPinned)
                                            Button(hasPinned ? L10n.tr("action.unpin") : L10n.tr("action.pin")) {
                                                let newValue = !hasPinned
                                                for i in items { i.isPinned = newValue }
                                                ClipItemStore.saveAndNotify(modelContext)
                                            }
                                            let hasSensitive = items.contains(where: \.isSensitive)
                                            Button(hasSensitive ? L10n.tr("sensitive.unmarkSensitive") : L10n.tr("sensitive.markSensitive")) {
                                                let newValue = !hasSensitive
                                                for i in items { i.isSensitive = newValue }
                                                ClipItemStore.saveAndNotify(modelContext)
                                            }
                                            Button(L10n.tr("action.mergeCopy")) {
                                                copyItemsToClipboard(items)
                                            }
                                            Divider()
                                            Button(L10n.tr("relay.addToQueue")) {
                                                RelayManager.shared.enqueue(clipItems: items)
                                                if !RelayManager.shared.isActive {
                                                    RelayManager.shared.activate()
                                                }
                                            }
                                            Divider()
                                            Button(L10n.tr("action.delete"), role: .destructive) {
                                                handleDeleteSelected()
                                            }
                                        } else {
                                            Button(item.isPinned ? L10n.tr("action.unpin") : L10n.tr("action.pin")) {
                                                item.isPinned.toggle()
                                                ClipItemStore.saveAndNotify(modelContext)
                                                selectItem(itemID)
                                            }
                                            Button(item.isSensitive ? L10n.tr("sensitive.unmarkSensitive") : L10n.tr("sensitive.markSensitive")) {
                                                item.isSensitive.toggle()
                                                ClipItemStore.saveAndNotify(modelContext)
                                                selectItem(itemID)
                                            }
                                            Button(L10n.tr("action.mergeCopy")) {
                                                copyItemsToClipboard([item])
                                                selectItem(itemID)
                                            }
                                            if itemContentType.isMergeable,
                                               ProManager.AUTOMATION_ENABLED {
                                                let manualRules = fetchEnabledRules()
                                                if !manualRules.isEmpty {
                                                    Divider()
                                                    Menu(L10n.tr("cmd.automation")) {
                                                        ForEach(manualRules) { rule in
                                                            Button(rule.isBuiltIn ? L10n.tr(rule.name) : rule.name) {
                                                                applyRule(rule, to: item)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                            Divider()
                                            if !item.content.isEmpty || item.imageData != nil {
                                                Button(L10n.tr("relay.addToQueue")) {
                                                    RelayManager.shared.enqueue(clipItems: [item])
                                                    if !RelayManager.shared.isActive {
                                                        RelayManager.shared.activate()
                                                    }
                                                }
                                                Button(L10n.tr("relay.splitAndRelay")) {
                                                    relaySplitText = item.content
                                                }
                                            }
                                            Divider()
                                            Button(L10n.tr("action.copyDebugInfo")) {
                                                copyDebugInfo(for: item)
                                            }
                                            Divider()
                                            Button(L10n.tr("action.delete"), role: .destructive) {
                                                deleteItem(item)
                                            }
                                        }
                                    }
                                } // isDeleted guard
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                }
                .onChange(of: lastNavigatedID) {
                guard let id = lastNavigatedID else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(id)
                }
            }
                .onChange(of: selectedFilter) {
                if let firstGroup = cachedGroupedItems.first {
                    proxy.scrollTo("group_\(firstGroup.group.rawValue)", anchor: .top)
                }
            }
            .id(scrollResetToken)
        }
        .frame(width: LIST_WIDTH)
    }

    // MARK: - Empty State

    private var isFilterActive: Bool {
        selectedFilter != .all || !searchText.isEmpty || selectedGroupFilter != nil
    }

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.quaternary)
            Text(L10n.tr("empty.noResults"))
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewPane: some View {
        if isMultiSelected {
            multiSelectPreview
        } else if let item = currentItem {
            QuickPreviewPane(item: item, searchText: searchText)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.text.square")
                    .font(.system(size: 24))
                    .foregroundStyle(.quaternary)
                Text(L10n.tr("empty.message"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var multiSelectPreview: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L10n.tr("quick.multiSelected", selectedItemIDs.count))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L10n.tr("quick.batchPaste"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footerBar: some View {
        VStack(spacing: 0) {
            // Expandable shortcuts panel
            if showAllShortcuts {
                HStack(spacing: 12) {
                    footerKey("←→", L10n.tr("quick.switchType"))
                    footerKey("↑↓", L10n.tr("quick.navigate"))
                    footerKey("⌘O", currentItem?.contentType == .link ? L10n.tr("quick.openLink") : L10n.tr("quick.preview"))
                    footerKey("⌘⌫", L10n.tr("quick.delete"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(Color.primary.opacity(0.02))
            }

            // Main footer bar
            HStack(spacing: 0) {
                if !quickPanelAutoPaste {
                    Text(L10n.tr("quick.copyToClipboard"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if let prevApp = targetApp,
                   let appName = prevApp.localizedName {
                    HStack(spacing: 4) {
                        if let icon = prevApp.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 14, height: 14)
                        }
                        Text(L10n.tr("quick.pasteTo", appName))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("PasteMemo")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.quaternary)
                }
                Spacer()
                HStack(spacing: 12) {
                    if isMultiSelected {
                        footerKey("↵", quickPanelAutoPaste ? (isTargetFinder ? L10n.tr("quick.saveToFolder") : L10n.tr("quick.batchPaste")) : L10n.tr("action.copy"))
                        if quickPanelAutoPaste, !isTargetFinder {
                            footerKey("⇧↵", L10n.tr("quick.pasteNewLine"))
                        }
                        footerKey("⌘↵", quickPanelAutoPaste ? L10n.tr("action.pasteAsPlainText") : L10n.tr("cmd.copyAsPlainText"))
                    } else {
                        if let cur = currentItem {
                            footerKey("↵", primaryFooterLabel(for: cur))
                            if quickPanelAutoPaste {
                                if !(cur.imageData != nil && canPasteToFinderFolder), !canSaveTextToFolder {
                                    footerKey("⇧↵", L10n.tr("quick.pasteNewLine"))
                                }
                            }
                            if let cmdEnterLabel = cmdEnterFooterLabel(for: cur) {
                                footerKey("⌘↵", cmdEnterLabel)
                            }
                        }
                    }
                    if let cur = currentItem, cur.isSensitive, !isMultiSelected {
                        footerKey("⌥", L10n.tr("sensitive.peek"))
                    }
                    footerKey("⌘K", L10n.tr("cmd.title"))
                    footerKey("esc", L10n.tr("quick.close"))

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showAllShortcuts.toggle()
                        }
                    } label: {
                        Image(systemName: showAllShortcuts ? "keyboard.chevron.compact.down" : "keyboard")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button {
                        handleDismiss()
                        AppAction.shared.openSettings?()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.03))
        }
    }

    private func primaryFooterLabel(for item: ClipItem) -> String {
        if quickPanelAutoPaste {
            if item.imageData != nil, canPasteToFinderFolder {
                return L10n.tr("quick.pasteImage")
            }
            if canSaveTextToFolder {
                return L10n.tr("quick.saveToFolder")
            }
            return L10n.tr("quick.pasteAction")
        }

        if isFileBasedItem(item) {
            return L10n.tr("quick.copyPath")
        }

        return L10n.tr("action.copy")
    }

    private func cmdEnterFooterLabel(for item: ClipItem) -> String? {
        if item.contentType == .link {
            return L10n.tr("cmd.openLink")
        }

        if isFileBasedItem(item) {
            return quickPanelAutoPaste ? L10n.tr("quick.pastePath") : L10n.tr("quick.copyPath")
        }

        if canSaveTextToFolder {
            return L10n.tr("quick.saveToFolder")
        }

        if [.text, .code, .color, .email, .phone].contains(item.contentType) {
            return quickPanelAutoPaste ? L10n.tr("action.pasteAsPlainText") : L10n.tr("cmd.copyAsPlainText")
        }

        return nil
    }

    private func footerKey(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private func moveSelection(_ delta: Int, extendSelection: Bool = false) {
        var items = displayOrderItems
        guard !items.isEmpty else { return }
        let cursorID = lastNavigatedID ?? selectedItemIDs.first ?? items.first?.persistentModelID
        guard let currentIdx = items.firstIndex(where: { $0.persistentModelID == cursorID }) else { return }
        let next = currentIdx + delta
        if next < 0 { return }
        if next >= items.count {
            store.loadMore()
            items = displayOrderItems
            if next >= items.count { return }
        }
        let targetID = items[next].persistentModelID
        lastNavigatedID = targetID
        if extendSelection {
            let anchor = selectionAnchor ?? cursorID ?? targetID
            selectionAnchor = anchor
            guard let anchorIdx = items.firstIndex(where: { $0.persistentModelID == anchor }) else { return }
            let range = min(anchorIdx, next)...max(anchorIdx, next)
            selectedItemIDs = Set(items[range].map(\.persistentModelID))
        } else {
            selectedItemIDs = [targetID]
            selectionAnchor = nil
        }
    }

    private func installKeyMonitor() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard HotkeyManager.shared.isQuickPanelVisible else { return event }
            OptionKeyMonitor.shared.isOptionPressed = event.modifierFlags.contains(.option)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard HotkeyManager.shared.isQuickPanelVisible else { return event }
            // Let command palette handle keys when it's open
            if showCommandPalette { return event }
            let hasShift = event.modifierFlags.contains(.shift)
            let hasCmd = event.modifierFlags.contains(.command)
            let hasControl = event.modifierFlags.contains(.control)

            // Group suggestion keyboard navigation
            if isShowingSuggestions {
                let total = totalSuggestionCount
                switch Int(event.keyCode) {
                case 125: // Down
                    groupSuggestionIndex = (groupSuggestionIndex + 1) % total
                    return nil
                case 126: // Up
                    groupSuggestionIndex = groupSuggestionIndex <= 0 ? total - 1 : groupSuggestionIndex - 1
                    return nil
                case 36: // Enter
                    if groupSuggestionIndex >= 0, groupSuggestionIndex < total {
                        let groups = currentSuggestionGroups
                        let apps = currentSuggestionApps
                        if groupSuggestionIndex < groups.count {
                            let g = groups[groupSuggestionIndex]
                            selectSuggestion(.group(name: g.name, icon: g.icon, count: g.count))
                        } else {
                            let a = apps[groupSuggestionIndex - groups.count]
                            selectSuggestion(.app(name: a.name, count: a.count))
                        }
                        return nil
                    }
                default: break
                }
            }

            switch Int(event.keyCode) {
            case 126: moveSelection(-1, extendSelection: hasShift); return nil
            case 125: moveSelection(1, extendSelection: hasShift); return nil
            case 123: switchType(-1); return nil
            case 124: switchType(1); return nil
            case 45:
                if hasControl {
                    moveSelection(1, extendSelection: hasShift)
                    return nil
                }
                return event
            case 35:
                if hasControl && !hasCmd {
                    moveSelection(-1, extendSelection: hasShift)
                    return nil
                }
                return event
            case 40: // Cmd+K
                if hasCmd {
                    showCommandPalette.toggle()
                    if showCommandPalette { isSearchFocused = false }
                    return nil
                }
                return event
            case 48: switchType(hasShift ? -1 : 1); return nil  // Tab / Shift+Tab
            case 13: // Cmd+W
                if hasCmd { handleDismiss(); return nil }
                return event
            case 53:
                if isShowingSuggestions {
                    searchText = ""
                    groupSuggestionIndex = -1
                    return nil
                }
                if let qlPanel = QLPreviewPanel.shared(), qlPanel.isVisible {
                    qlPanel.orderOut(nil)
                    return nil
                }
                // If a group/app filter tag is active, Esc first clears the tag
                // (and any keyword) before dismissing the panel.
                if selectedGroupFilter != nil {
                    clearGroupFilter()
                    searchText = ""
                    isSearchFocused = true
                    return nil
                }
                handleDismiss(); return nil
            case 43: // Cmd+,
                if hasCmd {
                    handleDismiss()
                    AppAction.shared.openSettings?()
                    return nil
                }
                return event
            case 8: // Cmd+C
                if hasCmd {
                    // Check if preview area has text selected
                    if let textView = event.window?.firstResponder as? NSTextView,
                       textView.selectedRange().length > 0 {
                        return event // let system copy selected text
                    }
                    let items = isMultiSelected ? currentItems : (currentItem.map { [$0] } ?? [])
                    if !items.isEmpty { copyItemsToClipboard(items, dismissAfterCopy: true, playSound: true) }
                    return nil
                }
                return event
            case 51:
                if hasCmd {
                    if isSearchFocused, !searchText.isEmpty { return event }
                    handleDeleteSelected(); return nil
                }
                if isSearchFocused, searchText.isEmpty, selectedGroupFilter != nil {
                    clearGroupFilter()
                    return nil
                }
                return event
            case 31:
                if hasCmd { handleOpenLink(); return nil }
                return event
            case 36:
                // Let IME confirm its candidate before handling Enter
                if let textView = event.window?.firstResponder as? NSTextView,
                   textView.hasMarkedText() {
                    return event
                }
                if isMultiSelected {
                    handleMultiPaste(asPlainText: hasCmd, forceNewLine: hasShift)
                } else if hasCmd {
                    handleCmdEnter()
                } else if hasShift {
                    handlePaste(forceNewLine: true)
                } else {
                    handlePaste()
                }
                return nil
            default:
                if hasCmd, let digit = Self.digitKeyMap[Int(event.keyCode)] {
                    handleShortcutPaste(index: digit)
                    return nil
                }
                return event
            }
        }
    }

    /// Maps macOS key codes to digit values 1~9.
    private static let digitKeyMap: [Int: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
        22: 6, 26: 7, 28: 8, 25: 9,
    ]

    private var availableContentTypes: [ClipContentType] { store.availableTypes }

    private func switchType(_ delta: Int) {
        let types = availableContentTypes
        let allFilters: [QuickFilter] = [.pinned, .all] + types.map { .type($0) }

        if let idx = allFilters.firstIndex(of: selectedFilter) {
            let newIdx = (idx + delta + allFilters.count) % allFilters.count
            selectedFilter = allFilters[newIdx]
        } else {
            selectedFilter = delta > 0 ? allFilters.first! : allFilters.last!
        }
    }

    private func handleCommandAction(_ action: CommandAction) {
        showCommandPalette = false
        isSearchFocused = true
        switch action {
        case .paste:
            handlePaste(respectAutoPaste: false)
        case .cmdEnter:
            if isMultiSelected {
                handleMultiPaste(asPlainText: true, forceNewLine: false, respectAutoPaste: false)
            } else {
                handleCmdEnter(respectAutoPaste: false)
            }
        case .copy:
            let items = isMultiSelected ? currentItems : (currentItem.map { [$0] } ?? [])
            if !items.isEmpty { copyItemsToClipboard(items, dismissAfterCopy: true, playSound: true) }
        case .retryOCR:
            if let item = currentItem, item.contentType == .image, item.imageData != nil {
                OCRTaskCoordinator.shared.retry(itemID: item.itemID)
            }
        case .openInPreview:
            if let item = currentItem {
                QuickLookHelper.shared.openInPreviewApp(item: item)
            }
        case .addToRelay:
            let items = isMultiSelected ? currentItems : (currentItem.map { [$0] } ?? [])
            RelayManager.shared.enqueue(clipItems: items)
            if !RelayManager.shared.isActive { RelayManager.shared.activate() }
        case .splitAndRelay:
            if let item = currentItem, !item.content.isEmpty {
                relaySplitText = item.content
            }
        case .pin:
            if isMultiSelected {
                let items = currentItems
                let shouldPin = !items.contains(where: \.isPinned)
                for i in items { i.isPinned = shouldPin }
            } else {
                currentItem?.isPinned.toggle()
            }
            ClipItemStore.saveAndNotify(modelContext)
        case .toggleSensitive:
            if isMultiSelected {
                let items = currentItems
                let hasSensitive = items.contains(where: \.isSensitive)
                for i in items { i.isSensitive = !hasSensitive }
            } else {
                currentItem?.isSensitive.toggle()
            }
            ClipItemStore.saveAndNotify(modelContext)
        case .copyColorFormat(let format, _):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(format, forType: .string)
            showCopiedToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedToast = false }
        case .showInFinder:
            if let item = currentItem {
                let paths = item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
                if let first = paths.first {
                    NSWorkspace.shared.selectFile(first, inFileViewerRootedAtPath: "")
                }
            }
        case .transform(let ruleAction):
            if let item = currentItem {
                let processed = AutomationEngine.shared.applyAction(ruleAction, to: item.content)
                item.content = processed
                item.displayTitle = ClipItem.buildTitle(content: processed, contentType: item.contentType)
                if ruleAction == .stripRichText {
                    item.richTextData = nil
                    item.richTextType = nil
                }
                ClipItemStore.saveAndNotify(modelContext)
            }
        case .delete:
            handleDeleteSelected()
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor); flagsMonitor = nil }
        OptionKeyMonitor.shared.isOptionPressed = false
    }

    /// Returns 1-based shortcut index (1~9) for the item, or nil if beyond top 9.
    private func shortcutIndex(for item: ClipItem) -> Int? {
        guard let first9 = cachedDisplayOrder.prefix(9).firstIndex(where: { $0.persistentModelID == item.persistentModelID }) else { return nil }
        return first9 + 1
    }

    private func handleShortcutPaste(index: Int) {
        let items = displayOrderItems
        guard index >= 1, index <= 9, index <= items.count else { return }
        let target = items[index - 1]
        selectItem(target.persistentModelID)
        handlePaste()
    }

    private func isFileBasedItem(_ item: ClipItem) -> Bool {
        item.contentType.isFileBased && !(item.contentType == .image && item.content == "[Image]")
    }

    private func isPureImage(_ item: ClipItem) -> Bool {
        item.contentType == .image && item.content == "[Image]" && item.imageData != nil
    }

    private var canPasteToFinderFolder: Bool {
        guard let item = currentItem, item.imageData != nil else { return false }
        return clipboardManager.isFinderApp(QuickPanelWindowController.shared.previousApp)
    }

    private func handleMultiPaste(asPlainText: Bool, forceNewLine: Bool = false, respectAutoPaste: Bool = true) {
        let items = currentItems
        guard !items.isEmpty else { return }

        if respectAutoPaste && !quickPanelAutoPaste {
            guard !forceNewLine else { return }
            copyItemsToClipboard(items, dismissAfterCopy: true, playSound: true)
            return
        }

        // Target is Finder → special file handling
        if isTargetFinder, !asPlainText {
            handleMultiPasteToFinder(items)
            return
        }

        let previousApp = QuickPanelWindowController.shared.previousApp
        dismissAndRestoreApp { _ in
            if asPlainText {
                clipboardManager.pasteMultipleAsPlainText(items)
            } else {
                clipboardManager.pasteMultiple(items, forceNewLine: forceNewLine, targetApp: previousApp)
            }
        }
    }

    private func handleMultiPasteToFinder(_ items: [ClipItem]) {
        let fileItems = items.filter { isFileBasedItem($0) }
        let textItems = items.filter { !isFileBasedItem($0) && $0.content != "[Image]" }
        let imageItems = items.filter { isPureImage($0) }

        guard let folder = clipboardManager.getFinderSelectedFolder() else {
            // Fallback: paste as files if possible
            dismissAndRestoreApp { _ in clipboardManager.pasteMultiple(items) }
            return
        }

        // Save pure images to folder
        for img in imageItems {
            guard let data = img.imageData else { continue }
            _ = clipboardManager.saveImageToFolder(data, folder: folder)
        }

        // Merge text items into one file
        if !textItems.isEmpty, fileItems.isEmpty {
            let merged = textItems.map(\.content).joined(separator: "\n")
            _ = clipboardManager.saveTextToFolder(merged, folder: folder)
        }

        // File items: paste via file URLs
        if !fileItems.isEmpty {
            let allPaths = fileItems.flatMap { $0.content.components(separatedBy: "\n").filter { !$0.isEmpty } }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            clipboardManager.writeFileURLsToPasteboard(pasteboard, paths: allPaths)
            clipboardManager.lastChangeCount = pasteboard.changeCount
        }

        dismissAndRestoreApp { _ in
            if !fileItems.isEmpty {
                clipboardManager.simulatePaste()
            } else {
                // Images/texts saved to folder, just reveal in Finder
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
            }
        }
    }

    private func dismissAndRestoreApp(action: @escaping (NSRunningApplication) -> Void) {
        let appToRestore = QuickPanelWindowController.shared.previousApp
        QuickPanelWindowController.shared.dismiss()

        guard let app = appToRestore else { return }
        app.activate()
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
            }
            try? await Task.sleep(for: .milliseconds(50))
            action(app)
        }
    }

    private func copyItemsToClipboard(_ items: [ClipItem], dismissAfterCopy: Bool = false, playSound: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let merged = items.map(\.content).joined(separator: "\n")
        pasteboard.setString(merged, forType: .string)
        clipboardManager.lastChangeCount = pasteboard.changeCount
        items.forEach { $0.lastUsedAt = Date() }
        ClipItemStore.saveAndNotifyLastUsed(modelContext)

        if playSound {
            SoundManager.playCopy()
        }

        if dismissAfterCopy {
            QuickPanelWindowController.shared.dismiss()
            GlobalToast.show(L10n.tr("action.copied"))
            return
        }

        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedToast = false }
    }

    private func handleDeleteSelected() {
        let itemsToDelete = isMultiSelected ? currentItems : (currentItem.map { [$0] } ?? [])
        deleteItems(itemsToDelete)
    }

    private func copyDebugInfo(for item: ClipItem) {
        let hexContent = item.content.utf8.map { String(format: "%02x", $0) }.joined()
        let hexTitle = (item.displayTitle ?? "").utf8.map { String(format: "%02x", $0) }.joined()
        let info = """
            [PasteMemo Debug Info]
            itemID: \(item.itemID)
            contentType: \(item.contentType.rawValue)
            content.count: \(item.content.count)
            content.hex: \(hexContent)
            content.text: \(item.content)
            displayTitle.hex: \(hexTitle)
            displayTitle.text: \(item.displayTitle ?? "nil")
            hasRichText: \(item.richTextData != nil)
            richTextType: \(item.richTextType ?? "nil")
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }

    private func deleteItem(_ item: ClipItem) {
        deleteItems([item])
    }

    private func applyTransform(_ action: RuleAction, to item: ClipItem) {
        let processed = AutomationEngine.shared.applyAction(action, to: item.content)
        item.content = processed
        item.displayTitle = ClipItem.buildTitle(content: processed, contentType: item.contentType)
        if action == .stripRichText {
            item.richTextData = nil
            item.richTextType = nil
        }
        ClipItemStore.saveAndNotify(modelContext)
    }

    private func fetchEnabledRules() -> [AutomationRule] {
        let descriptor = FetchDescriptor<AutomationRule>(
            predicate: #Predicate { $0.enabled },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func applyRule(_ rule: AutomationRule, to item: ClipItem) {
        let actions = rule.actions
        guard !actions.isEmpty else { return }
        let processed = AutomationEngine.executeActions(actions, on: item.content)
        guard processed != item.content || actions.contains(.stripRichText) else { return }
        item.content = processed
        item.displayTitle = ClipItem.buildTitle(content: processed, contentType: item.contentType)
        if actions.contains(.stripRichText) {
            item.richTextData = nil
            item.richTextType = nil
        }
        ClipItemStore.saveAndNotify(modelContext)
    }

    private func deleteItems(_ itemsToDelete: [ClipItem]) {
        guard !itemsToDelete.isEmpty else { return }
        let items = filteredItems
        let idsToDelete = Set(itemsToDelete.map(\.persistentModelID))
        let firstIdx = items.firstIndex { idsToDelete.contains($0.persistentModelID) }
        for del in itemsToDelete {
            if let groupName = del.groupName, !groupName.isEmpty {
                ClipboardManager.shared.decrementSmartGroup(name: groupName, context: modelContext)
            }
            modelContext.delete(del)
        }
        ClipItemStore.saveAndNotify(modelContext)
        store.removeItems(matching: idsToDelete)
        let remaining = filteredItems
        if let idx = firstIdx, !remaining.isEmpty {
            let nextIdx = min(idx, remaining.count - 1)
            let nextID = remaining[nextIdx].persistentModelID
            selectedItemIDs = [nextID]
            lastNavigatedID = nextID
        } else {
            let firstID = remaining.first?.persistentModelID
            selectedItemIDs = firstID.map { [$0] } ?? []
            lastNavigatedID = firstID
        }
    }

    private func guideRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 14)
            Text(text)
        }
    }

    private func emptyHintKey(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
            Spacer()
        }
    }

    private func handleOpenLink() {
        guard let item = currentItem else { return }
        if item.contentType == .link,
           let url = URL(string: item.content.trimmingCharacters(in: .whitespacesAndNewlines)) {
            NSWorkspace.shared.open(url)
            handleDismiss()
        } else {
            QuickLookHelper.shared.toggle(item: item)
        }
    }

    private func handleDismiss() { HotkeyManager.shared.hideQuickPanel() }

    private var isTargetFinder: Bool {
        clipboardManager.isFinderApp(QuickPanelWindowController.shared.previousApp)
    }

    private var canSaveAttachmentToFolder: Bool {
        guard let item = currentItem,
              item.imageData != nil,
              item.contentType != .image else { return false }
        return isTargetFinder
    }

    private var canSaveTextToFolder: Bool {
        guard let item = currentItem,
              item.contentType == .text || item.contentType == .code,
              item.imageData == nil else { return false }
        return isTargetFinder
    }

    private var canSaveLinkToFolder: Bool {
        guard let item = currentItem,
              item.contentType == .link else { return false }
        return isTargetFinder
    }

    private func handleCmdEnter(respectAutoPaste: Bool = true) {
        guard let item = currentItem else { return }
        // Link → open in browser
        if item.contentType == .link,
           let url = URL(string: item.content.trimmingCharacters(in: .whitespacesAndNewlines)) {
            QuickPanelWindowController.shared.dismiss()
            NSWorkspace.shared.open(url)
        }
        // File-based (including file images) → paste path
        else if isFileBasedItem(item) {
            if !respectAutoPaste || quickPanelAutoPaste {
                handlePastePath()
            } else {
                copyItemToClipboardAndDismiss(item, plainTextOnly: true)
            }
        }
        // Pure text → save to folder if target is Finder
        else if canSaveTextToFolder {
            handlePasteTextToFolder()
        }
        // Text-like types → paste as plain text
        else if [.text, .code, .color, .email, .phone].contains(item.contentType) {
            if !respectAutoPaste || quickPanelAutoPaste {
                handlePlainTextPaste(item)
            } else {
                copyItemToClipboardAndDismiss(item, plainTextOnly: true)
            }
        }
    }

    private func copyItemToClipboardAndDismiss(_ item: ClipItem, plainTextOnly: Bool = false) {
        if plainTextOnly {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(item.content, forType: .string)
            clipboardManager.lastChangeCount = pasteboard.changeCount
        } else {
            clipboardManager.writeToPasteboard(item)
        }

        item.lastUsedAt = Date()
        if let context = item.modelContext {
            ClipItemStore.saveAndNotifyLastUsed(context)
        }
        SoundManager.playCopy()
        QuickPanelWindowController.shared.dismiss()
        GlobalToast.show(L10n.tr("action.copied"))
    }

    private func handlePlainTextPaste(_ item: ClipItem) {
        let appToRestore = QuickPanelWindowController.shared.previousApp
        QuickPanelWindowController.shared.dismiss()

        if let app = appToRestore {
            app.activate()
            Task { @MainActor in
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
                }
                try? await Task.sleep(for: .milliseconds(50))
                clipboardManager.pasteAsPlainText(item)
            }
        }
    }

    private func handlePasteTextToFolder() {
        guard let item = currentItem else { return }

        guard let folder = clipboardManager.getFinderSelectedFolder() else { return }

        let ext = item.resolvedFileExtension
        guard let savedURL = clipboardManager.saveTextToFolder(item.content, folder: folder, fileExtension: ext) else { return }

        let appToRestore = QuickPanelWindowController.shared.previousApp
        QuickPanelWindowController.shared.dismiss()

        if let app = appToRestore {
            app.activate()
            Task { @MainActor in
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
                }
                try? await Task.sleep(for: .milliseconds(100))
                NSWorkspace.shared.selectFile(savedURL.path, inFileViewerRootedAtPath: savedURL.deletingLastPathComponent().path)
            }
        }
    }

    private func handlePasteLinkToFolder() {
        guard let item = currentItem, item.contentType == .link else { return }
        guard let folder = clipboardManager.getFinderSelectedFolder() else { return }

        let content = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkTitle = item.linkTitle
        let cm = clipboardManager
        let appToRestore = QuickPanelWindowController.shared.previousApp
        QuickPanelWindowController.shared.dismiss()

        Task { @MainActor in
            let savedURL: URL? = await Self.saveLinkToFolder(content: content, linkTitle: linkTitle, folder: folder, clipboardManager: cm)
            guard let savedURL else { return }
            if let app = appToRestore {
                app.activate()
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
                }
                try? await Task.sleep(for: .milliseconds(100))
                NSWorkspace.shared.selectFile(savedURL.path, inFileViewerRootedAtPath: savedURL.deletingLastPathComponent().path)
            }
        }
    }

    private static func saveLinkToFolder(content: String, linkTitle: String?, folder: URL, clipboardManager: ClipboardManager) async -> URL? {
        if content.hasPrefix("data:image/") {
            // data:image URI → decode base64, save as PNG
            guard let commaIndex = content.firstIndex(of: ",") else { return nil }
            let base64 = String(content[content.index(after: commaIndex)...])
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
            return clipboardManager.saveImageToFolder(data, folder: folder)
        } else if LinkMetadataFetcher.isImageURL(content) {
            // Image URL → download and save as PNG
            guard let url = URL(string: content) else { return nil }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      NSImage(data: data) != nil else { return nil }
                return clipboardManager.saveImageToFolder(data, folder: folder)
            } catch {
                return nil
            }
        } else {
            // Regular link → save as .webloc
            let title = linkTitle ?? (URL(string: content)?.host ?? "link")
            let safeName = String(title
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
                .trimmingCharacters(in: .controlCharacters)
                .prefix(50))
            let fileURL = folder.appendingPathComponent("\(safeName).webloc")
            let dict: NSDictionary = ["URL": content]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return nil }
            try? data.write(to: fileURL)
            return fileURL
        }
    }

    private func handlePasteImage() {
        guard let item = currentItem, let imageData = item.imageData else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(imageData, forType: .tiff)
        clipboardManager.lastChangeCount = pasteboard.changeCount
        SoundManager.playPaste()

        let appToRestore = QuickPanelWindowController.shared.previousApp
        QuickPanelWindowController.shared.dismiss()

        if let app = appToRestore {
            app.activate()
            Task { @MainActor in
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
                }
                try? await Task.sleep(for: .milliseconds(50))
                clipboardManager.simulatePaste()
            }
        }
    }

    private func handlePastePath() {
        guard let item = currentItem, isFileBasedItem(item) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.content, forType: .string)
        clipboardManager.lastChangeCount = pasteboard.changeCount
        SoundManager.playPaste()

        let appToRestore = QuickPanelWindowController.shared.previousApp
        QuickPanelWindowController.shared.dismiss()

        if let app = appToRestore {
            app.activate()
            Task { @MainActor in
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
                }
                try? await Task.sleep(for: .milliseconds(50))
                clipboardManager.simulatePaste()
            }
        }
    }

    private func handlePaste(forceNewLine: Bool = false, respectAutoPaste: Bool = true) {
        guard let item = currentItem else { return }
        if respectAutoPaste && !quickPanelAutoPaste {
            guard !forceNewLine else { return }
            if isFileBasedItem(item) {
                copyItemToClipboardAndDismiss(item, plainTextOnly: true)
            } else {
                copyItemToClipboardAndDismiss(item)
            }
            return
        }
        if canPasteToFinderFolder {
            handlePasteImageToFolder()
        } else if canSaveLinkToFolder {
            handlePasteLinkToFolder()
        } else if canSaveTextToFolder {
            handlePasteTextToFolder()
        } else {
            QuickPanelWindowController.shared.dismissAndPaste(
                item,
                clipboardManager: clipboardManager,
                addNewLine: forceNewLine
            )
        }
    }

    private func handlePasteImageToFolder() {
        guard let item = currentItem, let imageData = item.imageData else {
            // No image data, fallback to normal paste
            if let item = currentItem {
                QuickPanelWindowController.shared.dismissAndPaste(item, clipboardManager: clipboardManager)
            }
            return
        }

        guard let folder = clipboardManager.getFinderSelectedFolder() else {
            // Can't get folder, fallback to paste image
            handlePasteImage()
            return
        }

        guard let savedURL = clipboardManager.saveImageToFolder(imageData, folder: folder) else {
            // Save failed, fallback to paste image
            handlePasteImage()
            return
        }

        let appToRestore = QuickPanelWindowController.shared.previousApp
        QuickPanelWindowController.shared.dismiss()

        if let app = appToRestore {
            app.activate()
            Task { @MainActor in
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
                }
                try? await Task.sleep(for: .milliseconds(100))
                NSWorkspace.shared.selectFile(savedURL.path, inFileViewerRootedAtPath: savedURL.deletingLastPathComponent().path)
            }
        }
    }

}

struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }
}
