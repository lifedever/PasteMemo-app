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

    private init() {}

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enableOCRKey) as? Bool ?? true
    }

    var autoProcessEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoOCRKey) as? Bool ?? true
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

        let ids = pending.map { $0.itemID }
        Task {
            for id in ids {
                await withCheckedContinuation { continuation in
                    enqueueForceThen(itemID: id) {
                        continuation.resume()
                    }
                }
                self.scanCompleted += 1
            }
            self.isScanning = false
        }
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
            guard item.contentType == .image, let imageData = item.imageData else {
                item.ocrStatus = OCRStatus.skipped.rawValue
                item.ocrErrorMessage = nil
                item.ocrUpdatedAt = Date()
                ClipItemStore.saveAndNotifyContent(context)
                return
            }

            item.ocrStatus = OCRStatus.processing.rawValue
            item.ocrErrorMessage = nil
            ClipItemStore.saveAndNotifyContent(context)

            do {
                let result = try await ImageOCRService.shared.recognizeText(from: imageData)
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

    private static func fetchItem(id: String, context: ModelContext) -> ClipItem? {
        let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.itemID == id })
        return try? context.fetch(descriptor).first
    }

    static let enableOCRKey = "ocrEnabled"
    static let autoOCRKey = "ocrAutoProcessImages"
}
