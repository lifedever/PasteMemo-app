import SwiftUI

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background {
                if #available(macOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .glassEffect(.regular, in: .rect(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.separator, lineWidth: 0.5)
                        )
                }
            }
    }
}
