import AppKit
import SwiftUI

@MainActor
final class AIReadyPaste: ObservableObject {
    static let shared = AIReadyPaste()

    private init() {}

    /// Convert a clip item's content into AI-friendly markdown format
    func formatForAI(_ item: ClipItem) -> String {
        switch item.contentType {
        case .link:
            return formatLink(item.content)
        case .image:
            return "[Image content — paste directly]"
        case .file, .video, .audio, .document, .archive, .application:
            return item.content
        default:
            return formatText(item.content)
        }
    }

    /// Format raw clipboard text as AI-friendly output
    func formatFromClipboard() -> String? {
        guard let content = NSPasteboard.general.string(forType: .string) else { return nil }
        let detected = ClipboardManager.shared.detectContentType(content)

        switch detected.type {
        case .link:
            return formatLink(content)
        case .image:
            return nil
        case .file, .video, .audio, .document, .archive, .application:
            return content
        default:
            return formatText(content)
        }
    }

    // MARK: - Formatters

    private func formatLink(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(trimmed)](\(trimmed))"
    }

    private func formatText(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)

        // Short text: return as-is
        if lines.count <= 3 {
            return trimmed
        }

        // Longer text: wrap in a blockquote for clarity
        return lines.map { "> \($0)" }.joined(separator: "\n")
    }

}
