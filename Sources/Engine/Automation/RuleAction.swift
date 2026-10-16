import Foundation

enum RuleAction: Codable, Equatable, Hashable, Sendable {
    case lowercased
    case uppercased
    case trimWhitespace
    case removeBlankLines
    case urlEncode
    case urlDecode
    case removeQueryParams(patterns: [String])
    case regexReplace(pattern: String, replacement: String)
    case addPrefix(text: String)
    case addSuffix(text: String)
    case stripRichText
    case assignGroup(name: String)
    case markSensitive
    case unmarkSensitive
    case pin
    case unpin
    case skipCapture
    /// Stop evaluating further automatic rules once the rule containing this
    /// action has applied. Only meaningful on the capture path.
    case stopProcessing
    /// Close the Quick Panel after the rule ran. Manual-trigger only — there is
    /// no panel to close on the capture path.
    case closeQuickPanel
    /// Manual-trigger only. Runs the named macOS Shortcut with the current clip
    /// as input (image → --input-path, text → stdin, file → --input-path). The
    /// Shortcut's output is written to NSPasteboard so PasteMemo captures it as
    /// a new clip.
    case runShortcut(name: String)
    /// Manual-trigger only. Sends the clip text plus `prompt` to the configured
    /// OpenAI-compatible endpoint and uses the reply as the transformed text. Never
    /// runs on capture (privacy + bill), never on Relay (synchronous path).
    /// `thinking` / `temperature` / `timeoutSeconds` override the global AI settings when
    /// set; `nil` follows Settings → AI 服务. Older rules without these keys decode as nil.
    case aiTransform(prompt: String, thinking: AIThinkingMode? = nil, temperature: Double? = nil, timeoutSeconds: Double? = nil)
    /// Reformat a color value. `format` is a `ColorFormat` raw value; text that
    /// isn't a color passes through unchanged.
    case convertColor(format: String)
    /// Keep only the verification code found in the text. No code → unchanged.
    case extractVerificationCode
    /// Keep only the http(s) links in the text, one per line. No link → unchanged.
    case extractLinks
    /// Manual-trigger only, image clips. Recognises the text in the image; the
    /// actions after it and the output work on that text.
    case runOCR
    /// Manual-trigger only. Opens the result as a link, or the first link in it.
    case openLink
    /// Manual-trigger only. Quick Look (or Preview.app for images / PDFs).
    case openInPreview
    /// Manual-trigger only, file clips. Reveals the file in Finder.
    case showInFinder
    /// Manual-trigger only. Appends the result to the Relay queue.
    case addToRelay
    /// Manual-trigger only. Splits the result by `delimiter` (empty = newline)
    /// and appends the pieces to the Relay queue.
    case splitToRelay(delimiter: String)
    /// Manual-trigger only. Deletes the original clip after the rule ran; the
    /// usual undo toast applies.
    case deleteItem
    /// Plays a sound when the rule applies. `name` is a `SoundManager.SoundSource`
    /// storage key (`system:Glass`, `custom:Bubble`).
    case playSound(name: String)
    // Text toolbox — see `TextTools` for exact behaviour.
    case base64Encode
    case base64Decode
    case jsonFormat
    case jsonMinify
    case toCamelCase
    case toSnakeCase
    case toHalfWidth
    case toFullWidth
    case simplifiedToTraditional
    case removeDuplicateLines
    case sortLines(ascending: Bool)
    case joinLines(separator: String)
    case removeHTMLTags

