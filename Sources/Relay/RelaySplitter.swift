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

/// Delimiter presets of the「拆分并接力」automation action's editor. Splitting a clip by
/// hand goes through `ClipSplitter` (the split page).
enum RelaySplitter {

    static let PRESET_DELIMITERS: [RelayDelimiter] = [
        .newline, .comma, .chineseComma,
    ]
}
