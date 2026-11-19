import SwiftUI
import SwiftData
import AppKit

/// 贴边条的横向卡片列表：按时间分组，组之间用竖排标签隔开。
///
/// 和图片瀑布流同一个分工：这里只负责渲染、上报点击和位置；选中、粘贴、多选这些
/// 行为都在 QuickPanelView，状态从那边传进来。
struct ShelfStripView: View {
    let groups: [GroupedItem<ClipItem>]
    let focusedID: PersistentIdentifier?
    let selectedIDs: Set<PersistentIdentifier>
    /// 勾选顺序；非空时卡片角上标 ①②③
    let pickOrder: [PersistentIdentifier]
    /// 按住 ⌘ 时，卡片底栏显示 ⌘1–9
    let showsShortcutNumbers: Bool
    let shortcutIndex: (ClipItem) -> Int?
    let onTap: (PersistentIdentifier) -> Void
    let onLoadMore: () -> Void
    let contextMenu: (ClipItem) -> [NativeMenuItem]
    /// 能不能把卡片拖出去：编辑 / 拆分页面或 `/` 建议浮层盖在卡片区上时关掉，
    /// 不然在编辑框里拖动选字会被当成拖卡片
    let dragEnabled: Bool
    /// 从这张卡片拖出去时带哪些条目：勾选过的卡片带上全部勾选（按勾选顺序），否则只带这一张
    let itemsForDrag: (PersistentIdentifier) -> [ClipItem]
    /// 拖到别的 App 并被接收以后
    let onDragDelivered: ([ClipItem]) -> Void
    /// 焦点卡片和整条列表在**窗口坐标系**（AppKit，原点左下）里的位置，给 ⌘K 菜单和预览浮窗定位。
    /// 不报屏幕坐标：贴边条从屏幕外滑进来，第一次布局时窗口还在起点，那时换算的屏幕坐标
    /// 等窗口滑到位就过期了，而卡片在窗口里的位置没变、不会再上报。由浮窗显示时按窗口当前位置换算。
    let onFocusedCardFrame: (_ card: CGRect, _ strip: CGRect) -> Void

    /// 卡片位置存在引用类型里：每张卡片滚动时都会更新位置，放进 @State 会让整条列表反复重绘
    @State private var frames = CardFrameStore()

    private var itemIDs: [PersistentIdentifier] {
        groups.flatMap(\.items).map(\.persistentModelID)
    }

    private var trailingIDs: Set<PersistentIdentifier> {
        Set(groups.flatMap(\.items).suffix(6).map(\.persistentModelID))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: ShelfCardMetrics.spacing) {
                    ForEach(groups, id: \.group) { group in
                        ShelfGroupLabel(text: group.group.label)
                        ForEach(group.items, id: \.persistentModelID) { item in
                            card(item)
                        }
                    }
                }
                .padding(.horizontal, 14)
                // 顶上留一点：焦点卡片的描边和投影不被裁掉
                .padding(.top, 8)
                .padding(.bottom, 10)
                .background(VerticalWheelToHorizontal())
                .background(
                    ShelfDragSource(
                        isEnabled: dragEnabled,
                        frames: frames,
                        itemsForDrag: itemsForDrag,
                        onDelivered: onDragDelivered
                    )
                )
            }
            .onChange(of: itemIDs) { _, ids in
                // 切分类、搜索后旧卡片的位置记录还在，按下时可能匹配到一张已经不显示的卡片
                let current = Set(ids)
                frames.cards = frames.cards.filter { current.contains($0.key) }
            }
            .onChange(of: focusedID) { _, id in
                guard let id else { return }
                // 不给 anchor：已经看得到的卡片不滚，看不到时才最小滚动进来
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                reportFocusedFrame()
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            frames.strip = frame
            reportFocusedFrame()
        }
    }

    private func card(_ item: ClipItem) -> some View {
        let id = item.persistentModelID
        let order = pickOrder.firstIndex(of: id).map { $0 + 1 }
        return ShelfCardView(
            item: item,
            isFocused: id == focusedID,
            isPicked: selectedIDs.contains(id) && !pickOrder.isEmpty,
            pickOrder: order,
            shortcutNumber: showsShortcutNumbers ? shortcutIndex(item) : nil
        )
        .id(id)
        .onTapGesture { onTap(id) }
        .nativeContextMenuMonitor { contextMenu(item) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            frames.cards[id] = frame
            if id == focusedID { reportFocusedFrame() }
        }
        .onAppear {
            if trailingIDs.contains(id) { onLoadMore() }
        }
    }

    private func reportFocusedFrame() {
        guard let focusedID, let card = frames.cards[focusedID],
              let cardInWindow = Self.windowRect(fromGlobal: card),
              let stripInWindow = Self.windowRect(fromGlobal: frames.strip) else { return }
        onFocusedCardFrame(cardInWindow, stripInWindow)
    }

    /// SwiftUI 的 .global 是窗口内坐标（原点左上、y 向下），翻成 AppKit 窗口坐标（原点左下）
    @MainActor
    private static func windowRect(fromGlobal rect: CGRect) -> CGRect? {
        guard let content = QuickPanelWindowController.shared.panelWindow?.contentView else { return nil }
        return CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}

final class CardFrameStore {
    /// 卡片和整条列表的位置，SwiftUI `.global` 坐标（窗口内，原点左上）
    var cards: [PersistentIdentifier: CGRect] = [:]
    var strip: CGRect = .zero
}

/// 组之间的分隔：竖排标签 + 一条细线。中日韩文字逐字竖排，其他语言整体转 90°。
private struct ShelfGroupLabel: View {
    let text: String

