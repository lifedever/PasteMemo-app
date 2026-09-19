import SwiftUI

@MainActor
enum CommandAction: Hashable {
    case paste
    /// Paste the item, then delete it from history with an 8s undo window.
    /// Intended for one-shot values (OTP codes, temporary tokens) that should
    /// leave no trace after use. Suppressed for pinned / favourited items and
    /// for clips in a group flagged `preservesItems`.
    case pasteAndDestroy
    /// ⌘↩ 的镜像：纯文本粘贴 / 粘贴路径，永远不开链接。`hasKey` 为 false 时让出
    /// 字母键 `P`——那一行有链接可开时 `P` 归 `openLink`，⌘↩ 和底栏提示不受影响。
    case cmdEnter(label: String, hasKey: Bool)
    case copyColorFormat(format: String, label: String)
    /// 打开链接。条目本身就是链接时 `display` 为 nil（标签用通用的「打开链接」），
    /// 混合文本里解析出来的片段则带上 host。⌘↩ 一律是纯文本粘贴，开链接只走这里
    /// 和 ⌘O——两种条目在这件事上没有区别。
    /// `primary` 标记拿 `P` 的那行：多个链接时后面几行挂同一个键，徽章会显示一个
    /// 永远按不到的字母。
    case openLink(url: String, display: String?, primary: Bool)
    /// Paste an access / verification code found inside a mixed-text clip.
    case pasteEntityCode(code: String)
    case retryOCR
    /// Paste the item's recognized OCR text into the frontmost app (runs OCR on
    /// demand first when the text isn't cached). Falls back to clipboard when
    /// there's no target app, e.g. in the main window.
    case pasteOCR
    /// 查看条目内容。`usesPreviewApp` 为真时交给 Preview.app（图片 / PDF），否则走
    /// Quick Look。分两条路是因为 Preview.app 打不开纯文本，而 Quick Look 什么都能显示
    /// ——统一走 Preview.app 的话，文本条目点下去 Preview 只会被拉到前台、不开窗。
    case openInPreview(usesPreviewApp: Bool)
    case showInFinder
    case copy
    case addToRelay
    case splitAndRelay
    case pin(isPinned: Bool)
    case toggleSensitive(isSensitive: Bool)
    case delete
    /// Trigger a manual-trigger automation rule. Carries the rule's ID so the
    /// host can refetch and execute without keeping a SwiftData reference in
    /// a Hashable enum.
    case runRule(ruleID: String, displayName: String)

    var icon: String {
        switch self {
        case .paste: "doc.on.clipboard"
        case .pasteAndDestroy: "flame"
        case .cmdEnter: "textformat"
        case .copyColorFormat: "paintpalette"
        case .openLink: "link"
        case .pasteEntityCode: "key"
        case .retryOCR: "text.viewfinder"
        case .pasteOCR: "doc.text"
        case .openInPreview(let usesPreviewApp): usesPreviewApp ? "photo.on.rectangle.angled" : "eye"
        case .showInFinder: "folder"
        case .copy: "doc.on.doc"
        case .addToRelay: "arrow.right.arrow.left"
        case .splitAndRelay: "scissors"
        case .pin(let pinned): pinned ? "pin.slash" : "pin"
        case .toggleSensitive(let sensitive): sensitive ? "lock.open" : "lock.shield"
        case .delete: "trash"
        case .runRule: "sparkles"
        }
    }

    var label: String {
        switch self {
        case .paste: L10n.tr("cmd.paste")
        case .pasteAndDestroy: L10n.tr("cmd.pasteAndDestroy")
        case .cmdEnter(let label, _): label
        case .copyColorFormat(_, let label): label
        case .openLink(_, let display, _):
            display.map { L10n.tr("cmd.openEntity", $0) } ?? L10n.tr("cmd.openLink")
        case .pasteEntityCode(let code): L10n.tr("cmd.pasteEntity", code)
        case .retryOCR: L10n.tr("cmd.retryOCR")
        case .pasteOCR: L10n.tr("cmd.pasteOCR")
        case .openInPreview(let usesPreviewApp):
            usesPreviewApp ? L10n.tr("cmd.openInPreview") : L10n.tr("cmd.quickLook")
        case .showInFinder: L10n.tr("cmd.showInFinder")
        case .copy: L10n.tr("cmd.copy")
        case .addToRelay: L10n.tr("relay.addToQueue")
        case .splitAndRelay: L10n.tr("relay.splitAndRelay")
        case .pin(let pinned): pinned ? L10n.tr("action.unpin") : L10n.tr("action.pin")
        case .toggleSensitive(let sensitive): sensitive ? L10n.tr("sensitive.unmarkSensitive") : L10n.tr("sensitive.markSensitive")
        case .delete: L10n.tr("cmd.delete")
        case .runRule(_, let displayName): displayName
        }
    }

