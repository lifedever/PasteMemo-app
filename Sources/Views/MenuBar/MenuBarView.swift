import SwiftUI
import ApplicationServices

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var hotkeyManager = HotkeyManager.shared
    @ObservedObject private var clipboardManager = ClipboardManager.shared
    @AppStorage("hideDockIcon") private var hideDockIcon = false

    var body: some View {
        let _ = storeOpenWindowAction()

        if !AXIsProcessTrusted() {
            Button {
                openAccessibilitySettings()
            } label: {
                Text(L10n.tr("menu.accessibility.grant"))
            }
            Divider()
        }

        Button {
            handleOpenMainWindow()
        } label: {
            let shortcut = hotkeyManager.isManagerCleared ? "" : shortcutDisplayString(keyCode: hotkeyManager.managerKeyCode, modifiers: hotkeyManager.managerModifiers)
            if shortcut.isEmpty {
                Text(L10n.tr("menu.manager"))
            } else {
                Text("\(L10n.tr("menu.manager"))    \(shortcut)")
            }
        }

        Button {
            handleOpenQuickPanel()
        } label: {
            let shortcut = hotkeyManager.displayString
            if shortcut.isEmpty {
                Text(L10n.tr("menu.quickPanel"))
            } else {
                Text("\(L10n.tr("menu.quickPanel"))    \(shortcut)")
            }
        }

        Button {
            clipboardManager.togglePause()
        } label: {
            Text(clipboardManager.isPaused ? L10n.tr("menu.resume") : L10n.tr("menu.pause"))
        }
        .disabled(RelayManager.shared.isActive)

        if RelayManager.shared.isActive {
            Button {
                RelayManager.shared.deactivate()
            } label: {
                Text("\(L10n.tr("relay.title")) (\(RelayManager.shared.progressText)) — \(L10n.tr("relay.exitRelay"))")
            }
        } else {
            Button {
                RelayManager.shared.activate()
            } label: {
                let shortcut = hotkeyManager.isRelayCleared ? "" : shortcutDisplayString(keyCode: hotkeyManager.relayKeyCode, modifiers: hotkeyManager.relayModifiers)
                if shortcut.isEmpty {
                    Text(L10n.tr("relay.startRelay"))
                } else {
                    Text("\(L10n.tr("relay.startRelay"))    \(shortcut)")
                }
            }
        }

        Divider()

        Button(L10n.tr("settings.automation.manage")) {
            AppAction.shared.openAutomationManager?()
        }

        Button(L10n.tr("menu.settings")) {
            if !hideDockIcon {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Divider()

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PasteMemo"
        Button(L10n.tr("menu.quit", appName)) {
            AppDelegate.shouldReallyQuit = true
            NSApp.terminate(nil)
        }
    }

    private func storeOpenWindowAction() {
        let hideDock = hideDockIcon
        AppAction.shared.openMainWindow = { [openWindow] in
            openWindow(id: "main")
            if !hideDock {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        AppAction.shared.openSettings = { [openSettings] in
            if !hideDock {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        AppAction.shared.openAutomationManager = { [openWindow] in
            if !hideDock {
                NSApp.setActivationPolicy(.regular)
            }
            openWindow(id: "automationManager")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func handleOpenMainWindow() {
        openWindow(id: "main")
        if !hideDockIcon {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleOpenQuickPanel() {
        HotkeyManager.shared.showQuickPanel()
    }

    private func openAccessibilitySettings() {
        let opened = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            .map { NSWorkspace.shared.open($0) } ?? false
        if !opened {
            ClipboardManager.shared.requestAccessibilityPermission()
        }
    }
}
