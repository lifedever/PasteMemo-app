import SwiftUI

struct SensitiveMask<Content: View>: View {
    @State private var isRevealed = false
    private let content: () -> Content
    private var isOptionPressed: Bool { OptionKeyMonitor.shared.isOptionPressed }

    private static var AUTO_HIDE_SECONDS: TimeInterval { 30 }

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        if isRevealed || isOptionPressed {
            revealedView
        } else {
            maskedView
        }
    }

    private var maskedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange.opacity(0.6))

            Text(L10n.tr("sensitive.masked"))
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Text(L10n.tr("sensitive.optionHint"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Button {
                isRevealed = true
            } label: {
                Label(L10n.tr("sensitive.reveal"), systemImage: "eye")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var revealedView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isRevealed {
                HStack {
                    Spacer()
                    Button { isRevealed = false } label: {
                        Label(L10n.tr("sensitive.hide"), systemImage: "eye.slash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            content()
        }
        .task(id: isRevealed) {
            guard isRevealed else { return }
            try? await Task.sleep(for: .seconds(Self.AUTO_HIDE_SECONDS))
            isRevealed = false
        }
    }
}
