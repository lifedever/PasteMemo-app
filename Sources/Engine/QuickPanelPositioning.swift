import AppKit
import SwiftUI
import ApplicationServices

enum QuickPanelPositionMode: String, CaseIterable {
    case remembered
    case cursor
    case menuBarIcon
    case windowCenter
    case screenCenter

    var titleKey: String {
        switch self {
        case .remembered: "settings.quickPanelPosition.remembered"
        case .cursor: "settings.quickPanelPosition.cursor"
        case .menuBarIcon: "settings.quickPanelPosition.menuBarIcon"
        case .windowCenter: "settings.quickPanelPosition.windowCenter"
        case .screenCenter: "settings.quickPanelPosition.screenCenter"
        }
    }
}

enum QuickPanelScreenTarget: String, CaseIterable {
    case active
    case specified

    var titleKey: String {
        switch self {
        case .active: "settings.quickPanelTargetScreen.active"
        case .specified: "settings.quickPanelTargetScreen.specified"
        }
    }
}

enum QuickPanelPositionSettings {
    static let modeKey = "quickPanelPositionMode"
    static let screenTargetKey = "quickPanelScreenTarget"
    static let specifiedScreenIDKey = "quickPanelSpecifiedScreenID"
}

enum QuickPanelSettings {
    static let launchAnimationEnabledKey = "quickPanelLaunchAnimationEnabled"
    static let secondaryRowKey = "quickPanelSecondaryRow"
    /// 开关：重新打开快捷面板时是否恢复上次的 tab 主筛选（默认关闭）
    static let rememberLastFilterKey = "quickPanelRememberLastFilter"
    /// 序列化后的上次 tab 主筛选，供恢复用
    static let lastFilterKey = "quickPanelLastFilter"
    /// 「图片」筛选下的展示方式：列表 / 瀑布流网格（默认列表，行为不变）
    static let imageLayoutKey = "quickPanelImageLayout"
    /// 瀑布流密度（疏 / 中 / 密 → 目标列宽），默认中
    static let imageGridDensityKey = "quickPanelImageGridDensity"
    /// 在快捷面板标签栏里隐藏的项（逗号分隔的 id：`pinned` / `all` / 内容类型 rawValue）。
    ///
    /// 刻意不复用 `typeOrder`：那个键是**主窗口侧边栏**的类型排序，而且 `visibleCases`
    /// 会把不在其中的类型自动追加到末尾——新增类型不该悄悄消失，这个行为是对的，不能
    /// 为了实现隐藏去破坏它。所以隐藏用独立的键，两者正交。
    ///
    /// 只作用于快捷面板：主窗口侧边栏保持全量，隐藏之后还能从那儿找回内容。
    static let hiddenTabTypesKey = "quickPanelHiddenTabTypes"
    /// 快捷面板右侧预览区正文（文本 / 代码 / 短信原文等）的字号。
    static let previewFontSizeKey = "quickPanelPreviewFontSize"

    /// 快捷面板标签栏里可排序那部分的顺序（逗号分隔的 id）。空 = 默认顺序。
    ///
    /// 同样和 `typeOrder` 分开：快捷面板可以把「图片」提到最前，主窗口侧边栏不受影响。
    static let tabOrderKey = "quickPanelTabOrder"

    static let pinnedTabID = "pinned"
    static let allTabID = "all"
    static let smsTabID = "sms"

    /// 被隐藏的类型集合
    static func hiddenTabTypes() -> Set<ClipContentType> {
        let raw = UserDefaults.standard.string(forKey: hiddenTabTypesKey) ?? ""
        return Set(raw.split(separator: ",").compactMap { ClipContentType(rawValue: String($0)) })
    }

