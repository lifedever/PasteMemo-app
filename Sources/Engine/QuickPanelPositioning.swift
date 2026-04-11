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
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef
        else {
            return nil
        }
        let window = windowRef as! AXUIElement

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef
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

        return CGRect(origin: position, size: size)
    }

    @MainActor
    static func activeScreen() -> NSScreen? {
        if let frame = focusedWindowFrame(), let screen = ScreenLocator.screen(for: frame) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screenWithMouse ?? NSScreen.screens.first
    }
}

@MainActor
final class MenuBarAnchorStore: ObservableObject {
    static let shared = MenuBarAnchorStore()

    @Published private(set) var frameInScreen: CGRect?
    private(set) var screenID: String?

    private init() {}

    func update(frame: CGRect?, screenID: String?) {
        frameInScreen = frame
        self.screenID = screenID
    }
}

struct MenuBarAnchorReporter: NSViewRepresentable {
    func makeNSView(context: Context) -> MenuBarAnchorTrackingView {
        MenuBarAnchorTrackingView()
    }

    func updateNSView(_ nsView: MenuBarAnchorTrackingView, context: Context) {
        nsView.scheduleUpdate()
    }
}

final class MenuBarAnchorTrackingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleUpdate()
    }

    override func layout() {
        super.layout()
        scheduleUpdate()
    }

    func scheduleUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.reportAnchor()
        }
    }

    private func reportAnchor() {
        guard let window else { return }

        let frameInWindow = convert(bounds, to: nil)
        let frameInScreen = window.convertToScreen(frameInWindow)
        let screen = window.screen ?? ScreenLocator.screen(containing: frameInScreen.center)

        MenuBarAnchorStore.shared.update(
            frame: frameInScreen,
            screenID: screen.flatMap(ScreenLocator.identifier(for:))
        )
    }
}

private extension CGRect {
    var area: CGFloat {
        width * height
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
