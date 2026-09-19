@preconcurrency import AppKit
import SwiftUI

/// AppKit menus for places where SwiftUI's own `Menu` / `.contextMenu` render in the
/// compact, non-standard style (seen app-wide on macOS 26+): a real `NSMenu` pops up
/// with the system look, nested submenus and separators included.
struct NativeMenuItem {
    enum Kind { case item, separator, submenu([NativeMenuItem]) }
    var title: String = ""
    var kind: Kind = .item
    /// SF Symbol shown in the leading column. Give at least one item per menu an icon:
    /// a menu with no images and no checkmarks renders without the leading inset and
    /// looks cramped next to Finder's.
    var symbol: String? = nil
    var isDestructive = false
    var isEnabled = true
    var isChecked = false
    var action: (() -> Void)? = nil

    static func item(_ title: String, symbol: String? = nil, checked: Bool = false, destructive: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> NativeMenuItem {
        NativeMenuItem(title: title, kind: .item, symbol: symbol, isDestructive: destructive, isEnabled: enabled, isChecked: checked, action: action)
    }
    static var separator: NativeMenuItem { NativeMenuItem(kind: .separator) }
    static func submenu(_ title: String, symbol: String? = nil, _ items: [NativeMenuItem]) -> NativeMenuItem {
        NativeMenuItem(title: title, kind: .submenu(items), symbol: symbol)
    }
}

/// Holds the closures behind `NSMenuItem`s; the menu keeps it alive via `representedObject`.
private final class MenuActionBox: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire(_ sender: Any?) { action() }
}

enum NativeMenuBuilder {
    static func build(_ items: [NativeMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Menus popped from inside a SwiftUI list came up in the small "compact" font;
        // pin the regular menu font so they match every other menu in the system.
        menu.font = NSFont.menuFont(ofSize: 0)
        menu.minimumWidth = 180
        for item in items {
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
            case .submenu(let children):
                let mi = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                mi.submenu = build(children)
                if let symbol = item.symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                menu.addItem(mi)
            case .item:
                let box = MenuActionBox(item.action ?? {})
                let mi = NSMenuItem(title: item.title, action: #selector(MenuActionBox.fire(_:)), keyEquivalent: "")
                mi.target = box
                mi.representedObject = box
                mi.isEnabled = item.isEnabled
                mi.state = item.isChecked ? .on : .off
                if let symbol = item.symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                if item.isDestructive, #available(macOS 14, *) {
                    mi.attributedTitle = NSAttributedString(string: item.title, attributes: [.foregroundColor: NSColor.systemRed])
                }
                menu.addItem(mi)
            }
        }
        return menu
    }
}

// MARK: - Context menu

/// Catches right-click / ⌃-click over the modified view and pops a standard `NSMenu`.
/// Left clicks fall through to the SwiftUI content underneath.
/// The overlay sits above the SwiftUI row, so it also has to forward the plain click
/// (`onSelect`) — SwiftUI's list-selection gesture doesn't see through a representable.
struct NativeContextMenu: ViewModifier {
    let onSelect: () -> Void
    let items: () -> [NativeMenuItem]

    func body(content: Content) -> some View {
        content.overlay(RightClickCatcher(onSelect: onSelect, items: items))
    }
}

extension View {
    func nativeContextMenu(onSelect: @escaping () -> Void, _ items: @escaping () -> [NativeMenuItem]) -> some View {
        modifier(NativeContextMenu(onSelect: onSelect, items: items))
    }
}

private struct RightClickCatcher: NSViewRepresentable {
    let onSelect: () -> Void
    let items: () -> [NativeMenuItem]

    func makeNSView(context: Context) -> RightClickCatcherView {
        let view = RightClickCatcherView()
        view.onSelect = onSelect
        view.items = items
        return view
    }

    func updateNSView(_ nsView: RightClickCatcherView, context: Context) {
        nsView.onSelect = onSelect
        nsView.items = items
    }
}

private final class RightClickCatcherView: NSView {
    var onSelect: () -> Void = {}
    var items: () -> [NativeMenuItem] = { [] }