    @MainActor var displayLabel: String {
        switch self {
        case .lowercased: L10n.tr("automation.action.lowercased")
        case .uppercased: L10n.tr("automation.action.uppercased")
        case .trimWhitespace: L10n.tr("automation.action.trimWhitespace")
        case .removeBlankLines: L10n.tr("automation.action.removeBlankLines")
        case .urlEncode: L10n.tr("automation.action.urlEncode")
        case .urlDecode: L10n.tr("automation.action.urlDecode")
        case .removeQueryParams: L10n.tr("automation.action.removeQueryParams")
        case .regexReplace: L10n.tr("automation.action.regexReplace")
        case .addPrefix: L10n.tr("automation.action.addPrefix")
        case .addSuffix: L10n.tr("automation.action.addSuffix")
        case .stripRichText: L10n.tr("automation.action.stripRichText")
        case .assignGroup(let name): L10n.tr("automation.action.assignGroup") + ": " + name
        case .markSensitive: L10n.tr("automation.action.markSensitive")
        case .unmarkSensitive: L10n.tr("sensitive.unmarkSensitive")
        case .pin: L10n.tr("automation.action.pin")
        case .unpin: L10n.tr("action.unpin")
        case .skipCapture: L10n.tr("automation.action.skipCapture")
        case .stopProcessing: L10n.tr("automation.action.stopProcessing")
        case .closeQuickPanel: L10n.tr("automation.action.closeQuickPanel")
        case .runShortcut(let name): L10n.tr("automation.action.runShortcut") + ": " + name
        case .aiTransform: L10n.tr("automation.action.aiTransform")
        case .convertColor(let format): L10n.tr("automation.action.convertColor") + ": " + format
        case .extractVerificationCode: L10n.tr("automation.action.extractVerificationCode")
        case .extractLinks: L10n.tr("automation.action.extractLinks")
        case .runOCR: L10n.tr("automation.action.runOCR")
        case .openLink: L10n.tr("cmd.openLink")
        case .openInPreview: L10n.tr("cmd.quickLook")
        case .showInFinder: L10n.tr("cmd.showInFinder")
        case .addToRelay: L10n.tr("relay.addToQueue")
        case .splitToRelay: L10n.tr("relay.splitAndRelay")
        case .deleteItem: L10n.tr("automation.action.deleteItem")
        case .playSound: L10n.tr("automation.action.playSound")
        case .base64Encode: L10n.tr("automation.action.base64Encode")
        case .base64Decode: L10n.tr("automation.action.base64Decode")
        case .jsonFormat: L10n.tr("automation.action.jsonFormat")
        case .jsonMinify: L10n.tr("automation.action.jsonMinify")
        case .toCamelCase: L10n.tr("automation.action.toCamelCase")
        case .toSnakeCase: L10n.tr("automation.action.toSnakeCase")
        case .toHalfWidth: L10n.tr("automation.action.toHalfWidth")
        case .toFullWidth: L10n.tr("automation.action.toFullWidth")
        case .simplifiedToTraditional: L10n.tr("automation.action.simplifiedToTraditional")
        case .removeDuplicateLines: L10n.tr("automation.action.removeDuplicateLines")
        case .sortLines: L10n.tr("automation.action.sortLines")
        case .joinLines: L10n.tr("automation.action.joinLines")
        case .removeHTMLTags: L10n.tr("automation.action.removeHTMLTags")
        }
    }

    func execute(on content: String) -> String {
        switch self {
        case .lowercased:
            return content.lowercased()
        case .uppercased:
            return content.uppercased()
        case .trimWhitespace:
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        case .removeBlankLines:
            return removeExcessiveBlankLines(content)
        case .urlEncode:
            // RFC 3986 unreserved characters: ALPHA / DIGIT / "-" / "." / "_" / "~"
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return content.addingPercentEncoding(withAllowedCharacters: allowed) ?? content
        case .urlDecode:
            return content.removingPercentEncoding ?? content
        case .removeQueryParams(let patterns):
            return removeMatchingQueryParams(from: content, patterns: patterns)
        case .regexReplace(let pattern, let replacement):
            return applyRegexReplace(content, pattern: pattern, replacement: replacement)
        case .addPrefix(let text):
            return text + content
        case .addSuffix(let text):
            return content + text
        case .convertColor(let format):
            guard let color = ColorConverter.parse(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return content
            }
            return color.formatted(ColorFormat(rawValue: format) ?? .hex)
        case .extractVerificationCode:
            return VerificationCodeExtractor.extract(from: content) ?? content
        case .extractLinks:
            let links = TextEntityExtractor.linkURLs(in: content)
            return links.isEmpty ? content : links.joined(separator: "\n")
        case .base64Encode: return TextTools.base64Encode(content)
        case .base64Decode: return TextTools.base64Decode(content)
        case .jsonFormat: return TextTools.formatJSON(content)
        case .jsonMinify: return TextTools.minifyJSON(content)
        case .toCamelCase: return TextTools.camelCase(content)
        case .toSnakeCase: return TextTools.snakeCase(content)
        case .toHalfWidth: return TextTools.halfWidth(content)
        case .toFullWidth: return TextTools.fullWidth(content)
        case .simplifiedToTraditional: return TextTools.simplifiedToTraditional(content)
        case .removeDuplicateLines: return TextTools.removeDuplicateLines(content)
        case .sortLines(let ascending): return TextTools.sortLines(content, ascending: ascending)
        case .joinLines(let separator): return TextTools.joinLines(content, separator: separator)
        case .removeHTMLTags: return TextTools.removeHTMLTags(content)
        case .stripRichText, .assignGroup, .markSensitive, .unmarkSensitive, .pin, .unpin,
             .skipCapture, .stopProcessing, .closeQuickPanel, .runShortcut, .aiTransform,
             .runOCR, .openLink, .openInPreview, .showInFinder, .addToRelay, .splitToRelay,
             .deleteItem, .playSound:
            // Not synchronous text transforms — applied by ActionExecutor / AutomationEngine.
            return content
        }
    }

    // MARK: - Descriptor dimensions