    private var isCJK: Bool {
        text.unicodeScalars.allSatisfy { scalar in
            (0x3040...0x30FF).contains(scalar.value)      // 日文假名
                || (0x4E00...0x9FFF).contains(scalar.value)  // 中日韩汉字
                || (0xAC00...0xD7AF).contains(scalar.value)  // 韩文
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            if isCJK {
                VStack(spacing: 1) {
                    ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                        Text(String(character))
                    }
                }
            } else {
                Text(text)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 14, height: 70)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 0.5)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .frame(width: 14, height: ShelfCardMetrics.height)
        .padding(.top, 4)
    }
}

/// 鼠标滚轮只有竖向，横向列表翻不动：把竖向滚动量换成横向。触控板竖着扫也一并换。
private struct VerticalWheelToHorizontal: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelBridgeView { WheelBridgeView() }
    func updateNSView(_ nsView: WheelBridgeView, context: Context) {}
    static func dismantleNSView(_ nsView: WheelBridgeView, coordinator: ()) { nsView.removeMonitor() }
}

private final class WheelBridgeView: NSView {
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.redirect(event)
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private var scrollView: NSScrollView? {
        var current = superview
        while let view = current {
            if let scrollView = view as? NSScrollView { return scrollView }
            current = view.superview
        }
        return nil
    }

    private func redirect(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, let scrollView else { return event }
        let point = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(point) else { return event }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard abs(dy) > abs(dx) else { return event }
        // 鼠标滚轮一格的量很小（行为单位），放大到和触控板差不多的手感
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let clip = scrollView.contentView
        let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - clip.bounds.width)
        let x = min(max(clip.bounds.origin.x - dy * scale, 0), maxX)
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
        return nil
    }
}

// MARK: - 把卡片拖到别的 App

/// 卡片拖拽的发起端：按下记住卡片，按住拖动超过一小段距离才开始拖，单击、双击、右键
/// 照常交给 SwiftUI 的手势。用 AppKit 的拖拽会话而不是 SwiftUI `.onDrag`：后者一次
/// 只能带一个条目，勾选了多张或多文件条目时带不全。
private struct ShelfDragSource: NSViewRepresentable {
    let isEnabled: Bool
    let frames: CardFrameStore
    let itemsForDrag: (PersistentIdentifier) -> [ClipItem]
    let onDelivered: ([ClipItem]) -> Void

    func makeNSView(context: Context) -> ShelfDragSourceView {
        let view = ShelfDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ShelfDragSourceView, context: Context) { update(nsView) }

    static func dismantleNSView(_ nsView: ShelfDragSourceView, coordinator: ()) { nsView.removeMonitor() }

    private func update(_ view: ShelfDragSourceView) {
        view.isEnabled = isEnabled
        view.frames = frames
        view.itemsForDrag = itemsForDrag
        view.onDelivered = onDelivered
    }
}

private final class ShelfDragSourceView: NSView, NSDraggingSource {
    var isEnabled = true
    var frames: CardFrameStore?
    var itemsForDrag: ((PersistentIdentifier) -> [ClipItem])?
    var onDelivered: (([ClipItem]) -> Void)?

    private var monitor: Any?
    private var pressed: (id: PersistentIdentifier, location: NSPoint)?
    private var dragging: [ClipItem] = []
    /// 按住移动超过这么远才算拖拽，避免手抖把单击当成拖拽
    private static let dragThreshold: CGFloat = 5

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, isEnabled else {
            pressed = nil
            return event
        }
        switch event.type {
        case .leftMouseDown:
            pressed = cardID(at: event.locationInWindow).map { ($0, event.locationInWindow) }
            return event
        case .leftMouseDragged:
            guard let pressed else { return event }
            let dx = event.locationInWindow.x - pressed.location.x
            let dy = event.locationInWindow.y - pressed.location.y
            guard dx * dx + dy * dy >= Self.dragThreshold * Self.dragThreshold else { return event }
            self.pressed = nil
            return beginDrag(from: pressed.id, event: event) ? nil : event
        default:
            pressed = nil
            return event
        }
    }

    /// 窗口坐标（AppKit，原点左下）落在哪张卡片上；只认整条列表可见范围里的卡片
    private func cardID(at point: NSPoint) -> PersistentIdentifier? {
        guard let frames, let content = window?.contentView else { return nil }
        let global = CGPoint(x: point.x, y: content.bounds.height - point.y)
        guard frames.strip.contains(global) else { return nil }
        return frames.cards.first { $0.value.contains(global) }?.key
    }

    private func beginDrag(from id: PersistentIdentifier, event: NSEvent) -> Bool {
        guard let content = window?.contentView, let card = frames?.cards[id],
              let items = itemsForDrag?(id), !items.isEmpty else { return false }
        let writers = ClipboardManager.shared.pasteboardItemsForDrag(items)
        guard !writers.isEmpty else { return false }

        // 卡片在内容视图里的位置（AppKit 坐标），截一张图当拖拽图像；多张时叠成一摞
        let cardRect = CGRect(x: card.minX, y: content.bounds.height - card.maxY, width: card.width, height: card.height)
        let snapshot = Self.snapshot(of: content, in: cardRect)
        let draggingItems = writers.enumerated().map { index, writer -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: writer)
            let offset = CGFloat(min(index, 3)) * 4
            item.setDraggingFrame(cardRect.offsetBy(dx: offset, dy: -offset), contents: index < 4 ? snapshot : nil)
            return item
        }
        dragging = items
        let session = content.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
        return true
    }

    private static func snapshot(of view: NSView, in rect: CGRect) -> NSImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 只往别的 App 拖：拖回面板自己身上没有意义
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let delivered = dragging
        dragging = []
        guard operation != [], !delivered.isEmpty else { return }
        onDelivered?(delivered)
    }
}
