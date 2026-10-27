import SwiftUI
import SwiftData

// MARK: - 设置 → 数据（存储空间 + 自动清理 + 备份 + 导入导出）

struct DataPane: View {
    @EnvironmentObject private var nav: SettingsNavigationModel
    @EnvironmentObject private var storage: StorageModel
    @ObservedObject private var optimizer = OriginalImageOptimizer.shared
    @AppStorage(OriginalImageOptimizer.ENABLED_KEY) private var optimizeTIFF = true

    var body: some View {
        Form {
            Section(L10n.tr("settings.storage")) {
                summary
                locationRow
            }
            if storage.snapshot != nil {
                let totals = StorageQuery.categoryTotals(storage.cleanable)
                if !totals.isEmpty {
                    Section(L10n.tr("storage.byType")) {
                        ForEach(totals, id: \.category) { total in
                            HStack {
                                Text(total.category.label)
                                Spacer()
                                Text(L10n.tr("storage.itemCount", total.count.formatted()))
                                    .foregroundStyle(.secondary)
                                Text(StorageFormat.bytes(total.bytes))
                                    .monospacedDigit()
                                    .frame(minWidth: 80, alignment: .trailing)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // The type page reads the type-grouped list, which ignores the
                                // manage page's type menu.
                                storage.resetFilters()
                                storage.grouping = .type
                                nav.push(.storageGroup(.category(total.category)))
                            }
                            .pointerCursor()
                        }
                    }
                }
            }
            HistorySection()
            optimizeSection
            BackupSection()
            DataPorterSection()
        }
        .formStyle(.grouped)
        .task {
            await storage.refresh()
            // Switch on but TIFFs still around (new since launch, or the launch pass hasn't run).
            if optimizeTIFF { await storage.convertTIFFs() }
        }
        // A batch finishing elsewhere (the launch pass) changes the totals shown here.
        .onChange(of: optimizer.progress == nil) { _, idle in
            if idle { Task { await storage.refresh() } }
        }
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if storage.snapshot != nil {
                    Text(StorageFormat.bytes(storage.cleanable.map(\.bytes).reduce(0, +)))
                        .font(.system(size: 26, weight: .semibold))
                        .monospacedDigit()
                    Text(L10n.tr("storage.recordCount", storage.cleanable.count.formatted()))
                        .foregroundStyle(.secondary)
                } else if storage.scanFailed {
                    Text(L10n.tr("storage.scanFailed"))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("storage.scanning"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.tr("storage.manage")) {
                    storage.resetFilters()
                    nav.push(.storageManage)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(storage.snapshot == nil)
                    .pointerCursor()
            }
            if storage.snapshot != nil {
                let parts = Self.parts(of: storage.cleanable)
                StorageUsageBar(parts: parts.map { ($0.color, $0.bytes) })
                WrappingHStack(spacing: 16, lineSpacing: 4, alignment: .leading) {
                    ForEach(parts, id: \.label) { part in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 9, height: 9)
                            Text(part.label).foregroundStyle(.secondary)
                            Text(StorageFormat.bytes(part.bytes)).monospacedDigit()
                        }
                        .font(.system(size: 12))
                    }
                }
                if storage.protectedCount > 0 {
                    Text(L10n.tr("storage.protectedExcluded", storage.protectedCount.formatted()))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// What the records take, split by kind. Only what this page can delete: the database's own
    /// overhead (search index, change history, journal), backups, and pinned / permanent-group
    /// clips can't be removed here, and counting them raised "I deleted everything — why 28 MB?".
    private static func parts(of records: [StorageRecord]) -> [(label: String, color: Color, bytes: Int64)] {
        [
            (L10n.tr("storage.part.originals"), .blue, records.map(\.originalBytes).reduce(0, +)),
            (L10n.tr("storage.part.previews"), .teal, records.map(\.previewBytes).reduce(0, +)),
            (L10n.tr("storage.part.richText"), .purple, records.map(\.richTextBytes).reduce(0, +)),
            (L10n.tr("type.text"), .gray, records.map(\.textBytes).reduce(0, +)),
        ]
    }

    private var locationRow: some View {
        let directory = StorageScanner.Locations.dataDirectory
        return HStack {
            Text(L10n.tr("detail.location"))
            Spacer()
            Text((directory.path as NSString).abbreviatingWithTildeInPath)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(L10n.tr("detail.openInFinder")) { NSWorkspace.shared.open(directory) }
                .buttonStyle(.link)
                .pointerCursor()
        }
    }

    private var optimizeSection: some View {
        Section(L10n.tr("storage.optimize")) {
            Toggle(isOn: $optimizeTIFF) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("storage.tiff.title"))
                    ForEach(tiffDetail, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .onChange(of: optimizeTIFF) { _, isOn in
                if isOn { Task { await storage.convertTIFFs() } }
            }
        }
    }

    /// Progress while a batch runs; afterwards what it did; with the switch off, what's waiting.
    private var tiffDetail: [String] {
        if let progress = optimizer.progress {
            return [L10n.tr("storage.tiff.progress", progress.done.formatted(), progress.total.formatted())]
        }
        var lines: [String] = []
        if let outcome = optimizer.lastOutcome {
            if outcome.converted > 0 {
                lines.append(L10n.tr("storage.tiff.result", outcome.converted.formatted(), StorageFormat.bytes(outcome.savedBytes)))
            }
            if outcome.kept > 0 {
                lines.append(L10n.tr("storage.tiff.kept", outcome.kept.formatted()))
            }
        }
        let pending = storage.convertibleTIFFs
        if lines.isEmpty, !optimizeTIFF, !pending.isEmpty {
            lines.append(L10n.tr("storage.tiff.detail", pending.count.formatted(),
                                 StorageFormat.bytes(pending.map(\.bytes).reduce(0, +))))
        }
        return lines
    }
}

/// Proportional stacked bar; every non-empty part keeps a sliver so it stays visible.
struct StorageUsageBar: View {
    let parts: [(Color, Int64)]

    var body: some View {
        GeometryReader { proxy in
            let visible = parts.filter { $0.1 > 0 }
            let total = CGFloat(max(1, visible.map(\.1).reduce(0, +)))
            let spacing: CGFloat = 1.5
            let available = max(0, proxy.size.width - spacing * CGFloat(max(0, visible.count - 1)))
            HStack(spacing: spacing) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, part in
                    Rectangle()
                        .fill(part.0)
                        .frame(width: max(2, available * CGFloat(part.1) / total))
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
    }
}

// MARK: - Manage（数据 → 管理）

struct StorageManagePane: View {
    @EnvironmentObject private var nav: SettingsNavigationModel
    @EnvironmentObject private var storage: StorageModel
    @Environment(\.modelContext) private var modelContext
    @State private var clicks = StorageClickSelection<StorageGroupKey>()

    private var bySource: Bool { storage.grouping == .source }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $storage.grouping) {
                    Text(L10n.tr("storage.grouping.source")).tag(StorageGrouping.source)
                    Text(L10n.tr("storage.byType")).tag(StorageGrouping.type)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(L10n.tr(bySource ? "storage.sourceCount" : "storage.typeCount", storage.rows.count.formatted()))
                    .foregroundStyle(.secondary)
                Spacer()
                if bySource {
                    TextField(L10n.tr("storage.searchSources"), text: $storage.sourceSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }
                StorageTimeMenu()
                // Listing by type, a type filter would only hide rows.
                if bySource { StorageTypeMenu() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            header
            Divider()
            if storage.snapshot == nil {
                StorageLoadingView()
            } else if storage.rows.isEmpty {
                StorageEmptyView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(storage.rows) { row in
                            groupRow(row)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task { if storage.snapshot == nil { await storage.refresh() } }
    }

    private var allVisibleSelected: Bool {
        !storage.rows.isEmpty && storage.rows.allSatisfy { storage.selectedGroups.contains($0.key) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StorageCheckmark(isOn: allVisibleSelected) {
                if allVisibleSelected {
                    storage.selectedGroups.subtract(storage.rows.map(\.key))
                } else {
                    storage.selectedGroups.formUnion(storage.rows.map(\.key))
                }
            }
            .disabled(storage.rows.isEmpty)
            sortHeader(L10n.tr(bySource ? "storage.column.source" : "storage.column.type"), sort: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader(L10n.tr("storage.column.latest"), sort: .latest)
                .frame(width: 104, alignment: .leading)
            sortHeader(L10n.tr("storage.column.count"), sort: .count)
                .frame(width: 64, alignment: .trailing)
            sortHeader(L10n.tr("storage.column.size"), sort: .bytes)
                .frame(width: 84, alignment: .trailing)
            Color.clear.frame(width: 10, height: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func sortHeader(_ title: String, sort: StorageGroupSort) -> some View {
        Button {
            storage.groupSort = sort
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if storage.groupSort == sort {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(storage.groupSort == sort ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func groupRow(_ row: StorageGroupSummary) -> some View {
        HStack(spacing: 10) {
            StorageCheckmark(isOn: storage.selectedGroups.contains(row.key)) { select(row.key) }
            HStack(spacing: 8) {
                StorageGroupIcon(key: row.key)
                Text(storage.displayName(for: row.key)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.latest.formatted(date: .numeric, time: .omitted))
                .frame(width: 104, alignment: .leading)
            Text(row.count.formatted())
                .frame(width: 64, alignment: .trailing)
            Text(StorageFormat.bytes(row.bytes))
                .frame(width: 84, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
        }
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(storage.selectedGroups.contains(row.key) ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            // With ⌘ / ⇧ the row click selects, like the checkbox; a plain click opens it.
            if NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty {
                nav.push(.storageGroup(row.key))
            } else {
                select(row.key)
            }
        }
        .pointerCursor()
    }

    private func select(_ key: StorageGroupKey) {
        var selection = storage.selectedGroups
        clicks.click(key, extendingRange: NSEvent.modifierFlags.contains(.shift),
                     order: storage.rows.map(\.key), selection: &selection)
        storage.selectedGroups = selection
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            StorageDeleteNote()
            HStack {
                let selected = storage.visibleSelection
                if !selected.isEmpty {
                    Text(L10n.tr(
                        bySource ? "storage.selectionSummary" : "storage.typeSelectionSummary",
                        selected.count.formatted(),
                        selected.map(\.count).reduce(0, +).formatted(),
                        StorageFormat.bytes(selected.map(\.bytes).reduce(0, +))
                    ))
                }
                Spacer()
                StorageDeleteButton(disabled: selected.isEmpty || storage.isBusy) {
                    let ids = storage.selectedItemIDs
                    guard StorageDeleteConfirmation.confirm(count: ids.count) else { return }
                    Task {
                        await storage.delete(itemIDs: ids, in: modelContext)
                        storage.selectedGroups.removeAll()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Group（管理 → 某个来源 / 某种类型）

struct StorageGroupPane: View {
    let key: StorageGroupKey

    @EnvironmentObject private var storage: StorageModel
    @Environment(\.modelContext) private var modelContext
    /// Narrows one source's clips to a type; a type page is one type already.
    @State private var category: StorageCategory?
    /// Narrows one type's clips to a source ("" = no recorded source); a source page is one
    /// source already.
    @State private var source: String?
    @State private var sort: ItemSort = .size
    @State private var selection: Set<String> = []
    @State private var clicks = StorageClickSelection<String>()
    /// Clips for list rows, fetched as rows appear — the grid never needs them.
    @State private var items: [String: ClipItem] = [:]
    /// Filtered, sorted records and the menus' contents. Thousands of records: worked out once
    /// per change, not on every redraw (each tick of a checkbox redraws the page).
    @State private var derived = Derived()

    enum ItemSort: Hashable { case size, latest }

    struct Inputs: Hashable {
        var revision: Int
        var category: StorageCategory?
        var source: String?
        var sort: ItemSort
    }

    struct Derived {
        var inputs: Inputs?
        var records: [StorageRecord] = []
        var categories: [StorageCategory] = []
        var sources: [(key: String, count: Int)] = []
    }

    private var inputs: Inputs {
        Inputs(revision: storage.revision, category: category, source: source, sort: sort)
    }

    private var shownCategory: StorageCategory? {
        if case .category(let fixed) = key { return fixed }
        return category
    }

    /// The cached list minus whatever a delete is removing right now — filtered here, at draw
    /// time, because the cache only catches up once its task runs.
    private var records: [StorageRecord] {
        let deleting = storage.deletingIDs
        return deleting.isEmpty ? derived.records : derived.records.filter { !deleting.contains($0.id) }
    }

    /// A clip that's still alive. After a delete is saved `isDeleted` reads false again, so the
    /// context check is the one that holds.
    private func liveItem(_ id: String) -> ClipItem? {
        guard !storage.deletingIDs.contains(id), let item = items[id], !item.isGone else { return nil }
        return item
    }
    private var selectedRecords: [StorageRecord] { records.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if case .source = key {
                    Picker("", selection: $category) {
                        Text(L10n.tr("filter.all")).tag(StorageCategory?.none)
                        ForEach(derived.categories, id: \.self) { category in
                            Text(category.label).tag(StorageCategory?.some(category))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                } else {
                    StorageSourcePicker(sources: derived.sources, selection: $source)
                    Text(L10n.tr("storage.itemCount", records.count.formatted()))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StorageTimeMenu()
                NativePullDownButton(title: sort == .size ? L10n.tr("storage.sort.size") : L10n.tr("storage.sort.latest")) {
                    [
                        .item(L10n.tr("storage.sort.size"), checked: sort == .size) { sort = .size },
                        .item(L10n.tr("storage.sort.latest"), checked: sort == .latest) { sort = .latest },
                    ]
                }
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            content
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: inputs) { derive(inputs) }
    }

    private func derive(_ inputs: Inputs) {
        let groupRecords = storage.records(in: key)
        var result = Derived(inputs: inputs)
        result.categories = StorageCategory.allCases.filter(Set(groupRecords.map(\.category)).contains)
        var counts: [String: Int] = [:]
        for record in groupRecords { counts[record.sourceName ?? "", default: 0] += 1 }
        result.sources = counts.map { ($0.key, $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }

        // A picked type / source that emptied out (deleted, outside the time filter): back to all.
        if let category, !result.categories.contains(category) { self.category = nil; return }
        if let source, counts[source] == nil { self.source = nil; return }

        var filtered = groupRecords
        if let shown = shownCategory { filtered = filtered.filter { $0.category == shown } }
        if case .category = key, let source { filtered = filtered.filter { ($0.sourceName ?? "") == source } }
        switch inputs.sort {
        case .size: filtered.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.createdAt > $1.createdAt }
        case .latest: filtered.sort { $0.createdAt > $1.createdAt }
        }
        result.records = filtered
        derived = result
        selection.formIntersection(filtered.map(\.id))
    }

    @ViewBuilder
    private var content: some View {
        if storage.snapshot == nil || derived.inputs == nil {
            StorageLoadingView()
        } else if records.isEmpty {
            StorageEmptyView()
        } else if shownCategory == .image {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)], spacing: 8) {
                    ForEach(records) { record in
                        StorageThumbnailCell(record: record, isSelected: selection.contains(record.id)) {
                            toggle(record.id)
                        }
                    }
                }
                .padding(16)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(records) { record in
                        itemRow(record)
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }

    private func itemRow(_ record: StorageRecord) -> some View {
        HStack(spacing: 10) {
            StorageCheckmark(isOn: selection.contains(record.id)) { toggle(record.id) }
            Group {
                if record.category == .image {
                    // ClipRow would fault the image bytes on the main thread (full-size for
                    // older clips); this row takes its thumbnail from the background loader.
                    StorageImageListRow(record: record, title: liveItem(record.id)?.displayTitle)
                } else if let item = liveItem(record.id) {
                    ClipRow(item: item, isSelected: false)
                } else {
                    Text(record.createdAt.formatted()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(StorageFormat.bytes(record.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(selection.contains(record.id) ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { toggle(record.id) }
        .task(id: record.id) { loadItem(record.id) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            StorageDeleteNote()
            itemActions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var itemActions: some View {
        HStack {
            let selected = selectedRecords
            if !selected.isEmpty {
                Text(L10n.tr("storage.itemSelectionSummary", selected.count.formatted(),
                             StorageFormat.bytes(selected.map(\.bytes).reduce(0, +))))
            }
            Spacer()
            let allSelected = !records.isEmpty && selected.count == records.count
            Button(allSelected ? L10n.tr("storage.deselectAll") : L10n.tr("storage.selectAll")) {
                if allSelected {
                    selection.subtract(records.map(\.id))
                } else {
                    selection.formUnion(records.map(\.id))
                }
            }
            .disabled(records.isEmpty)
            .pointerCursor()
            StorageDeleteButton(disabled: selected.isEmpty || storage.isBusy) {
                let ids = selected.map(\.id)
                guard StorageDeleteConfirmation.confirm(count: ids.count) else { return }
                // Drop the rows' clips before the delete runs (see StorageModel.deletingIDs).
                for id in ids { items[id] = nil }
                selection.subtract(ids)
                Task { await storage.delete(itemIDs: ids, in: modelContext) }
            }
        }
    }

    private func toggle(_ id: String) {
        clicks.click(id, extendingRange: NSEvent.modifierFlags.contains(.shift),
                     order: records.map(\.id), selection: &selection)
    }

    /// One indexed lookup per visible row instead of materialising every clip of the group.
    private func loadItem(_ id: String) {
        guard items[id] == nil, !storage.deletingIDs.contains(id) else { return }
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.itemID == id })
        descriptor.fetchLimit = 1
        if let item = try? modelContext.fetch(descriptor).first {
            items[id] = item
        }
    }
}

struct StorageThumbnailCell: View {
    let record: StorageRecord
    let isSelected: Bool
    let toggle: () -> Void

    @State private var image: NSImage?
    /// Pixels for the long edge: a 140-pt cell on Retina.
    private static let THUMB_PIXELS = 280

    var body: some View {
        Color.secondary.opacity(0.1)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if record.isSensitive {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                } else if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                StorageCheckmark(isOn: isSelected, action: toggle)
                    .background(Circle().fill(.background.opacity(isSelected ? 0 : 0.8)).padding(1))
                    .padding(5)
            }
            .overlay(alignment: .bottomLeading) {
                Text(StorageFormat.bytes(record.bytes))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.5)))
                    .padding(5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .task(id: record.id) {
                guard !record.isSensitive,
                      let cgImage = await StorageThumbnailLoader.shared.thumbnail(
                        itemID: record.id, version: record.previewBytes, maxPixel: Self.THUMB_PIXELS
                      ) else { return }
                image = NSImage(cgImage: cgImage, size: .zero)
            }
    }
}

/// An image clip in a list: thumbnail from `StorageThumbnailLoader`, title, when it was copied.
struct StorageImageListRow: View {
    let record: StorageRecord
    let title: String?
    @State private var image: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Color.secondary.opacity(0.1)
                .frame(width: 36, height: 36)
                .overlay {
                    if record.isSensitive {
                        Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? L10n.tr("type.image")).lineLimit(1)
                Text(record.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .task(id: record.id) {
            guard !record.isSensitive,
                  let cgImage = await StorageThumbnailLoader.shared.thumbnail(itemID: record.id, version: record.previewBytes, maxPixel: 72)
            else { return }
            image = NSImage(cgImage: cgImage, size: .zero)
        }
    }
}

/// The type page's source filter: a popover list with app icons. NSMenu item images don't
/// render on this macOS, and 70-odd sources want a search field anyway.
struct StorageSourcePicker: View {
    let sources: [(key: String, count: Int)]
    @Binding var selection: String?

    @EnvironmentObject private var storage: StorageModel
    @State private var isPresented = false
    @State private var query = ""
    @State private var hovered: String??

    var body: some View {
        Button {
            query = ""
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                if let selection {
                    StorageGroupIcon(key: .source(selection)).scaleEffect(0.8).frame(width: 16, height: 16)
                }
                Text(selection.map { storage.displayName(for: .source($0)) } ?? L10n.tr("storage.allSources"))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { list }
    }

    private var filtered: [(key: String, count: Int)] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return sources }
        return sources.filter { storage.displayName(for: .source($0.key)).localizedCaseInsensitiveContains(text) }
    }

    private var list: some View {
        VStack(spacing: 0) {
            TextField(L10n.tr("storage.searchSources"), text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if query.isEmpty {
                        row(nil, name: L10n.tr("storage.allSources"), count: sources.map(\.count).reduce(0, +))
                        Divider().padding(.vertical, 3)
                    }
                    ForEach(filtered, id: \.key) { entry in
                        row(entry.key, name: storage.displayName(for: .source(entry.key)), count: entry.count)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: min(420, CGFloat(filtered.count + 2) * 28 + 12))
        }
        .frame(width: 280)
    }

    private func row(_ key: String?, name: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .opacity(selection == key ? 1 : 0)
                .frame(width: 12)
            if let key {
                StorageGroupIcon(key: .source(key)).scaleEffect(0.85).frame(width: 18, height: 18)
            } else {
                Color.clear.frame(width: 18, height: 18)
            }
            Text(name).lineLimit(1)
            Spacer(minLength: 8)
            Text(count.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovered == .some(key) ? Color.accentColor.opacity(0.15) : Color.clear))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? .some(key) : (hovered == .some(key) ? nil : hovered) }
        .onTapGesture {
            selection = key
            isPresented = false
        }
    }
}

// MARK: - Shared pieces

struct StorageCheckmark: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// A source's app icon, or a type's symbol on a tile.
struct StorageGroupIcon: View {
    let key: StorageGroupKey
    @EnvironmentObject private var storage: StorageModel

    var body: some View {
        switch key {
        case .source(let name):
            StorageSourceIcon(image: storage.icon(forSource: name.isEmpty ? nil : name))
        case .category(let category):
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 20, height: 20)
                .overlay(Image(systemName: category.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary))
        }
    }
}

struct StorageSourceIcon: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().renderingMode(.original)
            } else {
                Image(systemName: "questionmark.app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }
}

struct StorageDeleteButton: View {
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(L10n.tr("storage.deleteRecords"), role: .destructive, action: action)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(disabled)
            .pointerCursor()
    }
}

@MainActor
enum StorageDeleteConfirmation {
    static func confirm(count: Int) -> Bool {
        guard count > 0 else { return false }
        let alert = NSAlert()
        alert.messageText = L10n.tr("storage.delete.confirm", count.formatted())
        alert.informativeText = L10n.tr("storage.delete.scope")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("action.delete"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// What a delete here touches, under both lists: PasteMemo's records, never the user's files.
struct StorageDeleteNote: View {
    var body: some View {
        Text(L10n.tr("storage.protectedNote"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct StorageLoadingView: View {
    var body: some View {
        VStack { ProgressView().controlSize(.small) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StorageEmptyView: View {
    @EnvironmentObject private var storage: StorageModel

    /// While a delete runs its rows are already gone (see `StorageModel.deletingIDs`); saying
    /// "nothing to clean up" under the progress sheet would be wrong until it finishes.
    var body: some View {
        Text(L10n.tr(storage.isBusy ? "storage.deleting" : "storage.empty"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "全部时间 / N 个月前 / 自定义时间…", shared by the manage and source pages.
struct StorageTimeMenu: View {
    @EnvironmentObject private var storage: StorageModel
    @State private var showCustomRange = false

    var body: some View {
        NativePullDownButton(title: title) {
            var items: [NativeMenuItem] = [
                .item(L10n.tr("storage.time.all"), checked: storage.filter.time == .all) { storage.filter.time = .all },
                .separator,
            ]
            for months in StorageTimeFilter.presetMonths {
                items.append(.item(Self.label(months: months), checked: storage.filter.time == .olderThan(months: months)) {
                    storage.filter.time = .olderThan(months: months)
                })
            }
            items.append(.separator)
            items.append(.item(L10n.tr("storage.time.custom"), checked: isRange) { showCustomRange = true })
            return items
        }
        .fixedSize()
        .sheet(isPresented: $showCustomRange) {
            StorageCustomRangeSheet(initial: storage.filter.time) { storage.filter.time = $0 }
        }
    }

    private var isRange: Bool {
        if case .range = storage.filter.time { return true }
        return false
    }

    private var title: String {
        switch storage.filter.time {
        case .all:
            return L10n.tr("storage.time.all")
        case .olderThan(let months):
            return Self.label(months: months)
        case .range(let from, let to):
            let format = Date.FormatStyle(date: .numeric, time: .omitted)
            return "\(min(from, to).formatted(format)) – \(max(from, to).formatted(format))"
        }
    }

    /// One key per preset (`StorageTimeFilter.presetMonths`): plural rules differ per language.
    private static func label(months: Int) -> String {
        switch months {
        case 1: return L10n.tr("storage.time.1month")
        case 3: return L10n.tr("storage.time.3months")
        case 6: return L10n.tr("storage.time.6months")
        default: return L10n.tr("storage.time.1year")
        }
    }
}

/// Multi-select type filter: each pick toggles one type; "全部类型" clears them.
struct StorageTypeMenu: View {
    @EnvironmentObject private var storage: StorageModel

    var body: some View {
        NativePullDownButton(title: title) {
            var items: [NativeMenuItem] = StorageCategory.allCases.map { category in
                .item(category.label, checked: storage.filter.categories.contains(category)) {
                    if storage.filter.categories.contains(category) {
                        storage.filter.categories.remove(category)
                    } else {
                        storage.filter.categories.insert(category)
                    }
                }
            }
            items.append(.separator)
            items.append(.item(L10n.tr("storage.type.all"), checked: storage.filter.categories.isEmpty) {
                storage.filter.categories.removeAll()
            })
            return items
        }
        .fixedSize()
    }

    private var title: String {
        let picked = StorageCategory.allCases.filter(storage.filter.categories.contains)
        guard !picked.isEmpty else { return L10n.tr("storage.type.all") }
        return picked.map(\.label).joined(separator: L10n.tr("storage.listSeparator"))
    }
}

struct StorageCustomRangeSheet: View {
    let onApply: (StorageTimeFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var from: Date
    @State private var to: Date

    init(initial: StorageTimeFilter, onApply: @escaping (StorageTimeFilter) -> Void) {
        self.onApply = onApply
        let now = Date()
        if case .range(let from, let to) = initial {
            _from = State(initialValue: from)
            _to = State(initialValue: to)
        } else {
            _from = State(initialValue: Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now)
            _to = State(initialValue: now)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("storage.custom.title")).font(.headline)
            Form {
                DatePicker(L10n.tr("storage.custom.from"), selection: $from, displayedComponents: .date)
                DatePicker(L10n.tr("storage.custom.to"), selection: $to, displayedComponents: .date)
            }
            HStack {
                Spacer()
                Button(L10n.tr("action.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("action.confirm")) {
                    onApply(.range(from: from, to: to))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// Progress for deletes and conversions; can't be dismissed while the job runs.
struct StorageJobSheet: View {
    let job: StorageModel.Job

    var body: some View {
        VStack(spacing: 14) {
            Text(job.title).font(.headline)
            if job.total > 0, job.done > 0 {
                ProgressView(value: Double(job.done), total: Double(job.total)).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text("\(job.done.formatted()) / \(job.total.formatted())")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 300)
        .interactiveDismissDisabled()
    }
}
