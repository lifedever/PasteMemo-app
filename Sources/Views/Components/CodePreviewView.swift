import SwiftUI
import AppKit

struct CodePreviewView: NSViewRepresentable {
    let code: String
    var language: CodeLanguage?
    var insets: NSSize = NSSize(width: 14, height: 14)
    var deferredHighlightDelayMs: Int? = nil
    var maximumHighlightedCharacters: Int? = nil

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
        context.coordinator.lastKey = viewKey(appearance: NSApp.effectiveAppearance.name.rawValue)
        applyInitialContent(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        let appearance = NSApp.effectiveAppearance.name.rawValue
        let key = viewKey(appearance: appearance)
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        applyInitialContent(textView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var lastKey = ""
        var highlightTask: Task<Void, Never>?
    }

    private func viewKey(appearance: String) -> String {
        "\(code)-\(language?.rawValue ?? "")-\(appearance)-\(deferredHighlightDelayMs ?? -1)-\(maximumHighlightedCharacters ?? -1)"
    }

    private func applyInitialContent(_ textView: NSTextView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let lang = language ?? CodeDetector.detectLanguage(code) ?? .unknown
        let plainText = SyntaxHighlighter.highlightOffMain(code, language: lang, isDark: isDark)

        if let maximumHighlightedCharacters, code.count > maximumHighlightedCharacters {
            textView.textStorage?.setAttributedString(plainText)
            return
        }

        if let cached = SyntaxHighlighter.cachedHighlight(code, language: lang, isDark: isDark) {
            textView.textStorage?.setAttributedString(cached)
            return
        }

        textView.textStorage?.setAttributedString(plainText)

        let delayMs = deferredHighlightDelayMs ?? 0
        coordinator.highlightTask = Task { @MainActor in
            if delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled else { return }
            }
            let highlighted = await SyntaxHighlighter.highlightAsync(code, language: lang, isDark: isDark)
            guard !Task.isCancelled else { return }
            textView.textStorage?.setAttributedString(highlighted)
        }
    }
}
