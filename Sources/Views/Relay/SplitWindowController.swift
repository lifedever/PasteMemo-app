import AppKit
import SwiftUI

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Singleton controller for the split-to-queue window.
/// All entry points (main window, quick panel, relay panel) call this.
@MainActor
final class SplitWindowController {

    static let shared = SplitWindowController()

    private var window: NSPanel?
    private var hostingController: NSHostingController<AnyView>?

    private init() {}

    func show(text: String, onSplit: @escaping (RelayDelimiter) -> Void) {
        dismiss()

        let content = SplitContentView(text: text, onSplit: { [weak self] delimiter in
            onSplit(delimiter)
            self?.dismiss()
        }, onCancel: { [weak self] in
            self?.dismiss()
        })

        let hosting = NSHostingController(rootView: AnyView(content))
        hosting.sizingOptions = .preferredContentSize
        hostingController = hosting

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 300))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        let visualEffect = NSVisualEffectView(frame: container.bounds)
        visualEffect.material = .windowBackground
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]
        container.addSubview(visualEffect)

        let hostingView = hosting.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = container

        // Observe size changes
        let observation = hosting.observe(\.preferredContentSize, options: [.new, .initial]) { [weak panel] controller, _ in
            Task { @MainActor in
                guard let panel else { return }
                let size = controller.preferredContentSize
                guard size.height > 0 else { return }
                var frame = panel.frame
                let newHeight = min(size.height, 500)
                frame.origin.y -= (newHeight - frame.height)
                frame.size.height = newHeight
                frame.size.width = 340
                panel.setFrame(frame, display: true)
            }
        }
        // Store observation to keep it alive
        objc_setAssociatedObject(panel, "sizeObservation", observation, .OBJC_ASSOCIATION_RETAIN)

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.window = panel
    }

    func dismiss() {
        window?.close()
        window = nil
        hostingController = nil
    }
}

// MARK: - Split Content View

private struct SplitContentView: View {
    let text: String
    let onSplit: (RelayDelimiter) -> Void
    let onCancel: () -> Void
    @State private var customDelimiter = ""
    @State private var selectedDelimiter: RelayDelimiter = .newline

    private var resolvedDelimiter: RelayDelimiter {
        if case .custom = selectedDelimiter { return .custom(customDelimiter) }
        return selectedDelimiter
    }

    private var canSplit: Bool {
        RelaySplitter.split(text, by: resolvedDelimiter) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("relay.split.title"))
                .font(.system(size: 15, weight: .semibold))

            // Preview box
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let parts = RelaySplitter.split(text, by: resolvedDelimiter) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                            HStack(spacing: 6) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 16, alignment: .trailing)
                                Text(part.replacingOccurrences(of: "\n", with: " ↵ "))
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                        }
                    } else {
                        Text(text)
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            // Delimiter picker
            HStack {
                Text(L10n.tr("relay.split.delimiter"))
                    .font(.system(size: 13))
                Picker("", selection: $selectedDelimiter) {
                    ForEach(RelaySplitter.PRESET_DELIMITERS, id: \.self) { d in
                        Text(L10n.tr(d.displayName)).tag(d)
                    }
                    Text(L10n.tr("relay.delimiter.custom")).tag(RelayDelimiter.custom(""))
                }
                .labelsHidden()
                .frame(width: 120)
            }

            if case .custom = selectedDelimiter {
                TextField(L10n.tr("relay.split.customPlaceholder"), text: $customDelimiter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
            }

            if let parts = RelaySplitter.split(text, by: resolvedDelimiter) {
                Text(L10n.tr("relay.split.preview", parts.count))
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
            } else {
                Text(L10n.tr("relay.split.noResult"))
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }

            HStack {
                Button(L10n.tr("action.cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("relay.split.confirm")) { onSplit(resolvedDelimiter) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSplit)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Color.clear)
    }
}
