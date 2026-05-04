import SwiftUI
import AppKit

struct NativeTextView: NSViewRepresentable {
    let text: String
    var richTextData: Data?
    var richTextType: String?
    /// When false, the view shows `text` (plain string) only and skips all rich-text decoding.
    /// Callers use this to avoid paying the RTFD/HTML cost during rapid selection changes
    /// (e.g. arrow-key scrubbing in QuickPanel). Pass true once the selection settles.
    var allowRichRender: Bool = true
    /// Stable identifier for caching decoded rich-text results across view recreations.
    /// When provided, decoded NSAttributedString is keyed on `(itemID, dataHash, width)`.
    var itemID: String? = nil
    var isEditable: Bool = false
    var autoFocus: Bool = false
    var onTextChange: ((String) -> Void)?
    var onEscape: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange, onEscape: onEscape)
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
        // Horizontal scroll must stay off so that text/images wrap to the container width.
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        if autoFocus {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = isEditable
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onEscape = onEscape

        let isFirstResponder = textView.window?.firstResponder == textView
        guard !isFirstResponder else { return }

        // Fast path: rich render disabled OR no rich data — render plain string only, skip all decoding.
        guard allowRichRender, let rtfData = richTextData else {
            let wasRich = context.coordinator.lastRichTextData != nil
            context.coordinator.lastRichTextData = nil
            context.coordinator.lastLayoutWidth = 0
            if wasRich {
                // Switching from rich → plain on the same view: setting
                // `.string` only replaces the characters and keeps the prior
                // attributed run's typing attributes (bold/colors/font), so
                // the visual still looks formatted. Force a fully attributed
                // overwrite with the default plain attrs to clear all
                // inherited formatting.
                let plain = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor,
                ])
                textView.textStorage?.setAttributedString(plain)
            } else if textView.string != text {
                textView.string = text
            }
            return
        }

        let currentWidth = textView.textContainer?.size.width ?? 0
        let widthChanged = abs(currentWidth - context.coordinator.lastLayoutWidth) > 1
        let dataChanged = rtfData != context.coordinator.lastRichTextData
        guard dataChanged || widthChanged else { return }

        // Serve from cache instantly if we've decoded the same (itemID, data, width) combo recently.
        if let id = itemID,
           let cached = RichTextCache.shared.get(itemID: id, data: rtfData, width: currentWidth) {
            context.coordinator.lastRichTextData = rtfData
            context.coordinator.lastLayoutWidth = currentWidth
            textView.textStorage?.setAttributedString(cached)
            return
        }

        // Show the plain string immediately so the viewport isn't blank while we decode.
        if textView.string.isEmpty || dataChanged {
            textView.string = text
        }
        context.coordinator.lastRichTextData = rtfData
        context.coordinator.lastLayoutWidth = currentWidth

        // Decode off the main thread — RTFD with large inline images can take 100ms+.
        // Only Sendable values (Data, String?, CGFloat) cross into Task.detached; the
        // NSTextView/Coordinator references stay on the MainActor side.
        let typeLocal = richTextType
        let itemIDLocal = itemID
        let dataLocal = rtfData
        let widthLocal = currentWidth
        let coordinator = context.coordinator
        let token = coordinator.beginDecodeToken()
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        Task { @MainActor in
            // NSAttributedString isn't Sendable in Swift 6, but we're only ever moving the
            // reference from one detached decode task to this single MainActor consumer — wrap
            // in an unchecked box so the compiler is satisfied.
            let box = await Task.detached(priority: .userInitiated) {
                UnsafeSendableBox(Self.decode(data: dataLocal, type: typeLocal, maxImageWidth: widthLocal, isDark: isDark))
            }.value
            guard let attr = box.value else { return }
            guard coordinator.isCurrentDecodeToken(token) else { return }
            // Selection changed meanwhile — discard.
            guard coordinator.lastRichTextData == dataLocal else { return }
            if let id = itemIDLocal {
                RichTextCache.shared.set(itemID: id, data: dataLocal, width: widthLocal, value: attr)
            }
            textView.textStorage?.setAttributedString(attr)
        }
    }

    // MARK: - Decoding (nonisolated: safe on background)

    nonisolated private static func decode(data: Data, type: String?, maxImageWidth: CGFloat, isDark: Bool) -> NSAttributedString? {
        let raw: NSAttributedString?
        switch type {
        case "rtfd":
            raw = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
            )
        case "html":
            raw = NSAttributedString(html: data, documentAttributes: nil)
        default:
            raw = NSAttributedString(rtf: data, documentAttributes: nil)
        }
        guard let raw else { return nil }
        let adapted = adaptColorsForAppearance(raw, isDark: isDark)
        return scaleAttachmentsToFit(adapted, maxWidth: maxImageWidth)
    }

    /// Responsive images: shrink attachments whose intrinsic width exceeds the text container.
    /// Preserves aspect ratio. Leaves narrower images at natural size.
    nonisolated private static func scaleAttachmentsToFit(_ source: NSAttributedString, maxWidth: CGFloat) -> NSAttributedString {
        guard maxWidth > 1 else { return source }
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: result.length)
        // Leave a little breathing room so the scroll indicator / insets don't clip.
        let targetWidth = max(40, maxWidth - 8)

        result.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let intrinsic = intrinsicSize(of: attachment)
            guard intrinsic.width > 0, intrinsic.height > 0 else { return }
            guard intrinsic.width > targetWidth else {
                // Natural size fits — honor the source dimensions.
                attachment.bounds = CGRect(origin: .zero, size: intrinsic)
                return
            }
            let scale = targetWidth / intrinsic.width
            attachment.bounds = CGRect(
                x: 0, y: 0,
                width: targetWidth,
                height: (intrinsic.height * scale).rounded()
            )
            _ = range
        }
        return result
    }

    nonisolated private static func intrinsicSize(of attachment: NSTextAttachment) -> CGSize {
        if let image = attachment.image {
            return image.size
        }
        if let wrapper = attachment.fileWrapper,
           let data = wrapper.regularFileContents,
           let image = NSImage(data: data) {
            // Cache so subsequent layout passes don't re-decode.
            attachment.image = image
            return image.size
        }
        return attachment.bounds.size
    }

    nonisolated private static func adaptColorsForAppearance(_ source: NSAttributedString, isDark: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: result.length)

        // Strip source backgroundColor across the whole string — the preview
        // uses the panel's own material background; dragging in black/gray
        // backgrounds from the source makes text unreadable on dark mode.
        result.removeAttribute(.backgroundColor, range: fullRange)

        result.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            guard let color = value as? NSColor else {
                result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                return
            }
            if shouldAdaptForegroundColor(color, isDark: isDark) {
                result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        return result
    }

    nonisolated private static func shouldAdaptForegroundColor(_ color: NSColor, isDark: Bool) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let brightness = rgb.redComponent * 0.299 + rgb.greenComponent * 0.587 + rgb.blueComponent * 0.114
        // Near-black or near-white: always adapt.
        if brightness < 0.15 || brightness > 0.85 { return true }
        // Mid-grey on dark / light panel — low contrast, swap to label color.
        if isDark, brightness < 0.40 { return true }
        if !isDark, brightness > 0.70 { return true }
        return false
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: ((String) -> Void)?
        var onEscape: (() -> Void)?
        var lastRichTextData: Data?
        var lastLayoutWidth: CGFloat = 0
        private var decodeToken: Int = 0

        init(onTextChange: ((String) -> Void)?, onEscape: (() -> Void)? = nil) {
            self.onTextChange = onTextChange
            self.onEscape = onEscape
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), let onEscape {
                onEscape()
                return true
            }
            return false
        }

        /// Increment-and-return used to invalidate in-flight decodes when selection changes.
        func beginDecodeToken() -> Int {
            decodeToken &+= 1
            return decodeToken
        }

        func isCurrentDecodeToken(_ token: Int) -> Bool {
            decodeToken == token
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange?(textView.string)
        }
    }
}

