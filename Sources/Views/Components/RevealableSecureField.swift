import SwiftUI

/// Standard passphrase field with press-and-hold peek (macOS convention).
struct RevealableSecureField: View {
    @Binding var text: String
    @State private var isPeeking = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isPeeking {
                    TextField("", text: $text)
                } else {
                    SecureField("", text: $text)
                }
            }
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: .infinity)

            Image(systemName: "eye")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .onLongPressGesture(minimumDuration: 0, pressing: { pressing in
                    isPeeking = pressing
                }, perform: {})
                .pointerCursor()
                .help(L10n.tr("sync.encryption.passphrase.reveal"))
                .accessibilityLabel(L10n.tr("sync.encryption.passphrase.reveal"))
        }
    }
}
