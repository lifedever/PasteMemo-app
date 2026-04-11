import Foundation
import SwiftData

@Model
final class SnippetItem {
    var snippetID: String = UUID().uuidString
    var title: String
    var content: String
    var contentTypeRaw: String
    var groupName: String?
    var tagsRaw: String?
    var isPinned: Bool
    var createdAt: Date
    var lastUsedAt: Date
    var usageCount: Int
    @Attribute(.externalStorage) var richTextData: Data?
    var richTextType: String?

    init(
        title: String = "",
        content: String = "",
        contentType: ClipContentType = .text,
        groupName: String? = nil,
        tags: [String] = [],
        isPinned: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        usageCount: Int = 0,
        richTextData: Data? = nil,
        richTextType: String? = nil
    ) {
        self.title = title
        self.content = content
        self.contentTypeRaw = contentType.rawValue
        self.groupName = groupName
        self.tagsRaw = Self.serializeTags(tags)
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.usageCount = usageCount
        self.richTextData = richTextData
        self.richTextType = richTextType
    }

    var contentType: ClipContentType {
        get { ClipContentType(rawValue: contentTypeRaw) ?? .text }
        set { contentTypeRaw = newValue.rawValue }
    }

    var tags: [String] {
        get { Self.deserializeTags(tagsRaw ?? "") }
        set { tagsRaw = Self.serializeTags(newValue) }
    }

    var tagsText: String {
        get { tags.joined(separator: ", ") }
        set { tags = Self.parseTags(from: newValue) }
    }

    @MainActor
    var resolvedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        let firstLine = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        if let firstLine, !firstLine.isEmpty {
            return String(firstLine.prefix(60))
        }
        return L10n.tr("snippet.untitled")
    }

    static func parseTags(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        return text
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, tag in
                guard !result.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
                result.append(tag)
            }
    }

    private static func serializeTags(_ tags: [String]) -> String {
        parseTags(from: tags.joined(separator: ",")).joined(separator: "\n")
    }

    private static func deserializeTags(_ raw: String) -> [String] {
        parseTags(from: raw.replacingOccurrences(of: "\n", with: ","))
    }
}