/// Single-use box to pass non-Sendable values between tasks when we know by construction that
/// the value is only accessed by one isolation domain at a time.
private struct UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Rich-text render cache

/// LRU cache of decoded NSAttributedString keyed on (itemID, data hash, container width).
/// Saves 100ms+ per arrow-key navigation through RTFD-heavy items.
@MainActor
final class RichTextCache {
    static let shared = RichTextCache()

    private struct Key: Hashable {
        let itemID: String
        let dataHash: Int
        let width: Int  // rounded to reduce cache key churn from sub-pixel width drift
    }

    private var cache: [Key: NSAttributedString] = [:]
    private var order: [Key] = []
    private let capacity = 20

    func get(itemID: String, data: Data, width: CGFloat) -> NSAttributedString? {
        let key = Key(itemID: itemID, dataHash: data.hashValue, width: Int(width))
        guard let value = cache[key] else { return nil }
        // Mark as most recently used.
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return value
    }

    func set(itemID: String, data: Data, width: CGFloat, value: NSAttributedString) {
        let key = Key(itemID: itemID, dataHash: data.hashValue, width: Int(width))
        if cache[key] == nil {
            order.append(key)
        } else if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        cache[key] = value
        while order.count > capacity {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    func invalidate(itemID: String) {
        let keysToRemove = cache.keys.filter { $0.itemID == itemID }
        for key in keysToRemove {
            cache.removeValue(forKey: key)
            if let idx = order.firstIndex(of: key) {
                order.remove(at: idx)
            }
        }
    }
}
