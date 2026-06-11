import Foundation
import Vision
import AppKit

enum ImageOCRError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Unable to decode image for OCR."
        }
    }
}

struct OCRRecognitionResult {
    let text: String
    let hasText: Bool
}

actor ImageOCRService {
    static let shared = ImageOCRService()

    private init() {}

    /// OCR an in-memory image. When `markdown` is on and the OS supports it
    /// (macOS 26+), recognition runs through `RecognizeDocumentsRequest` and
    /// returns layout-aware Markdown; otherwise — and whenever document OCR
    /// finds no content — it falls back to plain-text `VNRecognizeTextRequest`.
    func recognizeText(from imageData: Data, markdown: Bool) async throws -> OCRRecognitionResult {
        let appLanguage = await MainActor.run { LanguageManager.shared.current }

        if markdown, #available(macOS 26.0, *) {
            if let text = try? await DocumentMarkdownOCRService().recognizeMarkdown(imageData: imageData, appLanguage: appLanguage),
               !text.isEmpty {
                return OCRRecognitionResult(text: text, hasText: true)
            }
        }

        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw ImageOCRError.invalidImage
        }
        return try runLegacyOCR(handler: VNImageRequestHandler(cgImage: cgImage), appLanguage: appLanguage)
    }

    /// File-URL OCR path. Used for file-backed image clips so OCR runs against
    /// the original file's full resolution rather than the small thumbnail we
    /// keep in `ClipItem.imageData`. Both the Markdown and plain-text engines
    /// stream the image by URL, so this works for multi-GB originals without
    /// loading them into memory.
    func recognizeText(fileURL: URL, markdown: Bool) async throws -> OCRRecognitionResult {
        let appLanguage = await MainActor.run { LanguageManager.shared.current }

        if markdown, #available(macOS 26.0, *) {
            if let text = try? await DocumentMarkdownOCRService().recognizeMarkdown(fileURL: fileURL, appLanguage: appLanguage),
               !text.isEmpty {
                return OCRRecognitionResult(text: text, hasText: true)
            }
        }

        return try runLegacyOCR(handler: VNImageRequestHandler(url: fileURL), appLanguage: appLanguage)
    }

    /// Plain-text OCR via `VNRecognizeTextRequest`. Used directly on macOS < 26
    /// and as a fallback when document OCR detects no structured content.
    private func runLegacyOCR(handler: VNImageRequestHandler, appLanguage: String) throws -> OCRRecognitionResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = Self.preferredRecognitionLanguages(appLanguage: appLanguage)
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = !Self.prefersChinese(appLanguage: appLanguage)

        try handler.perform([request])

        let rawLines = request.results?.compactMap { observation in
            observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? []

        let lines = rawLines.filter { !$0.isEmpty }
        let text = lines.joined(separator: "\n")
        return OCRRecognitionResult(text: text, hasText: !text.isEmpty)
    }

    nonisolated static func preferredRecognitionLanguages(appLanguage: String) -> [String] {
        var ordered: [String] = []

        func append(_ language: String) {
            guard !language.isEmpty else { return }
            if !ordered.contains(language) {
                ordered.append(language)
            }
        }

        if prefersChinese(appLanguage: appLanguage) {
            append("zh-Hans")
            append("zh-Hant")
            append("en-US")
        } else {
            append(normalizedRecognitionLanguage(for: appLanguage))
            append("zh-Hans")
            append("zh-Hant")
            append("en-US")
        }

        for language in Locale.preferredLanguages {
            append(normalizedRecognitionLanguage(for: language))
        }

        return ordered
    }

    nonisolated static func normalizedRecognitionLanguage(for language: String) -> String {
        let lower = language.lowercased()
        if lower.hasPrefix("zh-hans") || lower == "zh-cn" || lower == "zh-sg" { return "zh-Hans" }
        if lower.hasPrefix("zh-hant") || lower == "zh-tw" || lower == "zh-hk" || lower == "zh-mo" { return "zh-Hant" }
        if lower == "zh" { return "zh-Hans" }
        return Locale(identifier: language).identifier.replacingOccurrences(of: "_", with: "-")
    }

    nonisolated static func prefersChinese(appLanguage: String) -> Bool {
        normalizedRecognitionLanguage(for: appLanguage).hasPrefix("zh-")
    }
}
