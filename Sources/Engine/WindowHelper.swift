import Foundation
import AppKit

@MainActor
func showOnboardingWindow() {
    WindowManager.shared.show(
        id: "onboarding",
        title: L10n.tr("onboarding.welcome.title"),
        size: NSSize(width: 480, height: 380),
        floating: false,
        content: { OnboardingView() },
        onClose: { HotkeyManager.shared.register() }
    )
}

@MainActor
func showHelpWindow() {
    if let url = URL(string: "https://www.lifedever.com/PasteMemo/help/") {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
func showAccessibilityPrompt() {
    // Pre-1.6 users who upgraded via the buggy in-app updater are missing
    // PermissionFlow_PermissionFlow.bundle — accessing it via Bundle.module
    // would SIGTRAP. Degrade to a reinstall prompt instead. (issue #38)
    guard permissionFlowBundleAvailable() else {
        showReinstallRequiredAlert()
        return
    }

    let alert = NSAlert()
    alert.messageText = L10n.tr("accessibility.lost.title")
    alert.informativeText = L10n.tr("accessibility.lost.message")
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.tr("onboarding.accessibility.grant"))
    alert.addButton(withTitle: L10n.tr("accessibility.lost.later"))

    if alert.runModal() == .alertFirstButtonReturn {
        AccessibilityMonitor.shared.openAccessibilitySettings()
    }
}

private func permissionFlowBundleAvailable() -> Bool {
    let path = Bundle.main.bundleURL
        .appendingPathComponent("PermissionFlow_PermissionFlow.bundle").path
    return FileManager.default.fileExists(atPath: path)
}

@MainActor
private func showReinstallRequiredAlert() {
    let alert = NSAlert()
    alert.messageText = L10n.tr("reinstall.required.title")
    alert.informativeText = L10n.tr("reinstall.required.message")
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.tr("reinstall.required.action"))
    alert.addButton(withTitle: L10n.tr("accessibility.lost.later"))

    if alert.runModal() == .alertFirstButtonReturn,
       let url = URL(string: "https://www.lifedever.com/PasteMemo/download") {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
func showUpdateWindow(updater: UpdateChecker) {
    WindowManager.shared.show(
        id: "update",
        title: L10n.tr("update.available.title"),
        size: NSSize(width: 520, height: 460)
    ) {
        UpdateDialogView(updater: updater)
    }
}
