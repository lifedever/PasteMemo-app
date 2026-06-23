import Foundation
import SwiftData

@MainActor
final class OCRTaskCoordinator: ObservableObject {
    static let shared = OCRTaskCoordinator()

    private var modelContainer: ModelContainer?
    private var inFlightItemIDs = Set<String>()

    @Published var scanTotal = 0
    @Published var scanCompleted = 0
    @Published var isScanning = false
    private var scanCancelRequested = false

    private init() {}

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // 默认关：OCR 在后台用 Vision 识别图片（加载神经网络模型 + 解码图），内存开销较大。
    // 新用户默认不开，需要的人在「设置 → 图片 OCR」手动启用（启用处有内存提示）。
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enableOCRKey) as? Bool ?? false
    }

    var autoProcessEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoOCRKey) as? Bool ?? true
    }

    /// Whether OCR should emit layout-aware Markdown (paragraphs, lists, tables)
    /// instead of plain text. Only effective on macOS 26+; the engine falls back
    /// to plain text automatically below that, so this can stay on everywhere.
    var markdownEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.markdownKey) as? Bool ?? true
    }

    func enqueue(itemID: String) {
        guard isEnabled, autoProcessEnabled else { return }
        enqueueForce(itemID: itemID)
    }

    func retry(itemID: String) {
        guard isEnabled else { return }
        enqueueForce(itemID: itemID)
    }

    func canRetry(item: ClipItem) -> Bool {
        isEnabled && item.contentType == .image && item.imageData != nil
    }

    func scanExistingImages() {
        guard let container = modelContainer, !isScanning else { return }
        let context = container.mainContext
        let descriptor = FetchDescriptor<ClipItem>()
        guard let items = try? context.fetch(descriptor) else { return }
        let pending = items.filter { $0.contentType == .image && $0.resolvedOCRStatus != OCRStatus.done && $0.imageData != nil }
        guard !pending.isEmpty else { return }

        isScanning = true
        scanTotal = pending.count
        scanCompleted = 0
        scanCancelRequested = false

        let ids = pending.map { $0.itemID }
        Task {
            for id in ids {
                if scanCancelRequested { break }
                await withCheckedContinuation { continuation in
                    enqueueForceThen(itemID: id) {
                        continuation.resume()
                    }
                }
                self.scanCompleted += 1
            }
            self.isScanning = false
            self.scanCancelRequested = false
        }
    }

    /// Stop the in-progress background scan after the item currently being
    /// recognized finishes. Results already written are kept; remaining items
    /// stay in their previous OCR state and can be scanned again later.
    func cancelScan() {
        guard isScanning else { return }
        scanCancelRequested = true
    }

    private func enqueueForce(itemID: String) {
        enqueueForceThen(itemID: itemID, completion: nil)
    }

    private func enqueueForceThen(itemID: String, completion: (() -> Void)?) {
        guard let container = modelContainer else { completion?(); return }
        guard inFlightItemIDs.insert(itemID).inserted else { completion?(); return }

        Task {
            defer {
                inFlightItemIDs.remove(itemID)
                completion?()
            }
            let context = container.mainContext
            guard let item = Self.fetchItem(id: itemID, context: context) else { return }
            guard item.contentType == .image, item.imageData != nil else {
                item.ocrStatus = OCRStatus.skipped.rawValue
                item.ocrErrorMessage = nil
                item.ocrUpdatedAt = Date()
                ClipItemStore.saveAndNotifyContent(context)
                return
            }

            let originalURL = Self.originalImageURL(for: item)
            let imageData = item.imageData
            let useMarkdown = markdownEnabled

            item.ocrStatus = OCRStatus.processing.rawValue
            item.ocrErrorMessage = nil
            ClipItemStore.saveAndNotifyContent(context)

            do {
                let result: OCRRecognitionResult
                if let url = originalURL {
                    result = try await ImageOCRService.shared.recognizeText(fileURL: url, markdown: useMarkdown)
                } else if let data = imageData {
                    result = try await ImageOCRService.shared.recognizeText(from: data, markdown: useMarkdown)
                } else {
                    throw ImageOCRError.invalidImage
                }
                await MainActor.run {
                    guard let refreshed = Self.fetchItem(id: itemID, context: context) else { return }
                    refreshed.ocrText = result.text.isEmpty ? nil : result.text
                    refreshed.ocrStatus = result.hasText ? OCRStatus.done.rawValue : OCRStatus.skipped.rawValue
                    refreshed.ocrUpdatedAt = Date()
                    refreshed.ocrErrorMessage = nil
                    ClipItemStore.saveAndNotifyContent(context)
                }
            } catch {
                await MainActor.run {
                    guard let refreshed = Self.fetchItem(id: itemID, context: context) else { return }
                    refreshed.ocrStatus = OCRStatus.failed.rawValue
                    refreshed.ocrUpdatedAt = Date()
                    refreshed.ocrErrorMessage = error.localizedDescription
                    ClipItemStore.saveAndNotifyContent(context)
                }
            }
        }
    }

    /// On-demand OCR that **bypasses** the `isEnabled` toggle. Backs the
    /// "Copy OCR Text" command so it works even when auto-OCR is turned off.
    /// Returns cached text when present; otherwise runs Vision once, persists
    /// the result, and returns it. Returns nil when the item isn't an OCR-able
    /// image or no text was found.
    func recognizeOnDemand(itemID: String) async -> String? {
        guard let container = modelContainer else { return nil }
        let context = container.mainContext
        guard let item = Self.fetchItem(id: itemID, context: context) else { return nil }
        if let existing = item.ocrText, !existing.isEmpty { return existing }
        guard item.contentType == .image, item.imageData != nil else { return nil }

        let originalURL = Self.originalImageURL(for: item)
        let imageData = item.imageData
        let useMarkdown = markdownEnabled

        item.ocrStatus = OCRStatus.processing.rawValue
        item.ocrErrorMessage = nil
        ClipItemStore.saveAndNotifyContent(context)

        do {
            let result: OCRRecognitionResult
            if let url = originalURL {
                result = try await ImageOCRService.shared.recognizeText(fileURL: url, markdown: useMarkdown)
            } else if let data = imageData {
                result = try await ImageOCRService.shared.recognizeText(from: data, markdown: useMarkdown)
            } else {
                return nil
            }
            let text = result.text.isEmpty ? nil : result.text
            if let refreshed = Self.fetchItem(id: itemID, context: context) {
                refreshed.ocrText = text
                refreshed.ocrStatus = result.hasText ? OCRStatus.done.rawValue : OCRStatus.skipped.rawValue
                refreshed.ocrUpdatedAt = Date()
                refreshed.ocrErrorMessage = nil
                ClipItemStore.saveAndNotifyContent(context)
            }
            return text
        } catch {
            if let refreshed = Self.fetchItem(id: itemID, context: context) {
                refreshed.ocrStatus = OCRStatus.failed.rawValue
                refreshed.ocrUpdatedAt = Date()
                refreshed.ocrErrorMessage = error.localizedDescription
                ClipItemStore.saveAndNotifyContent(context)
            }
            return nil
        }
    }

    /// Image clips keep only a small thumbnail in `imageData`; OCR'ing that would miss small
    /// text. Prefer the original on disk — our cache file for raw screenshots, or the user's
    /// file for Finder copies (both resolved by `sourceImageFileURL`). Vision's URL handler
    /// streams it without loading the whole image. nil → fall back to `imageData` (legacy clips).
    private static func originalImageURL(for item: ClipItem) -> URL? {
        item.sourceImageFileURL
    }

    private static func fetchItem(id: String, context: ModelContext) -> ClipItem? {
        let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.itemID == id })
        return try? context.fetch(descriptor).first
    }

    static let enableOCRKey = "ocrEnabled"
    static let autoOCRKey = "ocrAutoProcessImages"
    static let markdownKey = "ocrToMarkdown"
}
