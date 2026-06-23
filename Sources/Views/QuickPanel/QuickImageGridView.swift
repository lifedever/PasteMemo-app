import SwiftUI
import SwiftData
import AppKit

/// 图片瀑布流（快捷面板「图片」筛选下的可选展示）。
///
/// 列表（`NativeClipHistoryList`）是单列 NSTableView，做不了多列变高布局，所以图片网格
/// 是独立的一条 SwiftUI 视图路径：选中状态、粘贴/复制/删除全部复用 `QuickPanelView`
/// 的 `selectedItemIDs` / `lastNavigatedID`，本视图只负责「渲染 + 上报点击」。
/// 键盘四向导航在父视图 `moveGrid` 里用同一套 `MasonryLayout` 计算，二者列分配一致。

// MARK: - 比例缓存（仅主线程；读图片头部，开销小，memoize）

@MainActor
enum ImageAspectCache {
    /// 原始像素尺寸（取自存储的缩略图字节，比例与原图一致）。
    private static var sizes: [PersistentIdentifier: NSSize] = [:]

    static func pixelSize(for item: ClipItem) -> NSSize? {
        if let s = sizes[item.persistentModelID] { return s.width > 0 ? s : nil }
        var size = NSSize.zero
        if let data = item.imageData, let dim = ImageCache.shared.imageDimensions(for: data) {
            size = dim
        }
        sizes[item.persistentModelID] = size
        return size.width > 0 ? size : nil
    }

    /// 宽高比 width/height，做了夹紧避免极端长/宽图把单元格撑得没法看。
    static func aspect(for item: ClipItem) -> CGFloat {
        guard let s = pixelSize(for: item), s.height > 0 else { return 1 }
        return min(max(s.width / s.height, 0.42), 2.4)
    }
}

// MARK: - 瀑布流布局（纯逻辑：最短列打包 + 四向最近格导航）

struct MasonryLayout {
    enum Direction { case up, down, left, right }

    /// 每列的条目（竖直顺序）。渲染时直接按这个铺。
    let columns: [[ClipItem]]
    /// id -> (列, 列内行号, 竖直中心 y)。导航用。
    private let positions: [PersistentIdentifier: (col: Int, row: Int, yCenter: CGFloat)]

    // 用到 @MainActor 的 ImageAspectCache，调用方（网格 body / moveGrid）都在主线程。
    @MainActor
    init(items: [ClipItem], columnCount: Int, columnWidth: CGFloat, spacing: CGFloat) {
        let n = max(1, columnCount)
        var cols = Array(repeating: [ClipItem](), count: n)
        var heights = Array(repeating: CGFloat(0), count: n)
        var pos: [PersistentIdentifier: (Int, Int, CGFloat)] = [:]

        for item in items {
            // 放进当前最矮的一列（贪心，标准瀑布流打包）。
            var c = 0
            for i in 1..<n where heights[i] < heights[c] - 0.5 { c = i }
            let h = columnWidth / ImageAspectCache.aspect(for: item)
            pos[item.persistentModelID] = (c, cols[c].count, heights[c] + h / 2)
            cols[c].append(item)
            heights[c] += h + spacing
        }
        columns = cols
        positions = pos.mapValues { (col: $0.0, row: $0.1, yCenter: $0.2) }
    }

    func neighbor(of id: PersistentIdentifier, _ dir: Direction) -> PersistentIdentifier? {
        guard let p = positions[id] else { return nil }
        switch dir {
        case .up:
            return p.row > 0 ? columns[p.col][p.row - 1].persistentModelID : nil
        case .down:
            return p.row + 1 < columns[p.col].count ? columns[p.col][p.row + 1].persistentModelID : nil
        case .left, .right:
            let target = dir == .left ? p.col - 1 : p.col + 1
            guard target >= 0, target < columns.count, !columns[target].isEmpty else { return nil }
            // 相邻列里竖直中心最接近的那个。
            var best: PersistentIdentifier?
            var bestDist = CGFloat.infinity
            for it in columns[target] {
                let yc = positions[it.persistentModelID]?.yCenter ?? 0
                let d = abs(yc - p.yCenter)
                if d < bestDist { bestDist = d; best = it.persistentModelID }
            }
            return best
        }
    }
}

// MARK: - 网格视图

struct QuickImageGridView<Menu: View, Palette: View>: View {
    let items: [ClipItem]
    /// 列数与列宽都由父视图按面板宽度 + 密度算好传入。渲染和键盘导航（moveGrid）
    /// 必须用同一对 (columnCount, columnWidth) 建布局——否则最短列打包里那个常量
    /// spacing 会让不同列宽算出不同的列分配，导致光标和屏幕对不上（尤其左右键）。
    let columnCount: Int
    let columnWidth: CGFloat
    let selectedItemIDs: Set<PersistentIdentifier>
    let focusedItemID: PersistentIdentifier?
    /// Cmd+K 命令面板是否展开——弹在焦点格上（与列表把面板挂在选中行上一致）。
    let showCommandPalette: Bool
    /// 点击某项（单击/⌘单击/⇧单击/双击 都走这里，由 `handleItemClick` 读
    /// `NSApp.currentEvent` 的修饰键判定，双击粘贴也在其中，与列表完全一致）。
    let onTap: (PersistentIdentifier) -> Void
    let onCommandPaletteDismiss: () -> Void
    /// 滚动接近底部时分页加载（与列表一致；否则图片多时只看得到第一页）。
    let onLoadMore: () -> Void
    @ViewBuilder let contextMenu: (ClipItem) -> Menu
    @ViewBuilder let commandPalette: (ClipItem) -> Palette

