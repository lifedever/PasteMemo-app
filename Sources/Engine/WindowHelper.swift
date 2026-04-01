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
    let alert = NSAlert()
    alert.messageText = L10n.tr("accessibility.lost.title")
    alert.informativeText = L10n.tr("accessibility.lost.message")
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.tr("onboarding.accessibility.grant"))
    alert.addButton(withTitle: L10n.tr("accessibility.lost.later"))

    if alert.runModal() == .alertFirstButtonReturn {
        ClipboardManager.shared.requestAccessibilityPermission()
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
