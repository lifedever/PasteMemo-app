import AppKit
import ImageIO
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private let CLIPBOARD_POLL_INTERVAL: TimeInterval = 0.5
private let PASTE_SIMULATION_DELAY: Duration = .milliseconds(30)
/// Long edge of the thumbnail we generate for file-based image clips. Stored
/// in `imageData` for UI preview only; paste writes the original file URL so
/// target apps read full-resolution from disk. 1024 keeps the detail-view
/// preview sharp on Retina without storing the full original (which can be
/// hundreds of MB for RAW/TIFF). JPEG @ 0.85 typically lands at 200–800 KB
/// per clip — 1000 such clips ≈ 500 MB of blob storage, manageable.
private let FILE_THUMBNAIL_MAX_PIXELS: Int = 1024
/// Largest source-file size we'll re-read at paste time to provide image bytes
/// to targets that can't follow a file URL (Claude Code, Electron apps, Slack,
/// etc.). Beyond this, paste only delivers the file URL — file-savvy targets
/// still work, pixel-only targets get nothing rather than triggering OOM.
private let MAX_PASTE_FILE_BYTES: Int = 200 * 1024 * 1024

@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    var lastChangeCount: Int = 0
    private var timer: Timer?
    var modelContainer: ModelContainer?

    private static let MONITORING_ENABLED_KEY = "clipboardMonitoringEnabled"

    @Published var isMonitoringEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMonitoringEnabled, forKey: Self.MONITORING_ENABLED_KEY)
            applyMonitoringState()
        }
    }

    @Published private(set) var isTemporarilyPaused: Bool = false {
        didSet { applyMonitoringState() }
    }

    var isPaused: Bool { !isMonitoringEnabled || isTemporarilyPaused }

    // Track app switches to determine the real source app
    private var appBeforeSwitch: (name: String?, bundleID: String?) = (nil, nil)
    private var lastSwitchTime: Date = .distantPast
    private var appSwitchObserver: Any?
    private static let APP_SWITCH_THRESHOLD: TimeInterval = 1.0

    private init() {
        let stored = UserDefaults.standard.object(forKey: Self.MONITORING_ENABLED_KEY) as? Bool
        self.isMonitoringEnabled = stored ?? true

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = UserDefaults.standard.object(forKey: Self.MONITORING_ENABLED_KEY) as? Bool ?? true
                if current != self.isMonitoringEnabled {
                    self.isMonitoringEnabled = current
                }
            }
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        lastChangeCount = NSPasteboard.general.changeCount
        startAppSwitchTracking()
        timer = Timer.scheduledTimer(withTimeInterval: CLIPBOARD_POLL_INTERVAL, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
    }

    private func applyMonitoringState() {
        if isPaused {
            stopMonitoring()
        } else if timer == nil {
            startMonitoring()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

    private func startAppSwitchTracking() {
        guard appSwitchObserver == nil else { return }
        appBeforeSwitch = frontmostAppInfo()
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = self.frontmostAppInfo()
                let currentBundleID = current.bundleID ?? ""
                let previousBundleID = self.appBeforeSwitch.bundleID ?? ""
                if currentBundleID != previousBundleID {
                    self.lastSwitchTime = Date()
                }
                self.appBeforeSwitch = current
            }
        }
    }

    func togglePause() {
        isMonitoringEnabled.toggle()
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        // Defensive fallback: even if `lastChangeCount` was knocked out of sync by a
        // third-party clipboard manager writing between our setData and our baseline
        // update, the self-write marker still identifies this change as ours and we
        // skip capturing a duplicate history entry.
        if pasteboard.isPasteMemoWrite { return }
        captureAndSave()
    }

    // MARK: - Capture

    private func captureAndSave() {
        guard let container = modelContainer else { return }
        // Skip content marked as transient, concealed, or auto-generated (nspasteboard.org)
        // Also skip app-specific sensitive types (1Password, KeeWeb, TypeIt4Me)
        let pasteboardTypes = NSPasteboard.general.types ?? []
        let sensitiveTypes: [NSPasteboard.PasteboardType] = [
            .init("org.nspasteboard.TransientType"),
            .init("org.nspasteboard.ConcealedType"),
            .init("org.nspasteboard.AutoGeneratedType"),
            .init("de.petermaurer.TransientPasteboardType"),
            .init("com.agilebits.onepassword"),
            .init("net.antelle.keeweb"),
            .init("com.typeit4me.clipping")
        ]
        if pasteboardTypes.contains(where: { sensitiveTypes.contains($0) }) {
            return
        }
        // If an app switch happened very recently, the copy likely came from the previous app
        let appInfo: (name: String?, bundleID: String?)
        if Date().timeIntervalSince(lastSwitchTime) < Self.APP_SWITCH_THRESHOLD,
           appBeforeSwitch.bundleID != nil {
            appInfo = appBeforeSwitch
        } else {
            appInfo = frontmostAppInfo()
        }
        if let bundleID = appInfo.bundleID, IgnoredAppsManager.shared.isIgnored(bundleID) { return }
        guard let newItem = captureCurrentClipboard(sourceApp: appInfo.name) else { return }
        newItem.sourceAppBundleID = appInfo.bundleID

        newItem.isSensitive = SensitiveDetector.isSensitive(
            content: newItem.content, sourceAppBundleID: appInfo.bundleID, contentType: newItem.contentType
        )

        // 来自 MCP `clipboard_set` 写入时,SetClipboardTool 会把 clientInfo.name 当作 marker
        // 附加到 pasteboard(同 PasteMemoMarker 那种自定义 UTI 模式)。这里捞一下,把 AI Agent
        // 来源名持久化到 ClipItem.agentSource,后续侧栏 / 详情面板就能识别。
        if let agent = NSPasteboard.general.string(forType: .agentSource), !agent.isEmpty {
            newItem.agentSource = agent
        }

        let context = container.mainContext

        // Apply automation rules (text-based content only)
        if newItem.contentType.isMergeable {
            let result = AutomationEngine.shared.process(
                content: newItem.content,
                contentType: newItem.contentType,
                sourceApp: appInfo.bundleID,
                context: context
            )
            switch result {
            case .unchanged:
                break
            case .applied(let processed, _, let actions):
                if actions.contains(.skipCapture) { return }
                applyAutomationActions(actions, processed: processed, to: newItem, context: context)
            case .pendingConfirmation(let processed, let ruleName, _, let actions):
                let accepted = showAutomationConfirmation(
                    ruleName: ruleName, original: newItem.content, processed: processed
                )
                if accepted {
                    if actions.contains(.skipCapture) { return }
                    applyAutomationActions(actions, processed: processed, to: newItem, context: context)
                }
            }
        }

        if isLatestDuplicate(newItem, in: context) { return }

        if let existingItem = findExistingDuplicate(for: newItem, in: context) {
            reuseExistingDuplicate(existingItem, with: newItem, in: context)
            cleanExpiredItems(in: context)
            ClipItemStore.saveAndNotify(context)
            SoundManager.playCopy()
            refreshLinkMetadataIfNeeded(for: existingItem, in: context)
            enqueueOCRIfNeeded(for: existingItem)
            return
        }

        context.insert(newItem)
        cleanExpiredItems(in: context)
        ClipItemStore.saveAndNotify(context)

        SoundManager.playCopy()

        refreshLinkMetadataIfNeeded(for: newItem, in: context)
        enqueueOCRIfNeeded(for: newItem)
    }

    func captureCurrentClipboard(sourceApp: String? = nil) -> ClipItem? {
        let pasteboard = NSPasteboard.general

        // Parallel capture of every independent representation on the pasteboard.
        // `richText` is attached to text (not counted as an independent representation for .mixed judgement).
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        // Cover the four standard image UTIs so iPhone photos (HEIC), Safari drags
        // (often JPEG), and classic screenshots (PNG/TIFF) all get recognised as
        // images rather than falling through to the file / unknown path.
        let rawImageData = capturePasteboardImage(from: pasteboard)
        let rawText = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let richText = captureRichTextData(from: pasteboard)

        let hasFiles = !fileURLs.isEmpty
        let rawHasImage = rawImageData != nil
        let hasRawText = rawText != nil && !(rawText!.isEmpty)

        // Take a full pasteboard snapshot whenever the source exposed rich content OR any
        // third-party custom UTI (e.g. Telegram's `com.trolltech.anymime.*` which carries
        // custom-emoji metadata that is invisible to the plain-text path). Replaying these
        // bytes via `restorePasteboardSnapshot` is the only way the origin app can decode
        // its own custom payload after PasteMemo hands the clip back. Plain-text /
        // plain-image / plain-file clips skip this to keep the database lean.
        let hasCustomTypes = pasteboardHasThirdPartyTypes(pasteboard)
        let snapshot: Data? = (richText.data != nil || hasCustomTypes)
            ? capturePasteboardSnapshot(from: pasteboard)
            : nil

        // File URLs only (copied files/folders from Finder)
        if hasFiles {
            let paths = fileURLs.map(\.path)
            let content = paths.joined(separator: "\n")
            let fileType = detectFileType(paths)
            // For single image files, generate a small thumbnail for UI preview only.
            // Paste writes the original file URL — target apps read full resolution
            // from disk, so storing the original bytes here would just bloat the DB
            // (RAW exports / TIFFs can be GBs) and the next backup encode pass.
            var imageData: Data?
            if fileType == .image, paths.count == 1 {
                imageData = Self.generateImageFileThumbnail(at: fileURLs[0])
            }
            return ClipItem(content: content, contentType: fileType, imageData: imageData, sourceApp: sourceApp)
        }

        // Rich-text content (browser, Word, Excel, Notes, TextEdit, ...) — prefer the text
        // path so we retain RTFD/HTML/RTF. The raw PNG that some sources expose alongside
        // (e.g. Excel rendering the selection as an image) is redundant for preview — the
        // rich text already conveys the content — and the pasteboard snapshot preserves it
        // byte-for-byte for paste-back.
        if hasRawText, richText.data != nil {
            let content = rawText!
            var detected = detectContentType(content)
            // Rich text sources are prose, not code — skip code-language detection which would
            // otherwise misread `--` / `->` as SQL/code.
            if detected.type == .code {
                detected = DetectedContent(type: .text, language: nil)
            }
            return ClipItem(
                content: content, contentType: detected.type,
                sourceApp: sourceApp, codeLanguage: detected.language,
                richTextData: richText.data, richTextType: richText.type,
                pasteboardSnapshot: snapshot
            )
        }

        // Image only (screenshots, copy image from apps that don't expose a file URL)
        if rawHasImage {
            return ClipItem(content: "[Image]", contentType: .image, imageData: rawImageData, sourceApp: sourceApp)
        }

        // Plain text (no rich formatting). Still attach the snapshot when the source wrote
        // custom UTIs alongside (Telegram custom emoji, Qt-based apps, etc.) so paste-back
        // to the origin restores the hidden payload.
        guard let content = rawText, !content.isEmpty else { return nil }
        let detected = detectContentType(content)
        // Pre-decode `data:image/...;base64,` URIs into `imageData` so the row,
        // preview pane, and properties panel can render from a normal image bytes
        // representation instead of re-decoding the multi-megabyte string on every
        // access. The original URI string stays in `content` so paste-back returns
        // exactly what the user copied.
        let dataURIImageData: Data? = (detected.type == .link && DataImageURI.isBase64DataImageURI(content))
            ? DataImageURI.decodedImageData(from: content)
            : nil
        return ClipItem(
            content: content, contentType: detected.type,
            imageData: dataURIImageData,
            sourceApp: sourceApp, codeLanguage: detected.language,
            pasteboardSnapshot: snapshot
        )
    }

    /// Returns true if the pasteboard carries at least one UTI whose prefix isn't in the
    /// Apple-standard set (`public.*`, `com.apple.*`, `NS*`, `CorePasteboardFlavorType`).
    /// Those third-party types are where apps like Telegram, Sketch, Figma stash custom
    /// payloads (emoji IDs, shape metadata, etc.) that only the origin can decode.
    func pasteboardHasThirdPartyTypes(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains { type in
            let raw = type.rawValue
            if raw.hasPrefix("public.") { return false }
            if raw.hasPrefix("com.apple.") { return false }
            if raw.hasPrefix("NS") { return false }
            if raw.hasPrefix("CorePasteboardFlavorType") { return false }
            return true
        }
    }

    private static let FLAT_RTFD_TYPE = NSPasteboard.PasteboardType("com.apple.flat-rtfd")
    /// Upper bound on the total bytes we'll persist in a single pasteboard snapshot.
    /// Protects the database from pathological clipboards (huge embedded PDFs, etc.).
    private static let MAX_SNAPSHOT_BYTES = 50 * 1024 * 1024
    /// Skip raw image clips above this size (un-encoded pasteboard PNG/JPEG/HEIC/TIFF bytes).
    /// 20 MB covers any reasonable screenshot or app-rendered image; pathologically large
    /// clipboards (Photoshop selections, RAW exports) get dropped to keep DB and backup
    /// memory bounded.
    private static let MAX_IMAGE_BYTES = 20 * 1024 * 1024
    /// Skip rich-text clips above this size. RTFD with embedded images can balloon to GBs.
    private static let MAX_RICHTEXT_BYTES = 50 * 1024 * 1024
    // MAX_PASTE_FILE_BYTES lives at file scope (see top of file) so the nonisolated
    // helper that re-reads originals can use it without crossing actors.
    // FILE_THUMBNAIL_MAX_PIXELS lives at file scope (see top of file) so the
    // nonisolated thumbnail helper can read it without crossing actors.

    /// Office-internal UTI prefixes that we never want on the pasteboard when PasteMemo
    /// writes back. Word paste hijacks into its private internal clipboard whenever any
    /// `com.microsoft.*` type is present and ignores NSPasteboard — so every paste
    /// replays whatever Word last copied itself instead of our content (issue #28).
    /// Maccy, the most popular OSS macOS clipboard manager, takes the same approach.
    /// Stripping here is harmless for non-Word targets (they ignore these types) and
    /// essential for Word: without the MS types, Word falls back to the standard
    /// `public.rtf` / `public.html` path. Bold / color / font size survive; only
    /// Word-internal object references are lost.
    private static let OFFICE_PRIVATE_TYPE_PREFIXES: [String] = [
        "com.microsoft."
    ]

    /// Returns true when the given UTI is an Office-private type that would trigger
    /// Word's internal-clipboard hijack.
    private static func isOfficePrivateType(_ rawType: String) -> Bool {
        OFFICE_PRIVATE_TYPE_PREFIXES.contains { rawType.hasPrefix($0) }
    }

    /// Captures every type on the pasteboard as a binary-plist dictionary. Returns nil if
    /// nothing readable is available, or if the total size exceeds MAX_SNAPSHOT_BYTES.
    /// Replaying this via `restorePasteboardSnapshot` reproduces the original pasteboard
    /// verbatim — that's how we achieve system-native paste in rich-content apps (Word,
    /// Mail, browsers, Notes) that pick UTIs outside the small set we decode ourselves.
    ///
    /// Loads the full-resolution bytes of an image file at paste time so targets
    /// that don't follow file URLs still get the original quality. Returns nil
    /// when the file is missing or larger than `MAX_PASTE_FILE_BYTES` — callers
    /// then fall back to file URL only (file-savvy apps still work).
    nonisolated static func loadOriginalImageData(at path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size <= MAX_PASTE_FILE_BYTES else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Generates a JPEG thumbnail (long edge `FILE_THUMBNAIL_MAX_PIXELS`) for an
    /// image file copied from Finder. Uses ImageIO so the source file is streamed,
    /// not fully decoded into memory — works fine for multi-GB RAW/TIFF originals.
    /// Returns nil if the file can't be read as an image.
    nonisolated static func generateImageFileThumbnail(at fileURL: URL) -> Data? {
        if let source = CGImageSourceCreateWithURL(fileURL as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) {
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: FILE_THUMBNAIL_MAX_PIXELS
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            }
        }
        // Vector formats (SVG) — CGImageSource can't decode them. Fall back to
        // NSImage which handles SVG natively on macOS 14+, then rasterize to JPEG
        // at FILE_THUMBNAIL_MAX_PIXELS so downstream preview code is unchanged.
        return rasterizeVectorThumbnail(at: fileURL)
    }

    private nonisolated static func rasterizeVectorThumbnail(at fileURL: URL) -> Data? {
        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        let original = image.size
        guard original.width > 0, original.height > 0 else { return nil }
        let maxPixel = CGFloat(FILE_THUMBNAIL_MAX_PIXELS)
        let scale = min(maxPixel / original.width, maxPixel / original.height, 1)
        let pixelWidth = Int((original.width * scale).rounded())
        let pixelHeight = Int((original.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else { return nil }
        bitmap.size = NSSize(width: pixelWidth, height: pixelHeight)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = ctx
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// Pulls the first available raw image representation off the pasteboard, but
    /// drops it when the bytes exceed `MAX_IMAGE_BYTES`. Without the cap a single
    /// pathological clip (Photoshop selection, RAW export) can blow up both the
    /// SwiftData store and downstream backup encoding.
    private func capturePasteboardImage(from pasteboard: NSPasteboard) -> Data? {
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            .tiff
        ]
        for type in imageTypes {
            guard let data = pasteboard.data(forType: type) else { continue }
            if data.count > Self.MAX_IMAGE_BYTES { return nil }
            return data
        }
        return nil
    }

    /// Office-private types are dropped at capture time so they never land in the
    /// database; see `OFFICE_PRIVATE_TYPE_PREFIXES` for rationale.
    private func capturePasteboardSnapshot(from pasteboard: NSPasteboard) -> Data? {
        guard let types = pasteboard.types, !types.isEmpty else { return nil }
        // Detect Word cross-reference/bookmark copy BEFORE the blanket com.microsoft.*
        // strip below removes the link markers. When Word places a bookmark link on
        // the pasteboard, the .pdf representation is a bookmark-link image rather
        // than real paragraph content; targets that pick PDF first (Pages, Preview)
        // would paste the link image instead of text. Drop the .pdf in that case
        // so targets fall through to public.rtf / public.html.
        let msLinkSource = NSPasteboard.PasteboardType("com.microsoft.LinkSource")
        let msObjectLink = NSPasteboard.PasteboardType("com.microsoft.ObjectLink")
        let isWordBookmarkCopy = types.contains(msLinkSource) && types.contains(msObjectLink)
        var dict: [String: Data] = [:]
        var totalBytes = 0
        for type in types {
            // Skip `dyn.*` aliases — macOS auto-generates them for legacy pasteboard
            // type names (e.g. `TelegramTextPboardType` also surfaces as `dyn.ah62d4rv4gu8...`).
            // Both point to identical bytes, so keeping them doubles the stored size
            // with no benefit.
            if type.rawValue.hasPrefix("dyn.") { continue }
            // Never persist the self-write marker in the snapshot. If it ever leaked
            // into the database, restoring that snapshot would re-apply the marker on
            // every paste and every subsequent poll would see it as "our write" — a
            // useless round-trip, and a stale artefact if the marker UTI ever changes.
            if type == .fromPasteMemo { continue }
            // Drop Office-private types unconditionally (issue #28) — Word's internal
            // clipboard hijack reads these and ignores NSPasteboard. This also removes
            // the LinkSource + ObjectLink pair.
            if Self.isOfficePrivateType(type.rawValue) { continue }
            // In a Word bookmark copy, also drop the bogus bookmark-link PDF.
            if isWordBookmarkCopy, type == .pdf { continue }
            guard let data = pasteboard.data(forType: type) else { continue }
            totalBytes += data.count
            if totalBytes > Self.MAX_SNAPSHOT_BYTES { return nil }
            dict[type.rawValue] = data
        }
        guard !dict.isEmpty else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    /// Restores a pasteboard snapshot produced by `capturePasteboardSnapshot`. Returns true
    /// on success (caller should skip any legacy per-type writes); false on malformed/empty
    /// snapshots so the caller can fall through to the fallback path.
    ///
    /// Office-private types are stripped on restore as well — defensively, in case the
    /// snapshot was captured by an older build before capture-time filtering existed.
    @discardableResult
    func restorePasteboardSnapshot(_ data: Data, to pasteboard: NSPasteboard) -> Bool {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dict = plist as? [String: Data],
            !dict.isEmpty
        else { return false }
        let filteredDict = dict.filter { !Self.isOfficePrivateType($0.key) }
        guard !filteredDict.isEmpty else { return false }
        pasteboard.clearContents()
        for (typeRaw, bytes) in filteredDict {
            pasteboard.setData(bytes, forType: NSPasteboard.PasteboardType(typeRaw))
        }
        return true
    }

    private func captureRichTextData(from pasteboard: NSPasteboard) -> (data: Data?, type: String?) {
        // Priority: RTFD (carries inline images — Notes, Pages, Word, TextEdit) >
        //           HTML (browsers, most modern apps) > RTF (legacy, no images).
        // Capturing the richest container and writing it back verbatim gives native pasting
        // behaviour: the destination app decodes whatever it prefers.
        // Each candidate is rejected if it exceeds MAX_RICHTEXT_BYTES so a single hot
        // RTFD with hundreds of inline images can't bloat the store / backup.
        if let rtfdData = pasteboard.data(forType: Self.FLAT_RTFD_TYPE),
           rtfdData.count <= Self.MAX_RICHTEXT_BYTES {
            return (rtfdData, "rtfd")
        }
        if let htmlData = pasteboard.data(forType: .html),
           htmlData.count <= Self.MAX_RICHTEXT_BYTES {
            return (htmlData, "html")
        }
        if let rtfData = pasteboard.data(forType: .rtf),
           rtfData.count <= Self.MAX_RICHTEXT_BYTES {
            return (rtfData, "rtf")
        }
        return (nil, nil)
    }

    /// Writes a previously-captured rich-text blob back to the pasteboard under its original type,
    /// and — when it's an RTFD container — also fills in HTML / RTF fallbacks so apps
    /// that can't read RTFD (e.g. Word, most browsers) still receive an equivalent representation.
    private func writeRichTextData(_ data: Data, type: String?, to pasteboard: NSPasteboard) {
        switch type {
        case "rtfd":
            pasteboard.setData(data, forType: Self.FLAT_RTFD_TYPE)
            // Derive HTML (with inline base64 images) and RTF fallbacks. Apps that can't read
            // RTFD will pick HTML — Word, Mail, browsers, etc.
            if let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtfd],
                documentAttributes: nil
            ) {
                let range = NSRange(location: 0, length: attr.length)
                // AppKit's HTML exporter drops fileWrapper-based image attachments, so build
                // our own HTML string with base64-inlined <img> tags.
                if pasteboard.data(forType: .html) == nil,
                   let html = Self.htmlWithInlineImages(from: attr) {
                    pasteboard.setData(html, forType: .html)
                }
                if pasteboard.data(forType: .rtf) == nil,
                   let rtf = try? attr.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    pasteboard.setData(rtf, forType: .rtf)
                }
            }
        case "html":
            pasteboard.setData(data, forType: .html)
        default:
            pasteboard.setData(data, forType: .rtf)
        }
    }

    /// Builds a minimal HTML document from an NSAttributedString where image attachments
    /// are encoded inline as base64 `data:` URIs. AppKit's native HTML export drops such
    /// attachments, so we produce them manually. Formatting is intentionally simple — the
    /// goal is to keep *images* intact for apps like Word that read HTML but not RTFD.
    private static func htmlWithInlineImages(from attr: NSAttributedString) -> Data? {
        var html = "<html><body>"
        let fullRange = NSRange(location: 0, length: attr.length)
        attr.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            if let attachment = value as? NSTextAttachment,
               let image = attachment.image
                ?? (attachment.fileWrapper?.regularFileContents).flatMap(NSImage.init(data:)),
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                let base64 = png.base64EncodedString()
                html += "<img src=\"data:image/png;base64,\(base64)\" />"
            } else {
                let substring = attr.attributedSubstring(from: range).string
                html += escapeHTML(substring)
            }
        }
        html += "</body></html>"
        return html.data(using: .utf8)
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br/>")
    }

    private static let VIDEO_EXTENSIONS: Set<String> = [
        "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "3gp"
    ]

    private static let IMAGE_EXTENSIONS: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "svg", "ico"
    ]

    private static let AUDIO_EXTENSIONS: Set<String> = [
        "mp3", "wav", "aac", "flac", "m4a", "ogg", "wma", "aiff", "alac", "opus"
    ]

    private static let DOCUMENT_EXTENSIONS: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "pages", "numbers", "keynote", "rtf", "rtfd",
        "csv", "tsv", "txt", "md", "markdown",
        "odt", "ods", "odp", "epub"
    ]

    private static let ARCHIVE_EXTENSIONS: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz",
        "tgz", "tbz2", "zst", "lz", "lzma", "cab", "iso", "dmg"
    ]

    private static let APPLICATION_EXTENSIONS: Set<String> = [
        "app", "pkg", "mpkg", "exe", "msi", "deb", "rpm", "apk", "ipa"
    ]

    private func detectFileType(_ paths: [String]) -> ClipContentType {
        let extensions = paths.compactMap { URL(fileURLWithPath: $0).pathExtension.lowercased() }
        let isDir = paths.count == 1 && {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: paths[0], isDirectory: &isDirectory)
            return isDirectory.boolValue
        }()
        // .app bundles are directories
        if isDir, extensions.first == "app" { return .application }
        if extensions.allSatisfy({ Self.VIDEO_EXTENSIONS.contains($0) }) { return .video }
        if extensions.allSatisfy({ Self.AUDIO_EXTENSIONS.contains($0) }) { return .audio }
        if extensions.allSatisfy({ Self.IMAGE_EXTENSIONS.contains($0) }) { return .image }
        if extensions.allSatisfy({ Self.DOCUMENT_EXTENSIONS.contains($0) }) { return .document }
        if extensions.allSatisfy({ Self.ARCHIVE_EXTENSIONS.contains($0) }) { return .archive }
        if extensions.allSatisfy({ Self.APPLICATION_EXTENSIONS.contains($0) }) { return .application }
        return .file
    }

    func findExistingDuplicate(for newItem: ClipItem, in context: ModelContext) -> ClipItem? {
        let content = newItem.content
        let descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate<ClipItem> { item in
                item.content == content
            },
            sortBy: [
                SortDescriptor(\.lastUsedAt, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse),
            ]
        )

        guard let matches = try? context.fetch(descriptor) else { return nil }
        return matches.first(where: { self.matchesDuplicateCandidate($0, with: newItem) })
    }

    func reuseExistingDuplicate(_ existingItem: ClipItem, with newItem: ClipItem, in context: ModelContext) {
        let now = Date()
        existingItem.lastUsedAt = now
        existingItem.sourceApp = newItem.sourceApp
        existingItem.sourceAppBundleID = newItem.sourceAppBundleID
        existingItem.displayTitle = newItem.displayTitle

        if existingItem.imageData == nil {
            existingItem.imageData = newItem.imageData
        }
        if existingItem.richTextData == nil {
            existingItem.richTextData = newItem.richTextData
            existingItem.richTextType = newItem.richTextType
        }
        if existingItem.codeLanguage == nil {
            existingItem.codeLanguage = newItem.codeLanguage
        }
        if newItem.isSensitive {
            existingItem.isSensitive = true
        }
        if newItem.isPinned {
            existingItem.isPinned = true
        }
        if existingItem.groupName == nil, let groupName = newItem.groupName, !groupName.isEmpty {
            existingItem.groupName = groupName
            upsertSmartGroup(name: groupName, context: context)
        }
    }

    private func isLatestDuplicate(_ newItem: ClipItem, in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        guard let latest = try? context.fetch(descriptor).first else { return false }
        return matchesDuplicateCandidate(latest, with: newItem)
    }

    private func matchesDuplicateCandidate(_ existingItem: ClipItem, with newItem: ClipItem) -> Bool {
        guard existingItem.content == newItem.content else {
            return false
        }

        let existingIsRelaxedText = existingItem.contentType == .text
        let newIsRelaxedText = newItem.contentType == .text

        if existingItem.contentType == newItem.contentType {
            if existingItem.contentType == .image, existingItem.imageData != newItem.imageData { return false }
            if existingItem.contentType == .mixed {
                // Mixed items carry multiple independent representations; any difference in
                // image bytes or file path list means it's a distinct clip.
                if existingItem.imageData != newItem.imageData { return false }
                if existingItem.filePaths != newItem.filePaths { return false }
                return true
            }
            if existingIsRelaxedText && newIsRelaxedText {
                let existingHasRichText = existingItem.richTextData != nil
                let newHasRichText = newItem.richTextData != nil
                if existingHasRichText != newHasRichText {
                    return true
                }
                return existingItem.richTextData == newItem.richTextData
            }
            // For non-text, non-image types (.link, .code, .phone, .color,
            // .file, .email, .video, .audio, .document, ...), the content
            // string is the authoritative identity — an identical URL copied
            // from Chrome vs Terminal should merge even if Chrome attached
            // HTML rich text and Terminal didn't.
            return true
        }

        guard existingIsRelaxedText, newIsRelaxedText else {
            return false
        }

        let existingHasRichText = existingItem.richTextData != nil
        let newHasRichText = newItem.richTextData != nil
        return existingHasRichText != newHasRichText
    }

    private func refreshLinkMetadataIfNeeded(for item: ClipItem, in context: ModelContext) {
        guard item.contentType == .link else { return }
        guard item.linkTitle == nil || item.faviconData == nil else { return }

        // Honour the user's privacy preferences: offline mode is the master
        // override (no network at all); otherwise disabling web preview or
        // preferring the raw URL also suppresses the background metadata
        // fetch — without this gate, PasteMemo silently GETs every copied
        // link (issue #46).
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "offlineModeEnabled") { return }
        let webPreviewEnabled = (defaults.object(forKey: "webPreviewEnabled") as? Bool) ?? true
        let showLinkURL = (defaults.object(forKey: "showLinkURL") as? Bool) ?? false
        guard webPreviewEnabled, !showLinkURL else { return }

        let targetItem = item
        Task {
            let metadata = await LinkMetadataFetcher.shared.fetchMetadata(urlString: targetItem.content)
            await MainActor.run {
                if let title = metadata.title { targetItem.linkTitle = title }
                if let favicon = metadata.faviconData { targetItem.faviconData = favicon }
                ClipItemStore.saveAndNotifyContent(context)
            }
        }
    }

    private func enqueueOCRIfNeeded(for item: ClipItem) {
        guard item.contentType == .image, item.imageData != nil else { return }
        OCRTaskCoordinator.shared.enqueue(itemID: item.itemID)
    }

    private func cleanExpiredItems(in context: ModelContext) {
        guard let cutoff = ProManager.shared.retentionCutoffDate else { return }

        let descriptor = FetchDescriptor<ClipItem>()
        guard let allItems = try? context.fetch(descriptor) else { return }
        let preservedGroupNames = SmartGroupRetention.preservedGroupNames(in: context)

        let expiredItems = allItems.filter {
            $0.createdAt < cutoff
                && !$0.isPinned
                && !SmartGroupRetention.shouldPreserve(item: $0, preservedGroupNames: preservedGroupNames)
        }
        guard !expiredItems.isEmpty else { return }

        let hasGroupedItems = expiredItems.contains { $0.groupName != nil }
        ClipItemStore.deleteAndNotify(expiredItems, from: context)
        if hasGroupedItems {
            recalculateAllGroupCounts(context: context)
        }
    }

    // MARK: - Content Detection

    struct DetectedContent {
        let type: ClipContentType
        let language: String?
    }

    func detectContentType(_ content: String) -> DetectedContent {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if isPhone(trimmed) { return DetectedContent(type: .phone, language: nil) }
        if isColor(trimmed) { return DetectedContent(type: .color, language: nil) }
        if isURL(trimmed) || trimmed.hasPrefix("data:image/") { return DetectedContent(type: .link, language: nil) }
        if isFilePath(trimmed) { return DetectedContent(type: .file, language: nil) }
        if let lang = CodeDetector.detectLanguage(trimmed) {
            return DetectedContent(type: .code, language: lang.rawValue)
        }

        return DetectedContent(type: .text, language: nil)
    }

    private func isPhone(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Chinese mobile: 1xx xxxx xxxx (with optional spaces/dashes)
        if trimmed.range(of: #"^1\d[\d\s\-]{9,13}$"#, options: .regularExpression) != nil {
            let digits = trimmed.filter(\.isNumber)
            if digits.count == 11 { return true }
        }
        // Chinese landline: (0xx) xxxx-xxxx or 0xx-xxxx-xxxx
        if trimmed.range(of: #"^[\(]?0\d{2,3}[\)]?[\s\-]?\d{7,8}$"#, options: .regularExpression) != nil {
            return true
        }
        // International: +xx xxx... (7-15 digits total)
        if trimmed.range(of: #"^\+\d[\d\s\-\(\)]{6,19}$"#, options: .regularExpression) != nil {
            let digits = trimmed.filter(\.isNumber)
            if (7...15).contains(digits.count) { return true }
        }
        return false
    }

    private func isColor(_ text: String) -> Bool {
        // #RGB, #RRGGBB, #RRGGBBAA
        if text.range(of: #"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#, options: .regularExpression) != nil {
            return true
        }
        // rgb(r,g,b) / rgba(r,g,b,a)
        if text.range(of: #"^rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}"#, options: .regularExpression) != nil {
            return true
        }
        // hsl(h,s%,l%) / hsla(h,s%,l%,a)
        if text.range(of: #"^hsla?\(\s*\d{1,3}\s*,"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private func isURL(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        // Full URL: https://example.com
        if text.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil,
           let url = URL(string: text), url.host != nil {
            return true
        }
        // Bare domain: example.com, sub.example.com/path
        if text.range(of: #"^[a-zA-Z0-9]([a-zA-Z0-9-]*\.)+[a-zA-Z]{2,}(/\S*)?$"#, options: .regularExpression) != nil {
            // Reject if the trailing label is a common file extension and
            // the text has no URL path (e.g. "mn-little-yellow-duck.conf"
            // or "foo.bar.json"). This avoids misclassifying config file
            // names as links.
            if !text.contains("/") {
                let lastDot = text.lastIndex(of: ".")!
                let suffix = text[text.index(after: lastDot)...].lowercased()
                if Self.nonDomainSuffixes.contains(String(suffix)) { return false }
            }
            return true
        }
        return false
    }

    private static let nonDomainSuffixes: Set<String> = [
        // configs / text
        "conf", "config", "ini", "env", "lock", "plist", "toml",
        "log", "txt", "md", "markdown", "rtf", "csv", "tsv",
        // data / markup
        "json", "xml", "yml", "yaml", "html", "htm", "xhtml", "sql",
        // code
        "swift", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs",
        "c", "cc", "cpp", "cxx", "h", "hpp", "hxx", "m", "mm",
        "java", "kt", "kts", "scala", "groovy", "dart", "lua",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        "php", "pl", "r", "jl", "clj", "erl", "ex", "exs",
        // binaries / archives
        "exe", "dll", "so", "dylib", "a", "o",
        "zip", "tar", "gz", "bz2", "xz", "rar", "7z",
        "iso", "dmg", "pkg", "deb", "rpm", "app",
        // documents
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
        "pages", "numbers", "keynote",
        // media
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "ico", "heic", "heif",
        "mp3", "wav", "flac", "ogg", "m4a", "aac",
        "mp4", "mov", "avi", "mkv", "webm", "m4v"
    ]

    private func isFilePath(_ text: String) -> Bool {
        guard text.hasPrefix("/") || text.hasPrefix("~") else { return false }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.allSatisfy({ $0.hasPrefix("/") || $0.hasPrefix("~") }) else { return false }
        // At least one path must actually exist on disk
        return lines.contains { line in
            let expanded = NSString(string: line).expandingTildeInPath
            return FileManager.default.fileExists(atPath: expanded)
        }
    }

    // MARK: - Paste

    func paste(_ item: ClipItem) {
        writeToPasteboard(item)
        lastChangeCount = NSPasteboard.general.changeCount
        skipRelayMonitorIfActive()
        SoundManager.playPaste()

        Task { @MainActor in
            try? await Task.sleep(for: PASTE_SIMULATION_DELAY)
            simulateCommandV()
        }
    }

    /// Extract filenames from a file-path content string (newline-separated paths).
    /// Returns nil if no valid filenames can be extracted.
    private func filenamesFromContent(_ content: String) -> String? {
        let names = content.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        return names.isEmpty ? nil : names.joined(separator: "\n")
    }

    func writeToPasteboard(_ item: ClipItem, targetApp: NSRunningApplication? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let textOnly = isTextOnlyApp(targetApp)
        let terminal = isTerminalApp(targetApp)

        // Full-fidelity path: if we captured a pasteboard snapshot at copy time, replay it
        // verbatim. That's exactly what the system does between Cmd+C and Cmd+V, so the target
        // app (Word / Mail / Notes / browsers) receives the original bytes for every UTI it
        // may prefer.
        //
        // Exception: if the target is a plain-text-only app (terminals, editors), skip the
        // snapshot — it might carry file URLs / images the target can't use, and the text-only
        // fallback below picks the best textual representation.
        //
        // `restorePasteboardSnapshot` itself drops Office-private types (issue #28) so Word
        // paste doesn't get hijacked by its private internal clipboard.
        if !textOnly, let snapshot = item.pasteboardSnapshot,
           restorePasteboardSnapshot(snapshot, to: pasteboard) {
            pasteboard.markAsPasteMemoWrite()
            lastChangeCount = pasteboard.changeCount
            skipRelayMonitorIfActive()
            return
        }

        switch item.contentType {
        case .image:
            if textOnly {
                // Text-only app: terminal gets full path, editor gets filename
                if item.content != "[Image]" {
                    // File-based image: write file URLs FIRST so tool windows that accept
                    // file drops (e.g. IDEA project tree) can paste the file, then add the
                    // filename string so editor buffers paste text. setString doesn't clear
                    // existing types, so both coexist on the pasteboard.
                    writeFilePathsToPasteboard(pasteboard, content: item.content)
                    if terminal {
                        pasteboard.setString(item.content, forType: .string)
                    } else if let names = filenamesFromContent(item.content) {
                        pasteboard.setString(names, forType: .string)
                    }
                } else if let data = item.imageData, let image = NSImage(data: data) {
                    pasteboard.writeObjects([image])
                } else if let data = item.imageData {
                    pasteboard.setData(data, forType: .png)
                }
            } else {
                // writeObjects clears the pasteboard on each call, so combine URLs + image into a
                // single writeObjects invocation. Otherwise the URL disappears and apps like Word
                // fall back to pasting the filename string instead of embedding the image.
                let paths: [String] = item.content == "[Image]"
                    ? []
                    : item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
                let hasFiles = !paths.isEmpty

                // For file-backed clips we re-read the original file at paste time so
                // pixel-only targets (Claude Code, Slack, browsers, Electron apps that
                // can't follow a file URL) get the full original image rather than the
                // small thumbnail kept in storage. Falls back to the stored bytes if
                // the source file is gone or oversized.
                let pasteImageData = item.imageBytesForExport()

                var writables: [NSPasteboardWriting] = paths.map { URL(fileURLWithPath: $0) as NSURL }
                if let data = pasteImageData, let image = NSImage(data: data) {
                    writables.append(image)
                }
                if !writables.isEmpty {
                    pasteboard.writeObjects(writables)
                }

                // Legacy file-names pboard type for apps that still read it.
                if hasFiles {
                    let pboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
                    pasteboard.setPropertyList(paths, forType: pboardType)
                }
                // Raw bytes for apps that don't read NSImage.
                if writables.first(where: { $0 is NSImage }) == nil,
                   let data = pasteImageData {
                    pasteboard.setData(data, forType: .png)
                }
                // Text fallback filename for unknown apps.
                if hasFiles, let names = filenamesFromContent(item.content) {
                    pasteboard.setString(names, forType: .string)
                }
            }
        case .file, .video, .audio, .document, .archive, .application:
            if textOnly {
                // Terminal: paste full path; Editor: paste filename
                if terminal {
                    pasteboard.setString(item.content, forType: .string)
                } else if let names = filenamesFromContent(item.content) {
                    pasteboard.setString(names, forType: .string)
                }
            } else {
                writeFilePathsToPasteboard(pasteboard, content: item.content)
                // Add text fallback for unknown apps
                if let names = filenamesFromContent(item.content) {
                    pasteboard.setString(names, forType: .string)
                }
            }
        case .mixed:
            let paths = item.resolvedFilePaths
            let hasFiles = !paths.isEmpty
            let hasImage = item.imageData != nil
            let textContent = item.content
            let hasText = !textContent.isEmpty && textContent != "[Mixed]"

            if textOnly {
                // Plain-text-only targets get the best textual representation available.
                if hasText {
                    pasteboard.setString(textContent, forType: .string)
                } else if hasFiles {
                    if terminal {
                        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
                    } else if let names = filenamesFromContent(paths.joined(separator: "\n")) {
                        pasteboard.setString(names, forType: .string)
                    }
                }
                // No image handling for text-only apps — they can't accept it.
            } else {
                // General targets: expose every representation so the target app can pick what it reads.
                // NSPasteboard.writeObjects internally preserves previously-written content when followed
                // by setData/setString, but earlier setData calls are cleared by subsequent writeObjects.
                // Therefore: do writeObjects first (combined), then setData/setString as additive layers.
                var writables: [NSPasteboardWriting] = []
                if hasFiles {
                    writables.append(contentsOf: paths.map { URL(fileURLWithPath: $0) as NSURL })
                }
                if hasImage, let data = item.imageData, let image = NSImage(data: data) {
                    writables.append(image)
                }
                if !writables.isEmpty {
                    pasteboard.writeObjects(writables)
                }
                // Legacy NSFilenamesPboardType for file-aware apps that still read the old type.
                if hasFiles {
                    let pboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
                    pasteboard.setPropertyList(paths, forType: pboardType)
                }
                // Raw image bytes for apps that don't read NSImage.
                if hasImage, let data = item.imageData, NSImage(data: data) == nil {
                    pasteboard.setData(data, forType: .png)
                }
                // Text + rich text layer (setString/setData are additive).
                if hasText {
                    pasteboard.setString(textContent, forType: .string)
                } else if hasFiles, let names = filenamesFromContent(paths.joined(separator: "\n")) {
                    pasteboard.setString(names, forType: .string)
                }
                if let rtfData = item.richTextData {
                    writeRichTextData(rtfData, type: item.richTextType, to: pasteboard)
                }
            }
        default:
            // writeObjects clears the pasteboard, so image (if present) goes first, then string/rtf are additive.
            // Skip image write for `.link` clips — `imageData` on a link is a
            // pre-decoded preview for base64 `data:image/...` URIs; the user's
            // copy intent is the URI string, so paste must hand back exactly that.
            if item.contentType != .link, let imgData = item.imageData {
                if let image = NSImage(data: imgData) {
                    pasteboard.writeObjects([image])
                } else {
                    pasteboard.setData(imgData, forType: .png)
                }
            }
            pasteboard.setString(item.content, forType: .string)
            if let rtfData = item.richTextData {
                writeRichTextData(rtfData, type: item.richTextType, to: pasteboard)
            }
        }
        pasteboard.markAsPasteMemoWrite()
        lastChangeCount = NSPasteboard.general.changeCount
        skipRelayMonitorIfActive()
    }

    func writeFileURLsToPasteboard(_ pasteboard: NSPasteboard, paths: [String]) {
        // Use both modern writeObjects and legacy NSFilenamesPboardType for max compatibility
        let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
        pasteboard.writeObjects(urls)
        let pboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.setPropertyList(paths, forType: pboardType)
    }

    private func writeFilePathsToPasteboard(_ pasteboard: NSPasteboard, content: String) {
        let paths = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        writeFileURLsToPasteboard(pasteboard, paths: paths)
    }

    /// Terminal apps — paste full file path (not just filename) since terminal users need paths to operate on files.
    private static let TERMINAL_APPS: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",          // iTerm2
        "dev.warp.Warp-Stable",           // Warp
        "org.alacritty",                  // Alacritty
        "net.kovidgoyal.kitty",           // Kitty
        "co.zeit.hyper",                  // Hyper
        "com.github.wez.wezterm",        // WezTerm
        "com.raphael.rio",               // Rio
        "org.tabby",                     // Tabby
        "dev.commandline.wave",          // Wave Terminal
        "com.mitchellh.ghostty",         // Ghostty
    ]

    /// Apps that are pure text environments — cannot accept file URLs or image data.
    /// Terminal apps get full path, editors get filename.
    /// This is a subset of PLAIN_TEXT_ONLY_APPS (excludes IM apps which can accept files).
    private static let TEXT_ONLY_APPS: Set<String> = TERMINAL_APPS.union([
        // Code editors / IDEs
        "com.apple.dt.Xcode",            // Xcode
        "com.google.android.studio",     // Android Studio
        "com.sublimetext.4",             // Sublime Text
        "com.sublimetext.3",
        "com.microsoft.VSCode",          // VS Code
        "com.jetbrains.intellij",        // IntelliJ IDEA
        "com.jetbrains.intellij.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.goland",
        "com.jetbrains.CLion",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.rubymine",
        "com.jetbrains.rider",
        "com.jetbrains.AppCode",
        "com.jetbrains.fleet",
        "dev.zed.Zed",                   // Zed
        "com.panic.Nova",                // Nova
        "com.barebones.bbedit",          // BBEdit
        "abnerworks.Typora",             // Typora
        "com.cursor.Cursor",             // Cursor
        "com.macromates.TextMate",       // TextMate
        "com.coteditor.CotEditor",       // CotEditor
        "com.neovide.neovide",           // Neovide
        "com.qvacua.VimR",              // VimR
        "com.codeium.windsurf",          // Windsurf
        "com.trae.Trae",                 // Trae
    ])

    /// Paste multiple items in display order via sequential Cmd+V operations.
    /// Consecutive file items are merged into one paste; each text/image gets its own paste to preserve formatting.
    /// Apps that don't handle rich text paste well — downgrade to plain text for merging.
    /// This is a superset of TEXT_ONLY_APPS, adding IM apps that can receive files but need rich text downgrade.
    private static let PLAIN_TEXT_ONLY_APPS: Set<String> = TEXT_ONLY_APPS.union([
        // IM — can receive files, only need rich text downgrade
        "com.tencent.xinWeChat",          // WeChat
        "com.tencent.qq",                 // QQ
        "com.alibaba.DingTalkMac",        // DingTalk
        "com.electron.lark",              // Feishu/Lark
        "com.apple.iChat",               // Messages
        "com.microsoft.teams2",           // Teams
        "com.tinyspeck.slackmacgap",      // Slack
        "ru.keepcoder.Telegram",          // Telegram
        "com.discord.Discord",            // Discord
        "net.whatsapp.WhatsApp",          // WhatsApp
        "org.whispersystems.signal-desktop", // Signal
        "jp.naver.line.mac",              // Line
        "us.zoom.xos",                    // Zoom
    ])

    private func shouldDowngradeRichText(targetApp: NSRunningApplication?) -> Bool {
        guard let bundleID = targetApp?.bundleIdentifier else { return false }
        return Self.PLAIN_TEXT_ONLY_APPS.contains(bundleID)
    }

    /// Whether the target app is a text-only environment that cannot accept file URLs or image data.
    private func isTextOnlyApp(_ targetApp: NSRunningApplication?) -> Bool {
        guard let bundleID = targetApp?.bundleIdentifier else { return false }
        return Self.TEXT_ONLY_APPS.contains(bundleID)
    }

    /// Whether the target app is a terminal — terminals get full file path, editors get filename.
    private func isTerminalApp(_ targetApp: NSRunningApplication?) -> Bool {
        guard let bundleID = targetApp?.bundleIdentifier else { return false }
        return Self.TERMINAL_APPS.contains(bundleID)
    }

    func pasteMultiple(_ items: [ClipItem], forceNewLine: Bool = false, targetApp: NSRunningApplication? = nil) {
        let downgrade = shouldDowngradeRichText(targetApp: targetApp)
        let textOnly = isTextOnlyApp(targetApp)
        let terminal = isTerminalApp(targetApp)
        let groups = buildPasteGroups(items, downgradeRichText: downgrade)

        SoundManager.playPaste()
        Task { @MainActor in
            for (index, group) in groups.enumerated() {
                if index > 0 {
                    try? await Task.sleep(for: .milliseconds(150))
                    // Insert a newline between groups so heterogeneous pastes (text + file,
                    // text + image, etc.) don't glue together on the same line.
                    simulateReturn()
                    try? await Task.sleep(for: .milliseconds(80))
                }

                let pasteboard = NSPasteboard.general

                switch group {
                case .clipItem(let item):
                    // Delegate to the single-item pipeline, which already knows about snapshots,
                    // mixed content, terminal/text-only overrides, etc.
                    writeToPasteboard(item, targetApp: targetApp)
                case .files(let paths):
                    pasteboard.clearContents()
                    if textOnly {
                        // Terminal: full paths; Editor: filenames
                        let text = terminal
                            ? paths.joined(separator: "\n")
                            : paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "\n")
                        pasteboard.setString(text, forType: .string)
                    } else {
                        writeFileURLsToPasteboard(pasteboard, paths: paths)
                    }
                case .text(let content, let rtfData, let rtfType):
                    pasteboard.clearContents()
                    pasteboard.setString(content, forType: .string)
                    if let rtfData {
                        writeRichTextData(rtfData, type: rtfType, to: pasteboard)
                    }
                case .image(let data):
                    pasteboard.clearContents()
                    if let image = NSImage(data: data) {
                        pasteboard.writeObjects([image])
                    } else {
                        pasteboard.setData(data, forType: .png)
                        pasteboard.setData(data, forType: .tiff)
                    }
                }

                pasteboard.markAsPasteMemoWrite()
                lastChangeCount = pasteboard.changeCount
                skipRelayMonitorIfActive()
                try? await Task.sleep(for: PASTE_SIMULATION_DELAY)
                simulateCommandV()
            }
            if forceNewLine {
                try? await Task.sleep(for: .milliseconds(100))
                simulateReturn()
            }
        }
    }

    private enum PasteGroup {
        case files([String])
        case text(String, richTextData: Data?, richTextType: String?)
        case image(Data)
        /// Full-fidelity single-item group — defer to `writeToPasteboard(item)` so the single-clip
        /// pipeline (snapshot restore, mixed handling, etc.) is reused verbatim instead of
        /// reimplemented here. Prevents drift between single-paste and multi-paste behaviour.
        case clipItem(ClipItem)
    }

    /// Group consecutive same-type items: files merge; texts and images each get their own group to preserve formatting.
    private func buildPasteGroups(_ items: [ClipItem], downgradeRichText: Bool = false) -> [PasteGroup] {
        var groups: [PasteGroup] = []
        for item in items {
            // Items carrying a full pasteboard snapshot or multi-representation (.mixed) content
            // must go through the single-paste pipeline — their bytes can't be meaningfully
            // inlined into a PasteGroup.text without garbling binary data (e.g. RTFD bytes
            // getting treated as a utf8 string).
            if (item.pasteboardSnapshot != nil && !downgradeRichText) || item.contentType == .mixed {
                groups.append(.clipItem(item))
                continue
            }
            if isFileBasedContent(item) {
                let paths = item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
                if case .files = groups.last {
                    if case .files(let existing) = groups.last {
                        groups[groups.count - 1] = .files(existing + paths)
                    }
                } else {
                    groups.append(.files(paths))
                }
            } else if item.contentType == .image, item.content == "[Image]", let data = item.imageData {
                groups.append(.image(data))
            } else if item.richTextData != nil, !downgradeRichText {
                // Rich text: separate group to preserve formatting
                groups.append(.text(item.content, richTextData: item.richTextData, richTextType: item.richTextType))
            } else {
                // Plain text: merge consecutive plain texts
                if case .text(let existing, nil, nil) = groups.last {
                    groups[groups.count - 1] = .text(existing + "\n" + item.content, richTextData: nil, richTextType: nil)
                } else {
                    groups.append(.text(item.content, richTextData: nil, richTextType: nil))
                }
            }
        }
        return groups
    }

    private func isFileBasedContent(_ item: ClipItem) -> Bool {
        item.contentType.isFileBased && !(item.contentType == .image && item.content == "[Image]")
    }

    func pasteMultipleAsPlainText(_ items: [ClipItem]) {
        let merged = items.map(\.content).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(merged, forType: .string)
        pasteboard.markAsPasteMemoWrite()
        lastChangeCount = pasteboard.changeCount
        skipRelayMonitorIfActive()

        Task { @MainActor in
            try? await Task.sleep(for: PASTE_SIMULATION_DELAY)
            simulateCommandV()
        }
    }

    func pasteAsPlainText(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.content, forType: .string)
        pasteboard.markAsPasteMemoWrite()
        lastChangeCount = pasteboard.changeCount
        skipRelayMonitorIfActive()
        SoundManager.playPaste()

        Task { @MainActor in
            try? await Task.sleep(for: PASTE_SIMULATION_DELAY)
            simulateCommandV()
        }
    }

    private func skipRelayMonitorIfActive() {
        if RelayManager.shared.isActive {
            RelayManager.shared.skipMonitorNextChange()
        }
    }

    func simulatePaste(forceNewLine: Bool = false) {
        simulateCommandV()

        let shouldNewLine = forceNewLine || UserDefaults.standard.bool(forKey: "addNewLineAfterPaste")
        if shouldNewLine {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.simulateReturn()
            }
        }
    }

    private func simulateCommandV() {
        // privateState: event carries no inherited physical modifier state, so
        // ⌘V stays exactly ⌘V even if the user is still holding other keys
        // (global hotkey release timing, Ctrl-based relay triggers, etc.).
        let source = CGEventSource(stateID: .privateState)
        // Resolve the V keycode for the current keyboard layout so pure Dvorak /
        // Colemak / AZERTY users also get ⌘V instead of whatever character sits
        // at the ANSI V slot in their layout.
        let vKeyCode = KeyboardLayout.virtualKeyForV()
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func simulateReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0.0
        let returnCode: CGKeyCode = 0x24
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnCode, keyDown: false)
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    func requestAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func frontmostAppInfo() -> (name: String?, bundleID: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? ""
        // Don't show PasteMemo as source app, but still allow capture
        let isPasteMemo = bundleID.contains("pastememo")
        return (isPasteMemo ? nil : app?.localizedName, bundleID)
    }

    // MARK: - Finder Integration

    func isFinderApp(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier == "com.apple.finder"
    }

    func getFinderSelectedFolder() -> URL? {
        let script = """
        tell application "Finder"
            if (count of windows) > 0 then
                set theSelection to selection
                if (count of theSelection) > 0 then
                    set firstItem to item 1 of theSelection
                    if class of firstItem is folder then
                        return POSIX path of (firstItem as alias)
                    else
                        return POSIX path of ((container of firstItem) as alias)
                    end if
                else
                    return POSIX path of ((target of front window) as alias)
                end if
            else
                return POSIX path of (desktop as alias)
            end if
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil, let path = result.stringValue else { return nil }
        return URL(fileURLWithPath: path)
    }

    func saveImageToFolder(
        _ imageData: Data,
        folder: URL,
        preferredFilename: String? = nil
    ) -> URL? {
        let filename: String
        if let preferred = preferredFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty {
            filename = preferred
        } else {
            let ext = Self.sniffImageExtension(from: imageData)
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            filename = "PasteMemo_\(timestamp).\(ext)"
        }

        let fileURL = Self.uniqueDestination(folder.appendingPathComponent(filename))

        do {
            try imageData.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }

    /// Copies an existing image file to `folder` byte-for-byte. Used by the
    /// "save to Finder folder" smart paste for file-backed clips so the user
    /// gets the original file (correct dimensions, format, EXIF), not a
    /// re-encoded copy of the stored thumbnail.
    ///
    /// `FileManager.copyItem(at:to:)` does NOT follow symbolic links — it
    /// duplicates the link node itself, which is a tiny file containing the
    /// link's target path string (showing up as ~174 bytes via `ls`).
    /// Telegram's group container places the pasteboard file URL on a `.jpg`
    /// symlink that points to an extension-less real file, so naive copyItem
    /// silently produces a "174-byte image" that won't preview anywhere.
    /// Detect symlinks and use `Data(contentsOf:)` (which follows links via
    /// the kernel) so the destination holds the actual image bytes while
    /// preserving the original filename users see in their copy.
    func copyImageFileToFolder(sourceURL: URL, folder: URL) -> URL? {
        return Self.copyImageFileToFolder(sourceURL: sourceURL, folder: folder)
    }

    nonisolated static func copyImageFileToFolder(sourceURL: URL, folder: URL) -> URL? {
        let destURL = uniqueDestination(folder.appendingPathComponent(sourceURL.lastPathComponent))
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                let bytes = try Data(contentsOf: sourceURL)
                try bytes.write(to: destURL)
            } else {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            }
            return destURL
        } catch {
            return nil
        }
    }

    /// Sniff the real image format from magic bytes (PNG / JPEG / GIF / WebP /
    /// HEIC) so saved files match their actual content — avoids shipping a
    /// JPEG payload under a `.png` extension.
    private static func sniffImageExtension(from data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 3 else { return "png" }
        if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50,
           bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpg" }
        if bytes.count >= 4, bytes[0] == 0x47, bytes[1] == 0x49,
           bytes[2] == 0x46, bytes[3] == 0x38 { return "gif" }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46],
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if bytes.count >= 12,
           Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(bytes: Array(bytes[8..<12]), encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "mif1", "msf1"].contains(brand) { return "heic" }
        }
        return "png"
    }

    /// Return a destination URL that doesn't collide with an existing file —
    /// `foo.jpg` → `foo 1.jpg` / `foo 2.jpg` etc.
    nonisolated private static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        for i in 1...999 {
            let candidate = folder.appendingPathComponent("\(base) \(i).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    func saveTextToFolder(_ text: String, folder: URL, fileExtension: String = "txt") -> URL? {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "PasteMemo_\(timestamp).\(fileExtension)"
        let fileURL = folder.appendingPathComponent(filename)

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }
}

// MARK: - ClipboardControllable

extension ClipboardManager: ClipboardControllable {
    var isMonitoringPaused: Bool { isPaused }

    func pauseMonitoring() {
        pauseMonitoring(persistent: true)
    }

    func resumeMonitoring() {
        resumeMonitoring(persistent: true)
    }

    func pauseMonitoring(persistent: Bool) {
        if persistent {
            guard isMonitoringEnabled else { return }
            isMonitoringEnabled = false
        } else {
            guard !isTemporarilyPaused else { return }
            isTemporarilyPaused = true
        }
    }

    func resumeMonitoring(persistent: Bool) {
        if persistent {
            guard !isMonitoringEnabled else { return }
            isMonitoringEnabled = true
        } else {
            guard isTemporarilyPaused else { return }
            isTemporarilyPaused = false
        }
    }

    private func applyAutomationActions(_ actions: [RuleAction], processed: String, to item: ClipItem, context: ModelContext) {
        item.content = processed
        item.displayTitle = ClipItem.buildTitle(content: processed, contentType: item.contentType)
        if actions.contains(.stripRichText) {
            item.richTextData = nil
            item.richTextType = nil
        }
        if actions.contains(.markSensitive) {
            item.isSensitive = true
        }
        if actions.contains(.pin) {
            item.isPinned = true
        }
        applyGroupAction(actions, to: item, context: context)
    }

    private func applyGroupAction(_ actions: [RuleAction], to item: ClipItem, context: ModelContext) {
        guard let groupAction = actions.first(where: {
            if case .assignGroup = $0 { return true }
            return false
        }), case .assignGroup(let name) = groupAction, !name.isEmpty else { return }

        item.groupName = name
        upsertSmartGroup(name: name, context: context)
    }

    func upsertSmartGroup(name: String, context: ModelContext) {
        let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == name })
        if let existing = try? context.fetch(descriptor).first {
            existing.count += 1
        } else {
            let maxOrder = (try? context.fetch(FetchDescriptor<SmartGroup>()))?.map(\.sortOrder).max() ?? -1
            let group = SmartGroup(name: name, sortOrder: maxOrder + 1)
            group.count = 1
            context.insert(group)
        }
    }

    func decrementSmartGroup(name: String, context: ModelContext) {
        let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == name })
        guard let group = try? context.fetch(descriptor).first else { return }
        group.count = max(0, group.count - 1)
    }

    func recalculateAllGroupCounts(context: ModelContext) {
        guard let groups = try? context.fetch(FetchDescriptor<SmartGroup>()) else { return }
        for group in groups {
            let name = group.name
            let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.groupName == name })
            group.count = (try? context.fetchCount(descriptor)) ?? 0
        }
        try? context.save()
    }

    private func showAutomationConfirmation(ruleName: String, original: String, processed: String) -> Bool {
        let localizedName = ruleName.hasPrefix("automation.builtIn.") ? L10n.tr(ruleName) : ruleName

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 0),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = L10n.tr("automation.confirm.title")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false

        var accepted = false

        let alert = NSAlert()
        alert.messageText = L10n.tr("automation.confirm.title")
        alert.informativeText = L10n.tr("automation.confirm.matched", localizedName)
            + "\n\n"
            + L10n.tr("automation.confirm.original") + "\n" + String(original.prefix(200))
            + "\n\n"
            + L10n.tr("automation.confirm.processed") + "\n" + String(processed.prefix(200))
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr("automation.confirm.apply"))
        alert.addButton(withTitle: L10n.tr("automation.confirm.keep"))

        // Bring alert to front without activating the full app
        NSApp.activate(ignoringOtherApps: true)
        accepted = alert.runModal() == .alertFirstButtonReturn

        return accepted
    }
}