    /// What the action does to the clip. Drives where each action is applied:
    /// `.transform` runs through `execute(on:)`, the others are handled by
    /// `ActionExecutor` (metadata / side effects) or the engine (`stopProcessing`).
    var kind: ActionKind {
        switch self {
        case .lowercased, .uppercased, .trimWhitespace, .removeBlankLines, .urlEncode,
             .urlDecode, .removeQueryParams, .regexReplace, .addPrefix, .addSuffix, .aiTransform,
             .convertColor, .extractVerificationCode, .extractLinks, .runOCR,
             .base64Encode, .base64Decode, .jsonFormat, .jsonMinify, .toCamelCase, .toSnakeCase,
             .toHalfWidth, .toFullWidth, .simplifiedToTraditional, .removeDuplicateLines,
             .sortLines, .joinLines, .removeHTMLTags:
            return .transform
        case .stripRichText, .assignGroup, .markSensitive, .unmarkSensitive, .pin, .unpin:
            return .metadata
        case .skipCapture, .stopProcessing, .closeQuickPanel, .openLink, .openInPreview,
             .showInFinder, .addToRelay, .splitToRelay, .deleteItem, .playSound:
            return .sideEffect
        case .runShortcut:
            return .external
        }
    }

    /// Which clips the action is meaningful for. Text transforms are text-only
    /// (OCR is the one transform that reads an image); metadata, flow-control and
    /// Shortcuts accept anything.
    var inputKind: InputKind {
        switch self {
        case .runOCR: return .image
        case .showInFinder: return .file
        case .openLink, .splitToRelay: return .text
        default: break
        }
        switch kind {
        case .transform: return .text
        case .metadata, .sideEffect, .external: return .any
        }
    }

    /// Async actions can't run on the synchronous capture / Relay paths — the
    /// engine would silently return the original text. Such actions force the
    /// rule to manual trigger.
    var isAsync: Bool {
        switch self {
        case .runShortcut, .aiTransform, .runOCR: return true
        default: return false
        }
    }

    /// Runtime environment the action needs. `ActionExecutor` skips the action
    /// when the host can't satisfy it; the rule editor uses this to lock the
    /// trigger mode so a rule never silently no-ops.
    var requiredContext: ActionContextRequirement {
        switch self {
        case .closeQuickPanel: return .panel
        case .runShortcut, .runOCR: return .manualTrigger
        case .aiTransform: return [.manualTrigger, .network]
        // Opening windows, touching the Relay queue or deleting on every copy
        // would be a surprise; these only run when the user picks the rule.
        case .openLink, .openInPreview, .showInFinder, .addToRelay, .splitToRelay, .deleteItem:
            return .manualTrigger
        default: return []
        }
    }

    /// Side effects that take the user somewhere else; the Quick Panel closes
    /// first so the browser / Finder window isn't left behind it.
    var leavesQuickPanel: Bool {
        switch self {
        case .openLink, .showInFinder: return true
        default: return false
        }
    }

    /// Manual-only actions: async ones and those needing a panel.
    var requiresManualTrigger: Bool {
        isAsync || !requiredContext.isDisjoint(with: [.panel, .manualTrigger])
    }

    // MARK: - Private Helpers

    private func removeExcessiveBlankLines(_ content: String) -> String {
        // Collapse any consecutive blank lines (2+ newlines) into a single newline
        guard let regex = try? NSRegularExpression(pattern: "\\n{2,}") else { return content }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: "\n")
    }

    private func removeMatchingQueryParams(from urlString: String, patterns: [String]) -> String {
        guard var components = URLComponents(string: urlString),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else { return urlString }

        let filtered = queryItems.filter { item in
            !patterns.contains { pattern in
                matchesWildcard(item.name, pattern: pattern)
            }
        }

        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.string ?? urlString
    }

    private func matchesWildcard(_ name: String, pattern: String) -> Bool {
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return name.hasPrefix(prefix)
        }
        return name == pattern
    }

    private func applyRegexReplace(_ content: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: replacement)
    }
}

// MARK: - Descriptor types

enum ActionKind: Sendable {
    /// Content → content, chainable.
    case transform
    /// Changes clip attributes (pin / sensitive / group / rich text), not content.
    case metadata
    /// Produces an effect without touching the clip (stop, close panel, skip).
    case sideEffect
    /// Hands the clip to something outside PasteMemo (Shortcuts).
    case external
}

/// Coarse clip category an action accepts. Deliberately not `Set<ClipContentType>`:
/// that enum carries legacy cases and grows over time; the three buckets here map
/// onto `isMergeable` / `isFileBased` and stay stable.
enum InputKind: Sendable {
    case text
    case image
    case file
    case any

    func accepts(_ type: ClipContentType) -> Bool {
        switch self {
        case .any: return true
        case .text: return type.isMergeable
        case .image: return type == .image
        case .file: return type.isFileBased
        }
    }
}

struct ActionContextRequirement: OptionSet, Sendable {
    let rawValue: Int
    /// Needs a Quick Panel to act on.
    static let panel = ActionContextRequirement(rawValue: 1 << 0)
    /// Needs a paste target (frontmost app before the panel opened).
    static let targetApp = ActionContextRequirement(rawValue: 1 << 1)
    /// Only runs when the user triggers the rule explicitly (never on capture).
    static let manualTrigger = ActionContextRequirement(rawValue: 1 << 2)
    /// Sends clip content off-device.
    static let network = ActionContextRequirement(rawValue: 1 << 3)
}