    /// 末尾若干项的 id；它们出现时触发分页加载。
    private var trailingIDs: Set<PersistentIdentifier> {
        Set(items.suffix(8).map(\.persistentModelID))
    }

    static var spacing: CGFloat { 13 }
    static var hPad: CGFloat { 16 }

    var body: some View {
        let n = max(1, columnCount)
        let colW = max(1, columnWidth)
        // 用传入的 (n, colW) 建布局；与 moveGrid 完全一致，保证导航跟屏幕对得上。
        let layout = MasonryLayout(items: items, columnCount: n, columnWidth: colW, spacing: Self.spacing)

        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(Array(layout.columns.indices), id: \.self) { ci in
                        LazyVStack(spacing: Self.spacing) {
                            ForEach(layout.columns[ci], id: \.persistentModelID) { item in
                                ImageGridCell(
                                    item: item,
                                    width: colW,
                                    isFocused: item.persistentModelID == focusedItemID,
                                    isSelected: selectedItemIDs.contains(item.persistentModelID),
                                    isPaletteTarget: showCommandPalette
                                        && item.persistentModelID == focusedItemID,
                                    onTap: onTap,
                                    onCommandPaletteDismiss: onCommandPaletteDismiss,
                                    contextMenu: contextMenu,
                                    commandPalette: commandPalette
                                )
                                .id(item.persistentModelID)
                                .onAppear {
                                    if trailingIDs.contains(item.persistentModelID) {
                                        onLoadMore()
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Self.hPad)
                .padding(.vertical, 14)
            }
            .onChange(of: focusedItemID) { _, id in
                guard let id else { return }
                // 不用 anchor: .center —— 那会让「点击已可见的图」也被强制滚到正中，
                // 视觉上卡一下、像延迟选中。无 anchor 只在目标不在可视区时最小滚动
                // （点已可见的图不滚；键盘移出视野才滚进来），与列表 .nearest 一致。
                proxy.scrollTo(id)
            }
        }
    }

}

// MARK: - 单元格（hover 局部化，避免鼠标划过时整张网格重算/重渲染，省 CPU）

private struct ImageGridCell<Menu: View, Palette: View>: View {
    let item: ClipItem
    let width: CGFloat
    let isFocused: Bool
    let isSelected: Bool
    /// 命令面板是否要弹在这一格（= showCommandPalette && 它是焦点格）。
    let isPaletteTarget: Bool
    let onTap: (PersistentIdentifier) -> Void
    let onCommandPaletteDismiss: () -> Void
    let contextMenu: (ClipItem) -> Menu
    let commandPalette: (ClipItem) -> Palette

    @State private var isHovered = false

    var body: some View {
        let aspect = ImageAspectCache.aspect(for: item)
        let height = width / aspect
        let showName = isHovered || isFocused

        AsyncPreviewImageView(
            data: item.imageData,
            cacheKey: item.itemID,
            maxPixelSize: max(width * 2, 320),
            cornerRadius: 0,
            thumbnailSize: max(width, 160)
        )
        .frame(width: width, height: height)
        .clipped()
        // 图片自身不接收点击：否则 AsyncPreviewImageView 内部的 count:2 手势会吞掉第二次
        // 点击，外层 handleItemClick 的「双击=粘贴」就触发不了。让点击全部落到外层单一手势。
        .allowsHitTesting(false)
        .overlay(alignment: .bottom) {
            if showName { nameOverlay.allowsHitTesting(false) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            // 焦点 = 粗高亮边框；多选项 = 细高亮边框（不再叠对勾角标）。
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isFocused || isSelected ? Color.accentColor : Color.black.opacity(0.06),
                    lineWidth: isFocused ? 3 : (isSelected ? 2 : 0.5)
                )
        )
        .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovered = $0 }
        .onTapGesture { onTap(item.persistentModelID) }
        .popover(
            isPresented: Binding(
                get: { isPaletteTarget },
                set: { if !$0 { onCommandPaletteDismiss() } }
            ),
            arrowEdge: .trailing
        ) {
            commandPalette(item)
        }
        .contextMenu { contextMenu(item) }
    }

    private var nameOverlay: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let title = item.displayTitle, !title.isEmpty {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            if let meta = metaLine {
                Text(meta)
                    .font(.system(size: 10))
                    .opacity(0.85)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.top, 16)
        .padding(.bottom, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.95), .black.opacity(0.6), .clear],
                startPoint: .bottom, endPoint: .top
            )
        )
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var metaLine: String? {
        var parts: [String] = []
        if let s = ImageAspectCache.pixelSize(for: item) {
            parts.append("\(Int(s.width))×\(Int(s.height))")
        }
        if let app = item.sourceApp, !app.isEmpty {
            parts.append(app)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