    var shortcutKey: String? {
        switch self {
        case .paste: "V"
        case .pasteAndDestroy: "B"
        case .cmdEnter(_, let hasKey): hasKey ? "P" : nil
        case .copyColorFormat: "P"
        case .openLink(_, _, let primary): primary ? "P" : nil
        case .pasteEntityCode: "K"
        case .retryOCR: "Y"
        case .pasteOCR: "G"
        case .openInPreview: "L"
        case .showInFinder: "O"
        case .copy: "C"
        case .addToRelay: "R"
        case .splitAndRelay: "S"
        case .pin: "T"
        case .toggleSensitive: "E"
        case .delete: "D"
        case .runRule: nil
        }
    }

    var keyCode: Int? {
        switch self {
        case .paste: 9       // V
        case .pasteAndDestroy: 11 // B
        case .cmdEnter(_, let hasKey): hasKey ? 35 : nil // P
        case .copyColorFormat: 35 // P
        case .openLink(_, _, let primary): primary ? 35 : nil // P
        case .pasteEntityCode: 40 // K
        case .retryOCR: 16   // Y
        case .pasteOCR: 5     // G
        case .openInPreview: 37 // L
        case .showInFinder: 31 // O
        case .copy: 8        // C
        case .addToRelay: 15 // R
        case .splitAndRelay: 1 // S
        case .pin: 17        // T
        case .toggleSensitive: 14 // E
        case .delete: 2      // D
        case .runRule: nil
        }
    }

    var isDestructive: Bool {
        switch self {
        case .delete, .pasteAndDestroy: true
        default: false
        }
    }

    /// Logical section for visually grouping the palette. A divider is drawn
    /// wherever two consecutive visible rows belong to different groups.
    /// 0 粘贴 · 1 识别与查看 · 2 复制与接力 · 3 管理 · 4 自动化
    var group: Int {
        switch self {
        case .paste, .pasteAndDestroy, .cmdEnter, .copyColorFormat: 0
        case .openLink, .pasteEntityCode,
             .retryOCR, .pasteOCR, .openInPreview, .showInFinder: 1
        case .copy, .addToRelay, .splitAndRelay: 2
        case .pin, .toggleSensitive, .delete: 3
        case .runRule: 4
        }
    }

    /// Actions whose handler tears down the whole Quick Panel. `handleCommandAction`
    /// skips the up-front `showCommandPalette = false` for these — otherwise the
    /// queued popover dismiss gets force-flushed by the panel's own `dismiss()`
    /// and the close stalls for a beat (the lag vs. a direct Enter paste).
    var dismissesQuickPanel: Bool {
        switch self {
        case .paste, .pasteAndDestroy, .cmdEnter, .copy, .pasteOCR, .showInFinder,
             .openLink, .pasteEntityCode: true
        default: false
        }
    }
}

/// macOS 26 上把 popover 的系统默认背景换成更通透的玻璃材质（与快捷面板本体的
/// Liquid Glass 呼应）；presentationBackground 的替换内容由 NSPopover 按自身外形
/// （含指向箭头）裁剪，不会破坏气泡形状。旧系统保持系统默认材质。
/// 注：完整 glassEffect 需要自定义形状、盖不住系统画的指向箭头，popover 形态下
/// ultraThinMaterial 是能做到的最大通透度。
/// popover 形态才需要固定宽度和 presentationBackground。嵌入玻璃浮层时两样都要
/// 去掉：presentationBackground 脱离 popover 上下文根本不生效（面板会没有底），
/// 而内层再钉一个 200pt 宽度会让外层容器和内容宽度对不上、两边空一圈。
private struct PaletteChrome: ViewModifier {
    let embedded: Bool

    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                // 行内尺寸整体放大后 200 装不下「图标 + 文字 + 快捷键徽章」
                .frame(width: 260)
                .modifier(PaletteGlassBackground())
        }
    }
}