    /// Go through AppKit's own right-click path (`menu(for:)` → default `rightMouseDown`)
    /// rather than popping the menu programmatically: programmatic `popUp` /
    /// `popUpContextMenu` came up in the compact style on macOS 26+, this path gives
    /// the same menu Finder shows.
    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect()   // Finder selects the row it's about to show a menu for
        return NativeMenuBuilder.build(items())
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }
        } else {
            onSelect()
        }
    }
}

// MARK: - Pull-down button

/// Standard pull-down (`NSPopUpButton(pullsDown:)`) — "+ 添加动作 ▾" with real submenus.
struct NativePullDownButton: NSViewRepresentable {
    let title: String
    var symbolName: String? = nil
    var bordered = true
    let items: () -> [NativeMenuItem]

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = bordered
        button.controlSize = .regular
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        context.coordinator.rebuild(button, title: title, symbolName: symbolName, items: items())
        button.menu?.delegate = context.coordinator
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.title = title
        context.coordinator.symbolName = symbolName
        context.coordinator.items = items
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(title: title, symbolName: symbolName, items: items)
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var title: String
        var symbolName: String?
        var items: () -> [NativeMenuItem]
        init(title: String, symbolName: String?, items: @escaping () -> [NativeMenuItem]) {
            self.title = title; self.symbolName = symbolName; self.items = items
        }

        /// Rebuilt on every open so item state (enabled flags, current groups) is fresh.
        /// Item 0 is the pull-down's title and stays put.
        func menuNeedsUpdate(_ menu: NSMenu) {
            while menu.items.count > 1 { menu.removeItem(at: 1) }
            let fresh = NativeMenuBuilder.build(items())
            for item in fresh.items {
                fresh.removeItem(item)
                menu.addItem(item)
            }
        }

        func rebuild(_ button: NSPopUpButton, title: String, symbolName: String?, items: [NativeMenuItem]) {
            let menu = NativeMenuBuilder.build(items)
            // A pull-down shows its first item as the button face.
            let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let symbolName {
                titleItem.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            }
            menu.insertItem(titleItem, at: 0)
            menu.delegate = self
            button.menu = menu
            if symbolName != nil, title.isEmpty {
                button.imagePosition = .imageOnly
                (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            }
            button.sizeToFit()
        }
    }
}

// MARK: - Monitor-based context menu (transparent to hit-testing)

/// For rows that already own their clicks (table rows with tap / multi-select
/// handling): watches right-clicks through a local event monitor like
/// `RightClickModifier` does, and pops a standard `NSMenu` when the click lands
/// inside the view. Never touches hit-testing, so every other gesture keeps working.
struct NativeContextMenuMonitor: ViewModifier {
    let items: () -> [NativeMenuItem]

    func body(content: Content) -> some View {
        content.background(
            ContextMenuMonitorView(items: items)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }
}

extension View {
    func nativeContextMenuMonitor(_ items: @escaping () -> [NativeMenuItem]) -> some View {
        modifier(NativeContextMenuMonitor(items: items))
    }
}

private struct ContextMenuMonitorView: NSViewRepresentable {
    let items: () -> [NativeMenuItem]

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.alphaValue = 0
        context.coordinator.view = view
        context.coordinator.startMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.items = items
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitor()
    }

    final class Coordinator: @unchecked Sendable {
        var items: () -> [NativeMenuItem]
        weak var view: NSView?
        private var monitor: Any?

        init(items: @escaping () -> [NativeMenuItem]) { self.items = items }

        func startMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .leftMouseDown, !event.modifierFlags.contains(.control) { return event }
                let windowNumber = event.windowNumber
                let location = event.locationInWindow
                let hit = MainActor.assumeIsolated { () -> Bool in
                    guard let view = self.view, let window = view.window,
                          window.windowNumber == windowNumber else { return false }
                    return view.bounds.contains(view.convert(location, from: nil))
                }
                guard hit else { return event }
                // Let the row's own right-click handler (selection) run first, then show.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let view = self.view else { return }
                        let menu = NativeMenuBuilder.build(self.items())
                        guard !menu.items.isEmpty else { return }
                        menu.popUp(positioning: nil, at: view.convert(location, from: nil), in: view)
                    }
                }
                return event
            }
        }

        func stopMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stopMonitor() }
    }
}
