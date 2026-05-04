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
