import AppKit
import SwiftUI

// MARK: - Bridge for SwiftUI → AppKit window actions

@MainActor
final class AppAction {
    static let shared = AppAction()
    var openMainWindow: (() -> Void)?
    var openSettings: (() -> Void)?
    var openAutomationManager: (() -> Void)?
    var showNewSnippetWindow: (() -> Void)?
    private init() {}
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shouldReallyQuit = false
    private var isLaunchComplete = false

    override init() {
        super.init()
        NSApp?.setActivationPolicy(.accessory)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
        AppDelegate.applyAppearance(mode)

        ClipboardManager.shared.modelContainer = PasteMemoApp.sharedModelContainer
        OCRTaskCoordinator.shared.configure(modelContainer: PasteMemoApp.sharedModelContainer)
        if ProManager.AUTOMATION_ENABLED {
            BuiltInRules.seedIfNeeded(context: PasteMemoApp.sharedModelContainer.mainContext)
        }
        ClipboardManager.shared.startMonitoring()
        UsageTracker.pingIfNeeded()

        // Hide SwiftUI auto-created windows
        hideAllMainWindows(NSApp)
        isLaunchComplete = true

        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let needsAccessibility = !AXIsProcessTrusted()

        HotkeyManager.shared.register()

        // Wire Relay Mode protocols
        RelayManager.shared.clipboardController = ClipboardManager.shared
        RelayManager.shared.hotkeyController = HotkeyManager.shared

        if !hasCompletedOnboarding {
            let hideDock = UserDefaults.standard.bool(forKey: "hideDockIcon")
            if !hideDock {
                NSApp.setActivationPolicy(.regular)
            }
            showOnboardingWindow()
        } else if needsAccessibility {
            let hideDock = UserDefaults.standard.bool(forKey: "hideDockIcon")
            if !hideDock {
                NSApp.setActivationPolicy(.regular)
            }
            showAccessibilityPrompt()
        }

        Task {
            await UpdateChecker.shared.checkForUpdates()
            UpdateChecker.shared.startPeriodicChecks()
        }

        BackupScheduler.shared.start(container: PasteMemoApp.sharedModelContainer)

        // Pre-warm quick panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            QuickPanelWindowController.shared.warmUp(
                clipboardManager: ClipboardManager.shared,
                modelContainer: PasteMemoApp.sharedModelContainer
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackupScheduler.shared.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppDelegate.shouldReallyQuit else {
            hideAllMainWindows(sender)
            NSApp.setActivationPolicy(.accessory)
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        AppAction.shared.openMainWindow?()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if isLaunchComplete {
            NSApp.setActivationPolicy(.accessory)
        }
        return false
    }

    // MARK: - Helpers

    private func hideAllMainWindows(_ sender: NSApplication) {
        for window in sender.windows where window.isVisible && window.canBecomeMain {
            window.close()
        }
    }

    static func applyAppearance(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

}
