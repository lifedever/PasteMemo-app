import AppKit
import SwiftUI

/// Progress + result UI for the top-menu Import action. The Settings panel has
/// its own integrated sheet; this coordinator backs the menu path with a
/// dedicated NSPanel that hosts a single SwiftUI view going through three
/// phases — running → success/failure → dismissed. The result phases live in
/// the same panel so the user doesn't have to chase a transient sheet then a
/// follow-up alert.
@MainActor
@Observable
final class ImportProgressCoordinator {
    static let shared = ImportProgressCoordinator()

    enum Phase {
        case running
        case success(ImportResult)
        case failure(message: String)
    }

    var title: String = ""
    var statusText: String = ""
    var value: Double = 0
    var phase: Phase = .running

    private var panel: NSPanel?

    private init() {}

    func start(title: String, initialStatus: String) {
        self.title = title
        self.statusText = initialStatus
        self.value = 0
        self.phase = .running
        showPanelIfNeeded()
    }

    func updateProgress(current: Int, total: Int) {
        statusText = "\(current) / \(total)"
        value = total > 0 ? Double(current) / Double(total) : 0
    }

    /// Switch to an indeterminate stage (spinner instead of % bar) — use for
    /// crypto / decode / post-import refresh where there's no measurable %.
    func setIndeterminateStage(_ status: String) {
        statusText = status
        value = 0
    }

    func showSuccess(result: ImportResult) {
        phase = .success(result)
    }

    func showFailure(message: String) {
        phase = .failure(message: message)
    }

    /// Called by the in-panel close button. Don't auto-dismiss on import
    /// completion — the result phase is the point of the panel.
    func dismiss() {
        panel?.close()
        panel = nil
    }

    private func showPanelIfNeeded() {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // .titled only — no close button so the user can't dismiss mid-import.
        // The success/failure phase renders its own "确定" button.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ImportProgressView(coordinator: self))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }
}

private struct ImportProgressView: View {
    let coordinator: ImportProgressCoordinator

    var body: some View {
        Group {
            switch coordinator.phase {
            case .running:
                runningView
            case .success(let result):
                successView(result: result)
            case .failure(let message):
                failureView(message: message)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var runningView: some View {
        VStack(spacing: 16) {
            Text(coordinator.title)
                .font(.headline)
            if coordinator.value > 0 && coordinator.value < 1.0 {
                ProgressView(value: coordinator.value, total: 1.0)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Text(coordinator.statusText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func successView(result: ImportResult) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text(L10n.tr("dataPorter.importSuccess"))
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("dataPorter.summary.imported", result.imported))
                Text(L10n.tr("dataPorter.summary.skipped", result.skipped))
                if result.importedGroups > 0 {
                    Text(L10n.tr("dataPorter.summary.newGroups", result.importedGroups))
                }
                if result.importedRules > 0 {
                    Text(L10n.tr("dataPorter.summary.newRules", result.importedRules))
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            Button(L10n.tr("action.confirm")) { coordinator.dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
            Button(L10n.tr("action.confirm")) { coordinator.dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
