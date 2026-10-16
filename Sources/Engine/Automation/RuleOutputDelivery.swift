import Foundation
import OSLog

private let log = Logger(subsystem: "com.lifedever.pastememo", category: "RuleOutput")

/// The two rule outputs that leave PasteMemo: a file in a folder and a webhook
/// POST. Shared by the manual executor (⌘K / context menu) and the capture path.
@MainActor
enum RuleOutputDelivery {

    /// Injectable for tests; same shape as the AI client's transport.
    static var webhookTransport: AITransport = URLSessionTransport()

    /// A POST body over this size is refused rather than sent.
    static let maxWebhookCharacters = 1_000_000

    // MARK: - Validation (editor + runtime)

    static func folderURL(from param: String) -> URL? {
        let trimmed = param.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    nonisolated static func webhookURL(from param: String) -> URL? {
        let trimmed = param.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Same boundary as the AI rewrite: sensitive clips and clips from apps on the
    /// AI-access blocklist never leave the Mac.
    static func mayLeaveDevice(isSensitive: Bool, sourceAppBundleID: String?) -> Bool {
        guard !isSensitive else { return false }
        guard let bundleID = sourceAppBundleID else { return true }
        return !MCPSourceAppBlocklist.shared.blockedBundleIDs.contains(bundleID)
    }

    // MARK: - Save to folder

    /// Writes one clip's result into `folder`. Text results (including OCR'd text)
    /// become a .txt; image and file clips keep their original bytes.
    static func save(text: String, of item: ClipItem, asText: Bool, into folder: URL) -> URL? {
        if asText {
            return ClipboardManager.shared.saveTextToFolder(text, folder: folder)
        }
        if item.contentType == .image, let data = item.imageBytesForExport() {
            return ClipboardManager.shared.saveImageToFolder(data, folder: folder)
        }
        if item.contentType.isFileBased {
            var saved: URL?
            for path in item.content.components(separatedBy: "\n") where !path.isEmpty {
                let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                if let url = ClipboardManager.copyImageFileToFolder(sourceURL: source, folder: folder) {
                    saved = url
                }
            }
            return saved
        }
        return ClipboardManager.shared.saveTextToFolder(text, folder: folder)
    }

    // MARK: - Webhook

    struct WebhookPayload: Encodable, Sendable {
        let content: String
        let contentType: String
        let sourceApp: String?
        let rule: String
        let createdAt: String
    }

    enum WebhookError: Error {
        case invalidURL
        case tooLarge
        case status(Int)
    }

    static func payload(content: String, item: ClipItem, ruleName: String, asText: Bool) -> WebhookPayload {
        WebhookPayload(
            content: content,
            contentType: asText ? ClipContentType.text.rawValue : item.contentType.rawValue,
            sourceApp: item.sourceAppBundleID,
            rule: ruleName,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    static func post(_ payload: WebhookPayload, to param: String) async throws {
        guard let url = webhookURL(from: param) else { throw WebhookError.invalidURL }
        guard payload.content.count <= maxWebhookCharacters else { throw WebhookError.tooLarge }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("PasteMemo", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(payload)
        let (_, response) = try await webhookTransport.send(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebhookError.status(http.statusCode)
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case WebhookError.invalidURL: return L10n.tr("automation.output.webhook.invalidURL")
        case WebhookError.tooLarge: return L10n.tr("automation.output.webhook.tooLarge")
        case WebhookError.status(let code): return L10n.tr("automation.output.webhook.failedStatus", code)
        default: return L10n.tr("automation.output.webhook.failed", error.localizedDescription)
        }
    }

    // MARK: - Capture path

    /// After an automatic rule stored `item`: add the file copy / POST its output
    /// asks for. Failures are logged, not shown — nobody asked for this copy.
    static func deliverOnCapture(_ outputs: [CaptureOutput], item: ClipItem) {
        for output in outputs {
            let asText = item.contentType.isMergeable
            switch output.mode {
            case .saveToFile:
                guard let folder = folderURL(from: output.param) else {
                    log.error("save-to-folder rule \(output.ruleName, privacy: .public): folder missing")
                    continue
                }
                if save(text: item.content, of: item, asText: asText, into: folder) == nil {
                    log.error("save-to-folder rule \(output.ruleName, privacy: .public): write failed")
                }
            case .postWebhook:
                guard asText, mayLeaveDevice(isSensitive: item.isSensitive, sourceAppBundleID: item.sourceAppBundleID) else {
                    continue
                }
                let body = payload(content: item.content, item: item, ruleName: output.ruleName, asText: true)
                let param = output.param
                let ruleName = output.ruleName
                Task { @MainActor in
                    do {
                        try await post(body, to: param)
                    } catch {
                        log.error("webhook rule \(ruleName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    }
                }
            case .replaceItem, .newItem, .clipboard, .pasteToFrontmost:
                continue
            }
        }
    }
}

/// A capture-path output that leaves PasteMemo, carried out of `AutomationEngine`
/// so the capture code can deliver it once the clip is stored.
struct CaptureOutput: Sendable, Equatable {
    let mode: RuleOutputMode
    let param: String
    let ruleName: String
}
