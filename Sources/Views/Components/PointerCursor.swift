import SwiftUI
import AppKit

struct PointerCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    func pointerCursor() -> some View {
        modifier(PointerCursorModifier())
    }
}