private struct PaletteGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.presentationBackground(.ultraThinMaterial)
        } else {
            content
        }
    }
}

// MARK: - Command Palette Content (popover body)

struct CommandPaletteContent: View {
    let item: ClipItem?
    let isMultiSelected: Bool
    /// Manual-trigger rules shown inline in the palette. Capped to 5 at the
    /// call site so a big rule list doesn't drown out built-in actions.
    var manualRules: [AutomationRule] = []
    /// Group names flagged `preservesItems` at the moment the palette opened.
    /// Used to suppress `pasteAndDestroy` for items whose group forbids deletion.
    var preservedGroupNames: Set<String> = []
    let onAction: (CommandAction) -> Void
    let onDismiss: () -> Void
    /// true：不自带宽度和背景，交给外部容器（快捷面板右下角的玻璃浮层）。
    /// false：保持 popover 形态需要的固定宽度 + presentationBackground——主窗口
    /// 仍走 popover，那条路径不能动。
    var embedded: Bool = false

    @State private var selectedIndex = 0
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var isOptionPressed = false
    /// 内容里认出来的链接 / 提取码。算一次存下来，不放进 `actions` 现算——键盘上下
    /// 移动焦点会反复求值 body，每次重跑一遍关键词扫描是白扔的开销。
    @State private var entities: [TextEntityExtractor.Entity] = []

    // keyCodes for digits 1..5 on an ANSI keyboard
    private static let digitKeyCodes: [Int] = [18, 19, 20, 21, 23]

    /// True when the current single-selection item can be paste-and-destroyed.
    /// Intentionally gated on single selection: multi-select paste-and-destroy is
    /// ambiguous (delete every selected item? only the active one?) so we skip it
    /// in that mode. Also suppressed for pinned / favourited items and for items
    /// whose group opts out of deletion via `SmartGroup.preservesItems`.
    private var canPasteAndDestroy: Bool {
        guard !isMultiSelected, let item else { return false }
        if item.isPinned || item.isFavorite { return false }
        if let group = item.groupName, !group.isEmpty, preservedGroupNames.contains(group) {
            return false
        }
        return true
    }

    /// ⌘K 里 `P` 该开的链接。判定和执行都由 `TextEntityExtractor.openableLink`
    /// 给，快捷面板的键监听走同一个函数，不会和这里说的不一样。
    private var openableLink: (url: String, display: String?)? {
        guard !isMultiSelected, let item else { return nil }
        return TextEntityExtractor.openableLink(for: item)
    }

    private var actions: [CommandAction] {
        var list: [CommandAction] = [.paste]
        if canPasteAndDestroy {
            list.append(.pasteAndDestroy)
        }
        if let item, item.contentType == .color, let parsed = ColorConverter.parse(item.content) {
            let alt = parsed.alternateFormat
            let altValue = parsed.formatted(alt)
            list.append(.copyColorFormat(
                format: altValue,
                label: L10n.tr("cmd.copyAs", alt.rawValue)
            ))
        } else if let item, item.contentType != .color {
            // 有链接可开时让出 `P`（见下面的 openLink），⌘↩ 和底栏提示照常
            list.append(.cmdEnter(
                label: cmdEnterLabel(for: item),
                hasKey: openableLink == nil
            ))
        }
        // 打开链接：条目整条是链接、或者内容里解析出了链接，都走这一行，`P` 键。
        // ⌘↩ 不参与——它是纯文本粘贴，见上面的 cmdEnter。
        if let openableLink {
            list.append(.openLink(
                url: openableLink.url, display: openableLink.display, primary: true
            ))
        }
        // 多出来的片段链接不给字母键，方向键可达
        for link in entities.filter({ $0.kind == .link }).dropFirst() {
            list.append(.openLink(url: link.value, display: link.display, primary: false))
        }
        if let code = entities.first(where: { $0.kind == .code }) {
            list.append(.pasteEntityCode(code: code.value))
        }
        if !isMultiSelected,
           let item,
           OCRTaskCoordinator.shared.canRetry(item: item) {
            list.append(.retryOCR)
        }
        // Shown for any OCR-able image — even with auto-OCR off / no text yet.
        // Clicking runs OCR on demand (see QuickPanelView/MainWindowView).
        if !isMultiSelected,
           let item,
           (item.contentType == .image && item.imageData != nil) || (item.ocrText?.isEmpty == false) {
            list.append(.pasteOCR)
        }
        if !isMultiSelected,
           let item,
           let route = QuickLookHelper.shared.previewRoute(for: item) {
            list.append(.openInPreview(usesPreviewApp: route == .previewApp))
        }
        // File-based clips always offer "Show in Finder"; plain-text clips do too
        // when their content is itself an existing filesystem path.
        if let item, item.contentType.isFileBased || item.revealableFinderPath != nil {
            list.append(.showInFinder)
        }
        list.append(.copy)
        list.append(.addToRelay)
        if !isMultiSelected, let item, !item.content.isEmpty {
            list.append(.splitAndRelay)
        }
        let isPinned = isMultiSelected ? false : (item?.isPinned ?? false)
        let isSensitive = isMultiSelected ? false : (item?.isSensitive ?? false)
        list.append(.pin(isPinned: isPinned))
        list.append(.toggleSensitive(isSensitive: isSensitive))
        list.append(.delete)
        // Manual-trigger automation rules, appended after built-in actions so
        // they don't displace high-use commands (Paste, Copy, etc).
        for rule in manualRules {
            let displayName = rule.isBuiltIn ? L10n.tr(rule.name) : rule.name
            list.append(.runRule(ruleID: rule.ruleID, displayName: displayName))
        }
        return list
    }

