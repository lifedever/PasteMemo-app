import SwiftUI
import SwiftData
import AppKit

enum SidebarFilter: Equatable {
    case all
    case pinned
    case sensitive
    case snippets
    case type(ClipContentType)
    case app(String)
    case group(String)

    @MainActor
    var title: String {
        switch self {
        case .all: return L10n.tr("filter.all")
        case .pinned: return L10n.tr("filter.pinned")
        case .sensitive: return L10n.tr("filter.sensitive")
        case .snippets: return L10n.tr("snippet.titlePlural")
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
    @State private var snippetStore = SnippetStore()
    @State private var searchText = ""
    @State private var selectedFilter: SidebarFilter = .all
    @State private var selectedItems: Set<ClipItem.ID> = []
    @State private var selectedSnippetIDs: Set<SnippetItem.ID> = []
    @State private var typeOrder: [ClipContentType] = ClipContentType.visibleCases
    @State private var draggingType: ClipContentType?
    @State private var draggingGroup: String?

    private var selectedItem: ClipItem? {
        guard selectedItems.count == 1, let id = selectedItems.first else { return nil }
        return store.items.first { $0.persistentModelID == id }
    }
    private var selectedSnippet: SnippetItem? {
        guard selectedSnippetIDs.count == 1, let selectedSnippetID = selectedSnippetIDs.first else { return nil }
        return snippetStore.items.first { $0.persistentModelID == selectedSnippetID }
    }
    private var selectedSnippets: [SnippetItem] {
        let ids = selectedSnippetIDs
        return filteredSnippets.filter { ids.contains($0.persistentModelID) }
    }
    @Environment(\.openWindow) private var openWindow
    @State private var showDeleteConfirm = false
    @State private var showCopiedToast = false
    @State private var toastMessage = ""
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var scrollTarget: ClipItem.ID?
    @State private var relaySplitText: String?
    @State private var showCommandPalette = false
    @AppStorage("hideDockIcon") private var hideDockIcon = false
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    private var sourceApps: [String] { store.sourceApps }

    private func bundleIDForApp(_ appName: String) -> String? {
        store.items.first { $0.sourceApp == appName }?.sourceAppBundleID
    }

    private var filteredItems: [ClipItem] { store.items.filter { !$0.isDeleted } }

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
            selectedSnippetIDs.removeAll()
            syncStoreFilter()
        }
        .onChange(of: searchText) {
            selectedItems.removeAll()
            selectedSnippetIDs.removeAll()
            if selectedFilter == .snippets {
                snippetStore.searchText = searchText
            } else {
                store.searchText = searchText
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("clearSelection"))) { _ in
            selectedItems.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("deleteSelectedFromDetail"))) { _ in
            deleteSelectedItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("copyItemFromDetail"))) { _ in
            showCopiedToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedToast = false }
        }
        .onAppear {
            store.sortPinnedFirst = true
            store.isActive = true
            store.configure(modelContext: modelContext)
            snippetStore.configure(modelContext: modelContext)
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
                    if selectedFilter == .snippets, let snippet = selectedSnippet {
                        SnippetLibrary.copyToClipboard(snippet)
                        showCopiedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedToast = false }
                        return nil
                    }
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
                if event.keyCode == 40, event.modifierFlags.contains(.command), (selectedFilter == .snippets ? !selectedSnippetIDs.isEmpty : !selectedItems.isEmpty) {
                    showCommandPalette.toggle()
                    return nil
                }

                guard !isSearchFieldEditing, !isEditableTextViewActive else { return event }

                if selectedFilter == .snippets {
                    if event.keyCode == 51, selectedSnippet != nil {
                        deleteSelectedSnippet()
                        return nil
                    }
                    if event.keyCode == 0, event.modifierFlags.contains(.command) {
                        selectedSnippetIDs = Set(filteredSnippets.map(\.persistentModelID))
                        return nil
                    }
                    return event
                }

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
                if selectedFilter == .snippets {
                    Button {
                        createEmptySnippetAndSelect()
                    } label: {
                        Label(L10n.tr("snippet.new"), systemImage: "plus")
                    }
                    .help(L10n.tr("snippet.new"))
                }
            }
            ToolbarItem(placement: .automatic) {
                Picker(L10n.tr("history.sort"), selection: $store.sortMode) {
                    ForEach(HistorySortMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .help(L10n.tr("history.sort"))
            }
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
            if showCopiedToast {
                VStack {
                    Spacer()
                    Text(toastMessage.isEmpty ? L10n.tr("action.copied") : toastMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.75), in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .padding(.bottom, 20)
                }
                .animation(.easeInOut(duration: 0.2), value: showCopiedToast)
            }
        }
        .localized()
        .alert(L10n.tr("action.clearAll"), isPresented: $showDeleteConfirm) {
            Button(L10n.tr("action.delete"), role: .destructive) {
                let descriptor = FetchDescriptor<ClipItem>(
                    predicate: #Predicate { !$0.isPinned }
                )
                if let items = try? modelContext.fetch(descriptor) {
                    ClipItemStore.deleteAndNotify(items, from: modelContext)
                }
                ClipboardManager.shared.recalculateAllGroupCounts(context: modelContext)
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
            AppAction.shared.showNewSnippetWindow = {
                AppAction.shared.openMainWindow?()
                NotificationCenter.default.post(name: Notification.Name("createSnippetFromMenu"), object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("createSnippetFromMenu"))) { _ in
            createEmptySnippetAndSelect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .snippetShouldOpenInManager)) { note in
            guard let snippetID = note.object as? PersistentIdentifier else { return }
            selectedFilter = .snippets
            snippetStore.reload()
            selectedSnippetIDs = [snippetID]
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
    }

    // MARK: - Sidebar

    private func syncStoreFilter() {
        if selectedFilter == .snippets {
            snippetStore.searchText = searchText
            return
        }
        store.pinnedOnly = false
        store.sensitiveOnly = false
        store.filterType = nil
        store.sourceApp = nil
        store.groupName = nil
        switch selectedFilter {
        case .all: break
        case .pinned: store.pinnedOnly = true
        case .sensitive: store.sensitiveOnly = true
        case .snippets: break
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

                sidebarRow(L10n.tr("snippet.titlePlural"), icon: "bookmark", badge: snippetStore.totalCount, isActive: selectedFilter == .snippets) {
                    selectedFilter = .snippets
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
                        sidebarRow(group.name, icon: group.icon, badge: group.count, isActive: selectedFilter == .group(group.name)) {
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

    private func sidebarRow(_ title: String, icon: String, badge: Int = 0, isActive: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(isActive ? .white : .secondary)
                .frame(width: 18)
            Text(title)
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

    // MARK: - Clip List

    private var groupedFilteredItems: [GroupedItem<ClipItem>] {
        groupItemsByTime(filteredItems, sortMode: store.sortMode)
    }

    private var filteredSnippets: [SnippetItem] { snippetStore.items }

    /// Items in visual display order (matching grouped section rendering)
    private var visualOrderedItems: [ClipItem] {
        groupedFilteredItems.flatMap(\.items)
    }

    private var clipListView: some View {
        if selectedFilter == .snippets {
            return AnyView(snippetListView)
        }

        return AnyView(historyListView)
    }

    private var historyListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groupedFilteredItems, id: \.group) { group in
                        Text(group.group.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 2)

                        ForEach(group.items) { item in
                            mainListRow(item: item)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(target, anchor: .center)
                }
                scrollTarget = nil
            }
        }
        .navigationTitle(selectedFilter.title)
        .navigationSubtitle("\(store.totalCount) \(L10n.tr("stats.clips"))")
        .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 450)
    }

    private var snippetListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredSnippets) { snippet in
                        let snippetID = snippet.persistentModelID
                        let isSelected = selectedSnippetIDs.contains(snippetID)
                        SnippetRow(snippet: snippet, isSelected: isSelected)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 1)
                            )
                            .padding(.trailing, 4)
                            .contentShape(Rectangle())
                            .id(snippetID)
                            .popover(
                                isPresented: Binding(
                                    get: {
                                        showCommandPalette
                                            && selectedSnippetIDs.contains(snippetID)
                                            && selectedSnippetIDs.count == 1
                                    },
                                    set: { if !$0 { showCommandPalette = false } }
                                ),
                                arrowEdge: .trailing
                            ) {
                                CommandPaletteContent(
                                    item: nil,
                                    snippet: snippet,
                                    isMultiSelected: false,
                                    onAction: { handleSnippetCommandAction($0, snippet: snippet) },
                                    onDismiss: { showCommandPalette = false }
                                )
                            }
                            .onTapGesture {
                                handleSnippetRowClick(snippet)
                            }
                            .contextMenu {
                                Button(L10n.tr("cmd.copy")) {
                                    SnippetLibrary.copyToClipboard(snippet)
                                }
                                Button(L10n.tr("snippet.groupChoose")) {
                                    GroupEditorPanel.show(name: snippet.groupName ?? "", icon: "folder") { result in
                                        guard let result else { return }
                                        snippet.groupName = result.name
                                        SnippetLibrary.saveAndNotify(modelContext)
                                    }
                                }
                                if snippet.groupName != nil {
                                    Button(L10n.tr("snippet.groupClear")) {
                                        snippet.groupName = nil
                                        SnippetLibrary.saveAndNotify(modelContext)
                                    }
                                }
                                Button(snippet.isPinned ? L10n.tr("action.unpin") : L10n.tr("action.pin")) {
                                    snippet.isPinned.toggle()
                                    SnippetLibrary.saveAndNotify(modelContext)
                                }
                                Divider()
                                Button(L10n.tr("snippet.delete"), role: .destructive) {
                                    if !selectedSnippetIDs.contains(snippetID) {
                                        selectedSnippetIDs = [snippetID]
                                    }
                                    deleteSelectedSnippet()
                                }
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedSnippet) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(target.persistentModelID, anchor: .center)
                }
            }
        }
        .navigationTitle(L10n.tr("snippet.titlePlural"))
        .navigationSubtitle(L10n.tr("snippet.count", snippetStore.totalCount))
        .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 450)
    }

    @ViewBuilder
    private func mainListRow(item: ClipItem) -> some View {
        if item.isDeleted { EmptyView() } else {
        let contentType = item.contentType
        let isSelected = selectedItems.contains(item.persistentModelID)
        ClipItemListRow(
            item: item,
            isSelected: isSelected,
            groupIcon: store.sidebarCounts.byGroup.first { $0.name == item.groupName }?.icon,
            searchText: searchText,
            sortMode: store.sortMode
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
            .contentShape(Rectangle())
            .id(item.persistentModelID)
            .onAppear {
                if item.id == filteredItems.last?.id { store.loadMore() }
            }
            .popover(
                isPresented: Binding(
                    get: {
                        showCommandPalette && isSelected
                        && (selectedItems.count <= 1 || (navigationCursor ?? selectedItems.first) == item.persistentModelID)
                    },
                    set: { if !$0 { showCommandPalette = false } }
                ),
                arrowEdge: .trailing
            ) {
                CommandPaletteContent(
                    item: item,
                    snippet: nil,
                    isMultiSelected: selectedItems.count > 1,
                    onAction: { handleMainCommandAction($0, item: item) },
                    onDismiss: { showCommandPalette = false }
                )
            }
            .onTapGesture { handleRowClick(item) }
            .onRightClick {
                if !selectedItems.contains(item.persistentModelID) {
                    selectedItems = [item.persistentModelID]
                    navigationCursor = item.persistentModelID
                }
            }
            .contextMenu {
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
                if !(selectedItems.contains(item.persistentModelID) && selectedItems.count > 1) {
                    Button(L10n.tr("snippet.saveAs")) {
                        saveSelectedItemAsSnippet(item)
                    }
                }
                if selectedItems.count > 1, selectedClipItems.allSatisfy({ $0.contentType.isMergeable }) {
                    Button(L10n.tr("action.merge")) { mergeSelectedItems() }
                }
                if contentType.isMergeable,
                   ProManager.AUTOMATION_ENABLED {
                    let rules = fetchEnabledAutomationRules()
                    if !rules.isEmpty {
                        Divider()
                        Menu(L10n.tr("cmd.automation")) {
                            ForEach(rules) { rule in
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
                            Button {
                                // Already in this group — no-op
                            } label: {
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
                        RelayManager.shared.enqueue(clipItems: selectedClipItems)
                        if !RelayManager.shared.isActive {
                            RelayManager.shared.activate()
                        }
                    }
                } else if !item.content.isEmpty || item.imageData != nil {
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
                Button(L10n.tr("action.delete"), role: .destructive) {
                    if !selectedItems.contains(item.persistentModelID) {
                        selectedItems = [item.persistentModelID]
                    }
                    deleteSelectedItems()
                }
                } // isDeleted guard
            }
        }
    }

    private func handleRowClick(_ item: ClipItem) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let id = item.persistentModelID
        navigationCursor = id

        if flags.contains(.command) {
            // Cmd+Click: toggle this item in selection
            if selectedItems.contains(id) {
                selectedItems.remove(id)
            } else {
                selectedItems.insert(id)
            }
        } else if flags.contains(.shift), let lastID = selectedItems.first {
            // Shift+Click: range select
            let items = visualOrderedItems
            guard let lastIdx = items.firstIndex(where: { $0.persistentModelID == lastID }),
                  let clickIdx = items.firstIndex(where: { $0.persistentModelID == id }) else {
                selectedItems = [id]
                return
            }
            let range = min(lastIdx, clickIdx)...max(lastIdx, clickIdx)
            selectedItems = Set(items[range].map(\.persistentModelID))
        } else {
            if selectedItems == [id] {
                selectedItems.removeAll()
            } else {
                selectedItems = [id]
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
        for old in items { modelContext.delete(old) }
        try? modelContext.save()
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
        case .cmdEnter:
            if item.contentType == .link,
               let url = URL(string: item.content.trimmingCharacters(in: .whitespacesAndNewlines)) {
                NSWorkspace.shared.open(url)
            } else {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(item.content, forType: .string)
                showCopiedToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedToast = false }
            }
        case .copy:
            if selectedItems.count > 1 {
                copySelectedToClipboard()
            } else {
                copyToClipboard(item)
            }
        case .saveAsSnippet:
            saveSelectedItemAsSnippet(item)
        case .retryOCR:
            if item.contentType == .image, item.imageData != nil {
                OCRTaskCoordinator.shared.retry(itemID: item.itemID)
            }
        case .openInPreview:
            QuickLookHelper.shared.openInPreviewApp(item: item)
        case .addToRelay:
            let items = selectedItems.count > 1 ? selectedClipItems : [item]
            RelayManager.shared.enqueue(clipItems: items)
            if !RelayManager.shared.isActive { RelayManager.shared.activate() }
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
            showCopiedToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedToast = false }
        case .showInFinder:
            let paths = item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
            if let first = paths.first {
                NSWorkspace.shared.selectFile(first, inFileViewerRootedAtPath: "")
            }
        case .transform(let ruleAction):
            let processed = AutomationEngine.shared.applyAction(ruleAction, to: item.content)
            item.content = processed
            item.displayTitle = ClipItem.buildTitle(content: processed, contentType: item.contentType)
            if ruleAction == .stripRichText {
                item.richTextData = nil
                item.richTextType = nil
            }
            ClipItemStore.saveAndNotify(modelContext)
        case .delete:
            deleteSelectedItems()
        case .openSnippetInManager:
            break
        }
    }

    private func copySelectedToClipboard() {
        let items = selectedClipItems.sorted { $0.createdAt < $1.createdAt }
        guard !items.isEmpty else { return }
        let merged = items.map(\.content).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(merged, forType: .string)
        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedToast = false }
    }

    private func copyToClipboard(_ item: ClipItem) {
        clipboardManager.writeToPasteboard(item)
        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopiedToast = false
        }
    }

    private func createEmptySnippetAndSelect() {
        selectedFilter = .snippets
        let snippet = SnippetLibrary.createEmpty(in: modelContext)
        snippetStore.reload()
        selectedSnippetIDs = [snippet.persistentModelID]
    }

    private func saveSelectedItemAsSnippet(_ item: ClipItem) {
        DispatchQueue.main.async {
            guard let saveInput = SnippetLibrary.promptForTitle(for: item) else {
                return
            }

            let snippet = SnippetLibrary.saveSnippet(from: item, title: saveInput.title, in: modelContext) { duplicate in
                duplicatePromptChoice(for: duplicate)
            }
            guard let snippet else {
                return
            }

            snippetStore.reload()
            selectedFilter = .snippets
            selectedSnippetIDs = [snippet.persistentModelID]
            toastMessage = L10n.tr("snippet.saved")
            showCopiedToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showCopiedToast = false
                toastMessage = ""
            }
        }
    }

    private func deleteSelectedSnippet() {
        let snippets = selectedSnippets
        guard !snippets.isEmpty else { return }
        for snippet in snippets {
            modelContext.delete(snippet)
        }
        SnippetLibrary.saveAndNotify(modelContext)
        snippetStore.reload()
        selectedSnippetIDs = Set(snippetStore.items.prefix(1).map(\.persistentModelID))
    }

    private func duplicatePromptChoice(for duplicate: SnippetItem) -> SnippetSaveChoice {
        let alert = NSAlert()
        alert.messageText = L10n.tr("snippet.duplicateTitle")
        alert.informativeText = L10n.tr("snippet.duplicateMessage", duplicate.resolvedTitle)
        alert.addButton(withTitle: L10n.tr("snippet.updateExisting"))
        alert.addButton(withTitle: L10n.tr("snippet.createNew"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .updateExisting
        case .alertSecondButtonReturn: return .createNew
        default: return .cancel
        }
    }

    private func handleSnippetRowClick(_ snippet: SnippetItem) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let id = snippet.persistentModelID

        if flags.contains(.command) {
            if selectedSnippetIDs.contains(id) {
                selectedSnippetIDs.remove(id)
            } else {
                selectedSnippetIDs.insert(id)
            }
        } else {
            if selectedSnippetIDs == [id] {
                selectedSnippetIDs.removeAll()
            } else {
                selectedSnippetIDs = [id]
            }
        }
    }

    private func handleSnippetCommandAction(_ action: CommandAction, snippet: SnippetItem) {
        showCommandPalette = false
        switch action {
        case .paste:
            SnippetLibrary.copyToClipboard(snippet)
            showCopiedToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedToast = false }
        case .copy:
            SnippetLibrary.copyToClipboard(snippet)
            showCopiedToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedToast = false }
        case .addToRelay:
            let texts = snippet.content.isEmpty ? [] : [snippet.content]
            RelayManager.shared.enqueue(texts: texts)
            if !RelayManager.shared.isActive { RelayManager.shared.activate() }
        case .splitAndRelay:
            if !snippet.content.isEmpty { relaySplitText = snippet.content }
        case .pin:
            snippet.isPinned.toggle()
            SnippetLibrary.saveAndNotify(modelContext)
        case .delete:
            selectedSnippetIDs = [snippet.persistentModelID]
            deleteSelectedSnippet()
        case .openSnippetInManager:
            SnippetLibrary.openInManager(snippet.persistentModelID)
        default:
            break
        }
    }

    private func assignTags(to snippets: [SnippetItem], tags: [String]) {
        guard !tags.isEmpty else { return }
        for snippet in snippets {
            snippet.tags = Array((snippet.tags + tags).reduce(into: [String]()) { result, tag in
                guard !result.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
                result.append(tag)
            })
        }
        SnippetLibrary.saveAndNotify(modelContext)
    }

    private func removeTags(from snippets: [SnippetItem], tags: [String]) {
        guard !tags.isEmpty else { return }
        for snippet in snippets {
            snippet.tags.removeAll { existing in
                tags.contains(where: { $0.caseInsensitiveCompare(existing) == .orderedSame })
            }
        }
        SnippetLibrary.saveAndNotify(modelContext)
    }

    private func promptForTags(titleKey: String, messageKey: String) -> [String]? {
        let alert = NSAlert()
        alert.messageText = L10n.tr(titleKey)
        alert.informativeText = L10n.tr(messageKey)
        alert.addButton(withTitle: L10n.tr("action.confirm"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = L10n.tr("snippet.tagsPlaceholder")
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return SnippetItem.parseTags(from: input.stringValue)
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

        let hasSpecialActions = actions.contains { action in
            switch action {
            case .stripRichText, .assignGroup, .markSensitive, .pin, .skipCapture: return true
            default: return false
            }
        }

        ClipItemStore.isBulkOperation = true
        for target in items {
            let processed = AutomationEngine.executeActions(actions, on: target.content)
            guard processed != target.content || hasSpecialActions else { continue }
            target.content = processed
            target.displayTitle = ClipItem.buildTitle(content: processed, contentType: target.contentType)
            if actions.contains(.stripRichText) {
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

        toastMessage = L10n.tr("automation.applied")
        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedToast = false; toastMessage = "" }
    }

    private func changeGroupIcon(name: String) {
        let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == name })
        guard let group = try? modelContext.fetch(descriptor).first else { return }
        GroupEditorPanel.show(name: group.name, icon: group.icon) { result in
            guard let result else { return }
            group.icon = result.icon
            try? modelContext.save()
            store.refreshSidebarCounts()
        }
    }

    private func editGroup(name: String) {
        let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == name })
        guard let group = try? modelContext.fetch(descriptor).first else { return }
        AppMenuActions.showEditGroupAlert(group: group, context: modelContext) { oldName, newName in
            guard oldName != newName else {
                store.refreshSidebarCounts()
                return
            }

            let itemDescriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.groupName == oldName })
            if let items = try? modelContext.fetch(itemDescriptor) {
                for item in items { item.groupName = newName }
            }
            try? modelContext.save()

            if selectedFilter == .group(oldName) {
                selectedFilter = .group(newName)
            }

            store.refreshSidebarCounts()
        }
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
        GroupEditorPanel.show() { result in
            guard let result else { return }
            let name = result.name
            let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == name })
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.icon = result.icon
            } else {
                let maxOrder = (try? modelContext.fetch(FetchDescriptor<SmartGroup>()))?.map(\.sortOrder).max() ?? -1
                let group = SmartGroup(name: result.name, icon: result.icon, sortOrder: maxOrder + 1)
                modelContext.insert(group)
            }
            try? modelContext.save()
            assignToGroup(items: items, name: result.name)
        }
    }

    private func deleteSelectedItems() {
        let items = visualOrderedItems
        let visibleIDs = Set(items.map(\.persistentModelID))
        let idsToDelete = selectedItems.intersection(visibleIDs)
        guard !idsToDelete.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = L10n.tr("action.deleteSelected.confirm", idsToDelete.count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("action.delete"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Find the lowest index among deleted items for successor selection
        let firstDeletedIdx = items.firstIndex { idsToDelete.contains($0.persistentModelID) }

        let itemsToDelete = items.filter { idsToDelete.contains($0.persistentModelID) }
        for item in itemsToDelete {
            if let groupName = item.groupName, !groupName.isEmpty {
                ClipboardManager.shared.decrementSmartGroup(name: groupName, context: modelContext)
            }
        }
        ClipItemStore.deleteAndNotify(itemsToDelete, from: modelContext)

        // Select next item after deletion
        let remaining = items.filter { !idsToDelete.contains($0.persistentModelID) }
        if !remaining.isEmpty, let idx = firstDeletedIdx {
            let nextIdx = min(idx, remaining.count - 1)
            let nextID = remaining[nextIdx].persistentModelID
            selectedItems = [nextID]
            navigationCursor = nextID
            scrollTarget = nextID
        } else {
            selectedItems.removeAll()
            navigationCursor = nil
        }

        store.refreshSidebarCounts()
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        if selectedFilter == .snippets {
            if let snippet = selectedSnippet {
                SnippetDetailView(snippet: snippet) {
                    deleteSelectedSnippet()
                }
            } else if selectedSnippetIDs.count > 1 {
                snippetMultiSelectView
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
        } else if selectedItems.count == 1, let item = selectedItem {
            ClipDetailView(
                item: item,
                clipboardManager: clipboardManager,
                onSaveAsSnippet: {
                    saveSelectedItemAsSnippet(item)
                }
            )
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
    private var snippetMultiSelectView: some View {
        let snippets = selectedSnippets
        let hasPinned = snippets.contains(where: \.isPinned)
        let hasGrouped = snippets.contains(where: { $0.groupName != nil })

        VStack(spacing: 0) {
            Spacer()

            Text(L10n.tr("detail.multiSelected", selectedSnippetIDs.count))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.6))
                .padding(.bottom, 12)

            snippetMultiSelectTypeChips(snippets)
                .padding(.bottom, 24)

            VStack(spacing: 0) {
                multiActionRow(L10n.tr("cmd.copy"), icon: "doc.on.doc") {
                    let joined = snippets.map(\.content).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(joined, forType: .string)
                    showCopiedToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopiedToast = false }
                }
                multiActionRow(hasPinned ? L10n.tr("action.unpin") : L10n.tr("action.pin"), icon: hasPinned ? "pin.slash" : "pin") {
                    let newValue = !hasPinned
                    for snippet in snippets { snippet.isPinned = newValue }
                    SnippetLibrary.saveAndNotify(modelContext)
                }
                snippetMultiActionGroupMenu(snippets: snippets)
                if hasGrouped {
                    multiActionRow(L10n.tr("action.removeFromGroup"), icon: "folder.badge.minus") {
                        for snippet in snippets { snippet.groupName = nil }
                        SnippetLibrary.saveAndNotify(modelContext)
                    }
                }
                multiActionRow(L10n.tr("snippet.addTags"), icon: "tag") {
                    if let tags = promptForTags(titleKey: "snippet.addTags", messageKey: "snippet.tagsPrompt") {
                        assignTags(to: snippets, tags: tags)
                    }
                }
                multiActionRow(L10n.tr("snippet.removeTags"), icon: "tag.slash") {
                    if let tags = promptForTags(titleKey: "snippet.removeTags", messageKey: "snippet.tagsPrompt") {
                        removeTags(from: snippets, tags: tags)
                    }
                }

                Divider().padding(.vertical, 4)

                Button {
                    deleteSelectedSnippet()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .frame(width: 18)
                        Text(L10n.tr("action.deleteSelected", selectedSnippetIDs.count))
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
            .frame(maxWidth: 240)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    RelayManager.shared.enqueue(clipItems: items)
                    if !RelayManager.shared.isActive { RelayManager.shared.activate() }
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

    private func snippetMultiActionGroupMenu(snippets: [SnippetItem]) -> some View {
        Menu {
            ForEach(store.sidebarCounts.byGroup, id: \.name) { group in
                Button(group.name) {
                    for snippet in snippets { snippet.groupName = group.name }
                    SnippetLibrary.saveAndNotify(modelContext)
                }
            }
            if !store.sidebarCounts.byGroup.isEmpty { Divider() }
            Button(L10n.tr("action.newGroup")) {
                GroupEditorPanel.show() { result in
                    guard let result else { return }
                    let groupName = result.name
                    let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == groupName })
                    if let existing = try? modelContext.fetch(descriptor).first {
                        existing.icon = result.icon
                    } else {
                        let maxOrder = (try? modelContext.fetch(FetchDescriptor<SmartGroup>()))?.map(\.sortOrder).max() ?? -1
                        let group = SmartGroup(name: result.name, icon: result.icon, sortOrder: maxOrder + 1)
                        modelContext.insert(group)
                    }
                    try? modelContext.save()
                    for snippet in snippets { snippet.groupName = result.name }
                    SnippetLibrary.saveAndNotify(modelContext)
                    store.refreshSidebarCounts()
                }
            }
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

        HStack(spacing: 6) {
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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func snippetMultiSelectTypeChips(_ items: [SnippetItem]) -> some View {
        let counts = items.reduce(into: [ClipContentType: Int]()) { $0[$1.contentType, default: 0] += 1 }
        let sorted = counts.sorted { $0.value > $1.value }

        HStack(spacing: 6) {
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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.secondary)
            }
        }
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
    var sortMode: HistorySortMode = .lastUsed

    var body: some View {
        ClipRow(item: item, isSelected: isSelected, groupIcon: groupIcon, searchText: searchText, sortMode: sortMode)
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
