import Foundation
import SwiftData

@MainActor
final class OCRTaskCoordinator: ObservableObject {
    static let shared = OCRTaskCoordinator()

    private var modelContainer: ModelContainer?
    private var inFlightItemIDs = Set<String>()
    /// 还有几个 `recognizeOnDemandWithProgress` 在共用那条「正在识别」提示。
    /// 用计数而不是布尔：两次现场识别重叠时（面板一处、主窗口一处），先完成的那次
    /// 若直接收掉提示，后完成的那次就再也收不掉自己的——而它是常驻提示（duration nil），
    /// 会一直挂在屏幕上。
    private var progressToastHolders = 0
    /// 提示的「第几轮」。超时兜底的 watchdog 靠它认出自己守的那轮是否已经结束，
    /// 免得收掉下一轮刚弹出来的提示。
    private var progressToastGeneration = 0

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

    /// Manual retry is a user-initiated action like "Paste OCR Text", so it
    /// bypasses the `isEnabled` master toggle — that toggle only gates
    /// background OCR. Without this, a stale cached result (e.g. produced by an
    /// older engine) could never be refreshed while background OCR is off.
    func retry(itemID: String) {
        enqueueForce(itemID: itemID)
    }

    func canRetry(item: ClipItem) -> Bool {
        item.contentType == .image && item.imageData != nil
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

    /// `recognizeOnDemand` + 一个「正在识别图片文字…」提示。
    ///
    /// 为什么要提示：命令菜单里按 G 时面板已经关了，识别是在没有任何界面的情况下跑的，
    /// 不给提示就是「按了完全没反应」。0.4s 内完成不弹：快路径是 0.2s 级别，无条件弹会闪。
    func recognizeOnDemandWithProgress(itemID: String) async -> String? {
        // 返回值 = 这一次到底弹出提示了没有；取消后 `value` 立刻返回 false。
        let progress = Task { @MainActor [weak self] () -> Bool in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return false }
            self.showProgressToast()
            return true
        }
        let text = await recognizeOnDemand(itemID: itemID, preferSpeed: true)
        progress.cancel()
        if await progress.value {
            hideProgressToast()
        }
        return text
    }

    private func showProgressToast() {
        progressToastHolders += 1
        let generation = progressToastGeneration
        ToastCenter.shared.show(ToastDescriptor(
            message: L10n.tr("detail.ocr.processing"), icon: .info, duration: nil
        ))
        // 这是常驻提示（duration nil），谁弹谁负责收。识别卡住时不能让它永远挂在屏幕上：
        // 用户实测过一次 ANE 编译期间提示挂了几分钟，切到别的 App 也还跟着。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, generation == self.progressToastGeneration else { return }
            self.hideProgressToast(force: true)
        }
    }

    /// `force` 用于超时兜底：直接清零，之后迟到的那几次完成不再重复收提示
    /// （`holders` 已是 0 就直接返回，免得把这期间别处弹的提示顺手关掉）。
    private func hideProgressToast(force: Bool = false) {
        guard progressToastHolders > 0 else { return }
        progressToastHolders = force ? 0 : progressToastHolders - 1
        guard progressToastHolders == 0 else { return }
        progressToastGeneration &+= 1
        ToastCenter.shared.dismiss()
    }

    /// On-demand OCR that **bypasses** the `isEnabled` toggle. Backs the
    /// "Copy OCR Text" command so it works even when auto-OCR is turned off.
    /// Returns cached text when present; otherwise runs Vision once, persists
    /// the result, and returns it. Returns nil when the item isn't an OCR-able
    /// image or no text was found.
    ///
    /// - Parameter preferSpeed: 用户正等着这段文字（快捷面板按 G、主窗口点「粘贴 OCR
    ///   文字」）时传 true，跳过版面识别引擎。`RecognizeDocumentsRequest` 首次调用要让
    ///   ANE 编译模型，而且**每个 app 各编译一次**：实测同一张图，脚本进程首次 48s、
    ///   换成 PasteMemo Dev 又让 ANECompilerService 满载跑了 3 分钟，之后才降到 0.11s。
    ///   `VNRecognizeTextRequest` 同一张图冷调用 0.24s。交互路径宁可要纯文本也不能让
    ///   用户干等几分钟；版面识别留给后台自动 OCR（`enqueueForce`，走 markdownEnabled）。
    ///
    ///   两条路不会打架：走到现场识别就意味着这张图没有缓存结果，也就意味着用户没开
    ///   自动 OCR——开了的话图片入库时后台已经用版面引擎识别过了。想给某张图补一份
    ///   Markdown 版面，用命令菜单里的「重新识别」（`retry`，不受开关限制）。
    func recognizeOnDemand(itemID: String, preferSpeed: Bool = false) async -> String? {
        guard let container = modelContainer else { return nil }
        let context = container.mainContext
        guard let item = Self.fetchItem(id: itemID, context: context) else { return nil }
        if let existing = item.ocrText, !existing.isEmpty { return existing }
        guard item.contentType == .image, item.imageData != nil else { return nil }

        let originalURL = Self.originalImageURL(for: item)
        let imageData = item.imageData
        let useMarkdown = markdownEnabled && !preferSpeed

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

    /// 现场识别完成后，这段文字该粘进目标 App 还是只落到剪贴板。
    enum OnDemandPasteRoute: Equatable {
        case paste
        case copyOnly
    }

    /// 现场 OCR 完成后的去向判定。
    ///
    /// 文档识别引擎整机首次调用要加载模型（实测几十秒），这期间快捷面板早就关了、用户
    /// 也切走了；仍朝当初记下的 pid 投 ⌘V 的话，文字会粘进一个看不见的窗口——表现就是
    /// 「按了没反应，等多久都不出现」。所以慢路径要求目标仍在前台，否则只写剪贴板。
    ///
    /// `elapsed < grace` 时无条件粘贴：热路径是 0.1s 级别，用户不可能切走，而
    /// `frontmostApplication` 的更新是异步的，这么短的时间里问它容易误判成「切走了」。
    nonisolated static func onDemandPasteRoute(
        elapsed: TimeInterval,
        grace: TimeInterval,
        hasTarget: Bool,
        targetIsFrontmost: Bool
    ) -> OnDemandPasteRoute {
        guard hasTarget else { return .copyOnly }
        if elapsed < grace { return .paste }
        return targetIsFrontmost ? .paste : .copyOnly
    }

    static let enableOCRKey = "ocrEnabled"
    static let autoOCRKey = "ocrAutoProcessImages"
    static let markdownKey = "ocrToMarkdown"
}