    /// 被隐藏的项 id 集合（含 `pinned` / `all`）
    static func hiddenTabIDs(from raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// 可排序项的默认顺序：全部，然后跟着主窗口侧边栏的类型顺序走。
    ///
    /// 不含「置顶」——它固定在标签栏第一位，不参与排序（但仍可整个关掉）。
    static var defaultTabOrderIDs: [String] {
        // 短信放末尾：它是小众维度（要开短信转发才有），排在内容类型前面会挤掉高频标签。
        // 也和「存过顺序的老用户那里它被补在末尾」保持一致。
        [allTabID] + ClipContentType.visibleCases.map(\.rawValue) + [smsTabID]
    }

    /// 把存下来的顺序修正成一份完整、无重复、无未知项的列表。
    ///
    /// 两头都要兜：存过的顺序里可能有已经下线的 id（跳过），也可能缺了后来新增的分类
    /// （补到末尾）——新分类默认可见是既定取舍，不能因为老用户存过顺序就永远看不到。
    static func resolvedTabOrderIDs(from raw: String) -> [String] {
        let fallback = defaultTabOrderIDs
        let saved = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !saved.isEmpty else { return fallback }

        let known = Set(fallback)
        var seen = Set<String>()
        var result = saved.filter { known.contains($0) && seen.insert($0).inserted }
        result += fallback.filter { seen.insert($0).inserted }
        return result
    }

    static func resolvedTabItems(from raw: String) -> [QuickPanelTabItem] {
        resolvedTabOrderIDs(from: raw).compactMap(QuickPanelTabItem.parse)
    }
}

/// 快捷面板标签栏里的一项。
///
/// `.pinned` 只用于设置页那个开关和显隐判断，不进 `tabOrder`：它固定在第一位。
/// 分组标签压根不在其中——它们随用户建的分组动态增减，没法预先排。
enum QuickPanelTabItem: Hashable, Identifiable {
    case pinned
    case all
    /// 短信验证码。不是内容类型（那些条目本身是 `.text`），和 AI Agent 一样是一条
    /// 独立的筛选维度——只在真有短信条目时才出现在标签栏。
    case sms
    case type(ClipContentType)

    var id: String { storageID }

    var storageID: String {
        switch self {
        case .pinned: QuickPanelSettings.pinnedTabID
        case .all: QuickPanelSettings.allTabID
        case .sms: QuickPanelSettings.smsTabID
        case .type(let type): type.rawValue
        }
    }

    static func parse(_ raw: String) -> QuickPanelTabItem? {
        switch raw {
        // 刻意不认 `pinned`：它不参与排序，老配置里存过也要被丢掉
        case QuickPanelSettings.allTabID: return .all
        case QuickPanelSettings.smsTabID: return .sms
        default:
            guard let type = ClipContentType(rawValue: raw),
                  ClipContentType.defaultVisibleCases.contains(type) else { return nil }
            return .type(type)
        }
    }

    var icon: String {
        switch self {
        case .pinned: "pin"
        case .all: "tray.full"
        case .sms: "message"
        case .type(let type): type.icon
        }
    }

    @MainActor
    var label: String {
        switch self {
        case .pinned: L10n.tr("filter.pinned")
        case .all: L10n.tr("filter.all")
        case .sms: L10n.tr("filter.sms")
        case .type(let type): type.label
        }
    }
}

/// 选中「图片」类型时的展示方式。仅作用于图片筛选，其它类型始终用列表。
enum QuickPanelImageLayout: String, CaseIterable {
    case list
    case grid

    var titleKey: String {
        switch self {
        case .list: "settings.imageLayout.list"
        case .grid: "settings.imageLayout.grid"
        }
    }
}

/// 瀑布流密度——决定「目标列宽」，面板宽度按它换算出列数（宽度变化列数自适应）。
enum QuickPanelImageGridDensity: String, CaseIterable {
    case sparse
    case medium
    case dense

    /// 目标列宽（pt）。实际列宽会在此基础上拉伸撑满整宽，不留右侧空隙。
    var targetColumnWidth: CGFloat {
        switch self {
        case .sparse: 210
        case .medium: 165
        case .dense: 125
        }
    }