    /// Digit shortcut to display next to a rule row (1-indexed). Only rules
    /// map to digits 1–5; earlier built-in commands keep their letter keys.
    private func digitForAction(at index: Int) -> String? {
        let action = actions[index]
        guard case .runRule = action else { return nil }
        let ruleIndex = actions[..<index].reduce(0) { count, a in
            if case .runRule = a { return count + 1 }
            return count
        }
        guard ruleIndex < Self.digitKeyCodes.count else { return nil }
        return String(ruleIndex + 1)
    }

    private func cmdEnterLabel(for item: ClipItem) -> String {
        // ⌘↩ 在所有条目上是同一件事：纯文本粘贴（文件类是粘贴路径）。链接条目也不
        // 例外——它整条就是 URL，粘纯文本和富文本去格式是同一个语义。
        switch item.contentType {
        case .text, .code, .color, .email, .phone, .mixed, .link:
            L10n.tr("cmd.pasteAsPlainText")
        case .image, .file, .document, .archive, .application, .video, .audio:
            L10n.tr("cmd.pastePath")
        }
    }

    /// 浮层形态才套 ScrollView，且 ScrollViewReader 必须和 selectedIndex 在同一个
    /// view 里——键盘上下移动焦点时要把焦点项滚进可见区，否则一旦超出一屏，按方向键
    /// 就等于在盲选。popover 形态高度由系统撑开，不需要滚动。
    @ViewBuilder
    private var paletteBody: some View {
        if embedded {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    rowsStack.padding(8)
                }
                .onChange(of: selectedIndex) { _, newValue in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        } else {
            rowsStack.padding(8)
        }
    }

