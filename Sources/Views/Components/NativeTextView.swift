import SwiftUI
import AppKit

struct NativeTextView: NSViewRepresentable {
    let text: String
    var richTextData: Data?
    var richTextType: String?
    var isEditable: Bool = false
    var onTextChange: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.delegate = context.coordinator
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = isEditable
        context.coordinator.onTextChange = onTextChange

        let isFirstResponder = textView.window?.firstResponder == textView
        guard !isFirstResponder else { return }

        if let rtfData = richTextData {
            let currentRTF = context.coordinator.lastRichTextData
            guard rtfData != currentRTF else { return }
            context.coordinator.lastRichTextData = rtfData
            if let attrString = attributedString(from: rtfData) {
                textView.textStorage?.setAttributedString(attrString)
            } else {
                textView.string = text
            }
        } else {
            context.coordinator.lastRichTextData = nil
            if textView.string != text {
                textView.string = text
            }
        }
    }

    private func attributedString(from data: Data) -> NSAttributedString? {
        let raw: NSAttributedString?
        if richTextType == "html" {
            raw = NSAttributedString(html: data, documentAttributes: nil)
        } else {
            raw = NSAttributedString(rtf: data, documentAttributes: nil)
        }
        guard let raw else { return nil }
        return adaptColorsForAppearance(raw)
    }

    private func adaptColorsForAppearance(_ source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: result.length)

        result.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            guard let color = value as? NSColor else {
                result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                return
            }
            if isNearBlackOrWhite(color) {
                result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        return result
    }

    private func isNearBlackOrWhite(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let brightness = rgb.redComponent * 0.299 + rgb.greenComponent * 0.587 + rgb.blueComponent * 0.114
        return brightness < 0.15 || brightness > 0.85
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: ((String) -> Void)?
        var lastRichTextData: Data?

        init(onTextChange: ((String) -> Void)?) {
            self.onTextChange = onTextChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange?(textView.string)
        }
    }
}