    var titleKey: String {
        switch self {
        case .sparse: "settings.imageGridDensity.sparse"
        case .medium: "settings.imageGridDensity.medium"
        case .dense: "settings.imageGridDensity.dense"
        }
    }
}

/// 快捷面板预览正文的字号。存的就是 pt，默认 13，与改之前的硬编码一致。
enum QuickPanelPreviewFontSize {
    static let defaultPoints = 13
    static let options = [11, 12, 13, 14, 15, 16, 18, 20]

    static func resolved(_ stored: Int) -> Int {
        options.contains(stored) ? stored : defaultPoints
    }

    static func resolvedPoints(_ stored: Int) -> CGFloat {
        CGFloat(resolved(stored))
    }
}

enum QuickPanelSecondaryRow: String, CaseIterable {
    case types
    case groups

    var titleKey: String {
        switch self {
        case .types: "settings.quickPanelSecondaryRow.types"
        case .groups: "settings.quickPanelSecondaryRow.groups"
        }
    }
}

struct ScreenOption: Identifiable, Hashable {
    let id: String
    let name: String
}

enum ScreenLocator {
    static func identifier(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return number.stringValue
    }

    static func options() -> [ScreenOption] {
        let screens = NSScreen.screens
        let grouped = Dictionary(grouping: screens, by: \.localizedName)

        return screens.compactMap { screen in
            guard let id = identifier(for: screen) else { return nil }
            let isDuplicated = (grouped[screen.localizedName]?.count ?? 0) > 1
            let name = isDuplicated ? "\(screen.localizedName) (\(id))" : screen.localizedName
            return ScreenOption(id: id, name: name)
        }
    }

    static func screen(for identifier: String?) -> NSScreen? {
        guard let identifier else { return nil }
        return NSScreen.screens.first { self.identifier(for: $0) == identifier }
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    static func screen(for frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let screen = screen(containing: center) {
            return screen
        }

        return NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }
    }
}

enum ActiveWindowLocator {
    @MainActor
    static func focusedWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let window = windowRef as! AXUIElement

        // Reject non-standard windows (e.g. Finder desktop pseudo-window, which spans all displays).
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String
        if subrole != kAXStandardWindowSubrole as String,
           subrole != kAXDialogSubrole as String,
           subrole != kAXFloatingWindowSubrole as String {
            return nil
        }

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else {
            return nil
        }

        return Self.axRectToCocoa(CGRect(origin: position, size: size))
    }

    /// Convert a rect from AX global coords (origin = top-left of primary screen, Y down)
    /// to Cocoa screen coords (origin = bottom-left of primary screen, Y up).
    @MainActor
    static func axRectToCocoa(_ rect: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.main
        else { return nil }
        let flippedY = primary.frame.height - rect.origin.y - rect.size.height
        return CGRect(x: rect.origin.x, y: flippedY, width: rect.size.width, height: rect.size.height)
    }

    @MainActor
    static func activeScreen() -> NSScreen? {
        if let frame = focusedWindowFrame(), let screen = ScreenLocator.screen(for: frame) {
            return screen
        }
        return NSScreen.screenWithMouse ?? NSScreen.main ?? NSScreen.screens.first
    }
}

enum MenuBarIconLocator {
    @MainActor
    static func iconFrame() -> (frame: CGRect, screen: NSScreen)? {
        for window in NSApp.windows {
            let className = String(describing: type(of: window))
            guard className.contains("StatusBar") else { continue }
            let frame = window.frame
            guard frame.width > 0, frame.height > 0 else { continue }
            let screen = window.screen
                ?? ScreenLocator.screen(containing: CGPoint(x: frame.midX, y: frame.midY))
            guard let screen else { continue }
            return (frame, screen)
        }
        return nil
    }
}

private extension CGRect {
    var area: CGFloat {
        width * height
    }
}