    private var rowsStack: some View {
        VStack(spacing: 1) {
            // 标题行：告诉用户这一菜单在对哪个对象操作（Raycast 同款）。只在浮层
            // 形态显示——popover 有指向箭头指明来源，不需要再重复一次。
            if embedded {
                Text(paletteTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
            }
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                if index > 0, actions[index - 1].group != action.group {
                    Divider()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                commandRow(action: action, isSelected: selectedIndex == index, index: index)
                    .onTapGesture { execute(action) }
                    .onHover { if $0 { selectedIndex = index } }
                    // scrollTo 的锚点
                    .id(index)
            }
        }
    }

    var body: some View {
        paletteBody
            .modifier(PaletteChrome(embedded: embedded))
            .onAppear {
            installKeyMonitor()
            installFlagsMonitor()
            loadEntities()
        }
        // 面板不关而换了条目（父视图带着新 item 重建）时 @State 不会重置，
        // 不重算就会拿上一条的链接 / 码去执行。
        .onChange(of: item?.itemID) { _, _ in loadEntities() }
        .onDisappear {
            removeKeyMonitor()
            removeFlagsMonitor()
        }
    }

    /// 浮层顶部的标题：多选时报条数，单选时用条目标题，都拿不到就退回通用标题。
    private var paletteTitle: String {
        if isMultiSelected { return L10n.tr("cmd.title") }
        if let title = item?.displayTitle, !title.isEmpty { return title }
        return L10n.tr("cmd.title")
    }

    private func displayLabel(for action: CommandAction) -> String {
        let suffix = isOptionPressed ? L10n.tr("cmd.andNewLine") : ""
        switch action {
        case .paste, .cmdEnter: return action.label + suffix
        default: return action.label
        }
    }

    private func commandRow(action: CommandAction, isSelected: Bool, index: Int) -> some View {
        let isRuleRow: Bool = {
            if case .runRule = action { return true }
            return false
        }()
        let ruleDigit = digitForAction(at: index)
        // 尺寸整体对齐 Raycast 的 actions 菜单：原来的 11/12/18 三档太局促，
        // 图标和快捷键徽章挤成一团，视觉上「小气」。
        return HStack(spacing: 9) {
            Image(systemName: action.icon)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(
                    action.isDestructive ? .red : (isRuleRow ? .purple : .secondary)
                )
            Text(displayLabel(for: action))
                .font(.system(size: 13))
                .foregroundStyle(action.isDestructive ? .red : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if let key = action.shortcutKey ?? ruleDigit {
                // 独立圆角小方块 + 细描边，而不是一块糊上去的浅灰底
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
            }
        }
        .padding(.horizontal, 10)
        // 5 而不是 8：动作项十几条，行高每多 3pt 就多占 40pt，直接决定「一屏能不能
        // 望全」——望不全就得滚动，用户就没法扫一眼直接按快捷键。
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                // 中性灰而非 accentColor：面板整体是柔和玻璃，一颗饱和蓝是全场
                // 唯一的高饱和色，必然跳出来。
                .fill(isSelected ? Color.primary.opacity(0.09) : .clear)
        )
        .contentShape(Rectangle())
    }

    private func execute(_ action: CommandAction) {
        removeKeyMonitor()
        removeFlagsMonitor()
        onAction(action)
        onDismiss()
    }

    private func dismiss() {
        removeKeyMonitor()
        removeFlagsMonitor()
        onDismiss()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            let hasControl = event.modifierFlags.contains(.control)
            switch code {
            case 53: dismiss(); return nil // Esc
            case 40 where event.modifierFlags.contains(.command): dismiss(); return nil // Cmd+K
            case 13 where event.modifierFlags.contains(.command): dismiss(); return nil // Cmd+W
            case 126: // Up
                selectedIndex = selectedIndex > 0 ? selectedIndex - 1 : actions.count - 1; return nil
            case 125: // Down
                selectedIndex = selectedIndex < actions.count - 1 ? selectedIndex + 1 : 0; return nil
            case 35: // P
                if hasControl {
                    selectedIndex = selectedIndex > 0 ? selectedIndex - 1 : actions.count - 1
                    return nil
                }
                return event
            case 45: // N
                if hasControl {
                    selectedIndex = selectedIndex < actions.count - 1 ? selectedIndex + 1 : 0
                    return nil
                }
                return event
            case 36: execute(actions[selectedIndex]); return nil // Enter
            default:
                if let match = actions.first(where: { $0.keyCode == code }) {
                    execute(match); return nil
                }
                // Digits 1–5 trigger the Nth manual-trigger rule inline.
                if let digitIndex = Self.digitKeyCodes.firstIndex(of: code) {
                    let ruleActions = actions.filter {
                        if case .runRule = $0 { return true }
                        return false
                    }
                    if digitIndex < ruleActions.count {
                        execute(ruleActions[digitIndex])
                        return nil
                    }
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// 该扫哪些条目由 `TextEntityExtractor.entities(for:)` 判定（含敏感条目遮蔽），
    /// 这里只管多选时不扫。
    private func loadEntities() {
        guard !isMultiSelected, let item else {
            entities = []
            return
        }
        entities = TextEntityExtractor.entities(for: item)
    }

    private func installFlagsMonitor() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            isOptionPressed = event.modifierFlags.contains(.option)
            return event
        }
    }

    private func removeFlagsMonitor() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
    }
}
