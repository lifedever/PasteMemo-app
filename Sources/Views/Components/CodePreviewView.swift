import SwiftUI
import AppKit

struct CodePreviewView: NSViewRepresentable {
    let code: String
    var language: CodeLanguage?
    var insets: NSSize = NSSize(width: 14, height: 14)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = insets
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        applyHighlighting(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        let appearance = NSApp.effectiveAppearance.name.rawValue
        let key = "\(code)-\(language?.rawValue ?? "")-\(appearance)"
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        applyHighlighting(textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var lastKey = ""
    }

    private func applyHighlighting(_ textView: NSTextView) {
        let lang = language ?? CodeDetector.detectLanguage(code) ?? .unknown
        let highlighted = SyntaxHighlighter.highlight(code, language: lang)
        textView.textStorage?.setAttributedString(highlighted)
    }
}
