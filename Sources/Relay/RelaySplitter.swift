import Foundation

enum RelayDelimiter: Hashable {
    case newline
    case comma
    case chineseComma
    case custom(String)

    var value: String {
        switch self {
        case .newline: "\n"
        case .comma: ","
        case .chineseComma: "、"
        case .custom(let s): s
        }
    }

    var displayName: String {
        switch self {
        case .newline: "relay.delimiter.newline"
        case .comma: "relay.delimiter.comma"
        case .chineseComma: "relay.delimiter.chineseComma"
        case .custom: "relay.delimiter.custom"
        }
    }
}

enum RelaySplitter {

    static let PRESET_DELIMITERS: [RelayDelimiter] = [
        .newline, .comma, .chineseComma,
    ]

    /// Split text by delimiter. Returns nil if delimiter not found or result is single item.
    static func split(_ text: String, by delimiter: RelayDelimiter) -> [String]? {
        let parts = text
            .components(separatedBy: delimiter.value)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else { return nil }
        return parts
    }
}
