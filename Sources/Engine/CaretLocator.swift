import AppKit
import ApplicationServices

/// 目标 App 键盘焦点的一次采样。坐标都是 AppKit 屏幕坐标（原点在主屏左下，y 向上）。
struct FocusSnapshot {
    /// 焦点是不是文字输入控件（文本框 / 文本区 / 组合框 / 搜索框）
    var isTextInput: Bool
    /// 文字光标的位置
    var caretRect: CGRect?
    /// 焦点输入框的边框，只有 `isTextInput` 时才有
    var inputFrame: CGRect?

    static let empty = FocusSnapshot(isTextInput: false, caretRect: nil, inputFrame: nil)

    /// 贴边条判断「贴底会不会挡住输入位置」用的点：先看光标，读不到用输入框中心；都没有时为 nil，由调用方退回鼠标位置。
    var anchor: CGPoint? {
        if let caretRect { return CGPoint(x: caretRect.midX, y: caretRect.midY) }
        if let inputFrame { return CGPoint(x: inputFrame.midX, y: inputFrame.midY) }
        return nil
    }
}

/// 读目标 App 的键盘焦点：是不是文字输入框、光标在哪、输入框在哪。
///
/// 必须在快捷面板 `makeKey()` 之前调用，抢了 key 之后读到的是面板自己的焦点。
///
/// 2026-11-18 在各 App 里实测过（源码和日志在仓库外的 experiments/caret-probe）：
/// - 备忘录、Typora、Word 正文、VS Code、Telegram：光标位置可用
/// - 企业微信、钉钉：报出的光标整整偏上一行；第一行会落在输入框外面，被下面的
///   「光标须在输入框内」挡掉，退回用输入框中心，对「会不会被挡住」的判断影响不大
/// - Chrome：焦点在链接 / 按钮上时 text marker 会报出不在任何输入框里的位置，所以只认
///   文字类控件；空输入框读不到光标，只有输入框边框
/// - 微信、WPS、终端：读不到光标，也没有输入框边框
/// - App 忙的时候单次 AX 调用会吃满超时，几次叠起来能到 750ms，所以读光标有总时限，
///   超了就放弃，调用方退回鼠标位置
enum CaretLocator {
    /// 焦点落在这些 AX 角色上时，用户的意图是「往这个框里打字」。
    static let textInputRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// 读焦点元素和角色的超时。沿用之前 `focusIsTextInput` 的 200ms：目标 App 卡住时
    /// AX 默认要等好几秒，会把面板弹出一起拖住。
    private static let focusTimeout: Float = 0.2
    /// 读光标（输入框边框 + 选区 + 边界）的总时限，从开始采样算起。
    private static let caretBudget: TimeInterval = 0.06

    /// - Parameter wantsCaret: 只有贴边条「避开输入位置」需要光标；其余情况只判断是不是
    ///   文字输入框，和原来的 `focusIsTextInput` 完全一样，不多发 AX 请求。
    @MainActor
    static func sample(_ app: NSRunningApplication?, wantsCaret: Bool) -> FocusSnapshot {
        guard let pid = app?.processIdentifier else { return .empty }
        let start = Date()
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, focusTimeout)
        guard let focused = copyElement(axApp, kAXFocusedUIElementAttribute) else { return .empty }
        // 超时是按元素设的：给应用元素设的那个管不到焦点元素，不设的话 App 卡住时这一步能等好几秒
        AXUIElementSetMessagingTimeout(focused, focusTimeout)
        guard let role = copyString(focused, kAXRoleAttribute),
              textInputRoles.contains(role) else { return .empty }

        var snapshot = FocusSnapshot(isTextInput: true, caretRect: nil, inputFrame: nil)
        guard wantsCaret else { return snapshot }

        let reader = BudgetedReader(element: focused, start: start, budget: caretBudget)
        guard let frameAX = reader.frame() else { return snapshot }
        snapshot.inputFrame = ActiveWindowLocator.axRectToCocoa(frameAX)
        if let caretAX = reader.caret(), Self.caret(caretAX, isInside: frameAX) {
            snapshot.caretRect = ActiveWindowLocator.axRectToCocoa(caretAX)
        }
        return snapshot
    }

    /// 光标要落在输入框里（留 4pt 余量）才算数。挡掉 Chrome 链接上的脏位置，以及
    /// 企业微信 / 钉钉偏上一行时落到框外的那一行。坐标都是 AX 坐标。
    static func caret(_ caret: CGRect, isInside input: CGRect) -> Bool {
        input.insetBy(dx: -4, dy: -4).contains(CGPoint(x: caret.minX, y: caret.midY))
    }

    /// AX 报回来的矩形像不像一个光标：高度合理、不是零点。有的 App 读不到时返回全零矩形。
    static func isPlausibleCaret(_ rect: CGRect) -> Bool {
        rect.height >= 4 && rect.height <= 200 && !(rect.minX == 0 && rect.minY == 0)
    }

    // MARK: - AX 读取

    fileprivate static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    fileprivate static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}

/// 在总时限内依次发 AX 请求；每次请求的超时取剩余时间，时间用完就不再发。
private struct BudgetedReader {
    let element: AXUIElement
    let start: Date
    let budget: TimeInterval

    /// 还能发请求就把这次请求的超时设成剩余时间
    private func armed() -> Bool {
        let remaining = budget - Date().timeIntervalSince(start)
        guard remaining > 0.005 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(remaining))
        return true
    }

    func frame() -> CGRect? {
        guard armed(), let position: CGPoint = value(of: kAXPositionAttribute, .cgPoint, .zero),
              armed(), let size: CGSize = value(of: kAXSizeAttribute, .cgSize, .zero),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// 读法顺序（实测各有 App 只认其中一种）：
    /// 选区起点的零长度边界 → 前一个字符的右边缘 → 后一个字符的左边缘 → text marker
    func caret() -> CGRect? {
        guard armed() else { return nil }
        if let range: CFRange = value(of: kAXSelectedTextRangeAttribute, .cfRange, CFRange()) {
            if let r = bounds(CFRange(location: range.location, length: 0)) { return r }
            if range.location > 0, let r = bounds(CFRange(location: range.location - 1, length: 1)) {
                return CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height)
            }
            if let r = bounds(CFRange(location: range.location, length: 1)) {
                return CGRect(x: r.minX, y: r.minY, width: 1, height: r.height)
            }
        }
        return markerBounds()
    }

    private func bounds(_ range: CFRange) -> CGRect? {
        guard armed() else { return nil }
        var range = range
        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &ref
        ) == .success else { return nil }
        guard let rect: CGRect = Self.unwrap(ref, .cgRect, .zero), CaretLocator.isPlausibleCaret(rect) else { return nil }
        return rect
    }

    private func markerBounds() -> CGRect? {
        guard armed() else { return nil }
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
              let markerRange, armed() else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &ref
        ) == .success else { return nil }
        guard let rect: CGRect = Self.unwrap(ref, .cgRect, .zero), CaretLocator.isPlausibleCaret(rect) else { return nil }
        return CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 1), height: rect.height)
    }

    private func value<T: BitwiseCopyable>(of attribute: String, _ type: AXValueType, _ initial: T) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return Self.unwrap(ref, type, initial)
    }

    private static func unwrap<T: BitwiseCopyable>(_ ref: CFTypeRef?, _ type: AXValueType, _ initial: T) -> T? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var out = initial
        return AXValueGetValue(ref as! AXValue, type, &out) ? out : nil
    }
}
