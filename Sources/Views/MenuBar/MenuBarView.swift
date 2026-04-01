import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var proManager = ProManager.shared
    @ObservedObject private var hotkeyManager = HotkeyManager.shared
    @ObservedObject private var clipboardManager = ClipboardManager.shared

    var body: some View {
        let _ = storeOpenWindowAction()

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
            Button(L10n.tr("relay.startRelay")) {
                RelayManager.shared.activate()
            }
        }

        Divider()

        if !proManager.isPro {
            Button(L10n.tr("menu.upgrade")) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Button(L10n.tr("settings.automation.manage")) {
            AppAction.shared.openAutomationManager?()
        }

        Button(L10n.tr("menu.settings")) {
            NSApp.setActivationPolicy(.regular)
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
        AppAction.shared.openMainWindow = { [openWindow] in
            openWindow(id: "main")
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        AppAction.shared.openSettings = { [openSettings] in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        AppAction.shared.openAutomationManager = { [openWindow] in
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "automationManager")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func handleOpenMainWindow() {
        openWindow(id: "main")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleOpenQuickPanel() {
        QuickPanelWindowController.shared.show(
            clipboardManager: ClipboardManager.shared,
            modelContainer: PasteMemoApp.sharedModelContainer
        )
    }
}
