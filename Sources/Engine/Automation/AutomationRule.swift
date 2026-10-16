import Foundation
import SwiftData

enum TriggerMode: String, Codable, Sendable {
    case automatic
    case manual
}

enum ConditionLogic: String, Codable, Sendable {
    case all   // AND: all conditions must match
    case any   // OR: any condition must match
}

/// Where a rule's result goes. One per rule (a field, not an action): a rule has
/// exactly one destination, and this keeps ordering / duplication out of the
/// action chain. How each mode behaves per execution path is decided by
/// `ActionExecutor`; on the capture path `.clipboard` and `.pasteToFrontmost`
/// both mean "mirror the result back to the pasteboard" (the old
/// `writeBackToPasteboard` toggle).
enum RuleOutputMode: String, Codable, Sendable, CaseIterable {
    /// Overwrite the clip in place (manual) / store the processed text (capture).
    case replaceItem
    /// Insert a new clip with the result, leave the original untouched.
    case newItem
    /// Write the result to the system pasteboard only — no history entry.
    case clipboard
    /// Write to the pasteboard and paste into the app the panel was opened from.
    case pasteToFrontmost
    /// Write the result into the folder in `outputParam` (text → .txt, image /
    /// file clips → their bytes). On capture the clip is stored as well.
    case saveToFile
    /// POST the result as JSON to the URL in `outputParam`. On capture the clip is
    /// stored as well. Sensitive clips are never sent.
    case postWebhook

    /// On capture there is no paste target and the clip is being created anyway,
    /// so the only question is whether to mirror the result to the pasteboard.
    var mirrorsToPasteboardOnCapture: Bool {
        switch self {
        case .clipboard, .pasteToFrontmost: return true
        case .replaceItem, .newItem, .saveToFile, .postWebhook: return false
        }
    }

    /// Modes that need `outputParam` (a folder path / a URL).
    var needsParameter: Bool {
        self == .saveToFile || self == .postWebhook
    }
}

@Model
final class AutomationRule {
    var ruleID: String = UUID().uuidString
    var name: String = ""
    var enabled: Bool = true
    var isBuiltIn: Bool = false
    var sortOrder: Int = 0
    var triggerModeRaw: String = TriggerMode.automatic.rawValue
    var notifyBeforeApply: Bool = false
    var notifyOnTrigger: Bool = false
    /// Legacy storage for `outputMode`. Still written on every `outputMode` change so
    /// a downgraded build keeps the "mirror to pasteboard" behaviour; read only as a
    /// fallback when `outputModeRaw` is empty (rules created before the field existed).
    var writeBackToPasteboard: Bool = false
    var outputModeRaw: String = ""
    /// Parameter of the output mode: folder path for `.saveToFile`, URL for
    /// `.postWebhook`. Empty for the other modes.
    var outputParam: String = ""
    var conditionLogicRaw: String = ConditionLogic.all.rawValue
    var conditionsData: Data = Data()
    var actionsData: Data = Data()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Transient
    var triggerMode: TriggerMode {
        get { TriggerMode(rawValue: triggerModeRaw) ?? .automatic }
        set { triggerModeRaw = newValue.rawValue }
    }

    @Transient
    var conditionLogic: ConditionLogic {
        get { ConditionLogic(rawValue: conditionLogicRaw) ?? .all }
        set { conditionLogicRaw = newValue.rawValue }
    }

    @Transient
    var outputMode: RuleOutputMode {
        get {
            if let mode = RuleOutputMode(rawValue: outputModeRaw) { return mode }
            return writeBackToPasteboard ? .clipboard : .replaceItem
        }
        set {
            outputModeRaw = newValue.rawValue
            writeBackToPasteboard = newValue.mirrorsToPasteboardOnCapture
        }
    }

    /// Conditions decode strictly: dropping one this build doesn't know (rule written
    /// by a newer version, then the app was downgraded) would make the rule match
    /// *more*, so an unknown condition blanks the list and the engine skips the rule.
    var conditions: [RuleCondition] {
        get { (try? JSONDecoder().decode([RuleCondition].self, from: conditionsData)) ?? [] }
        set { conditionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Actions decode element-wise: an unknown action only makes the rule do less,
    /// so it's dropped instead of blanking the whole rule.
    var actions: [RuleAction] {
        get { Self.decodeLenient(actionsData) }
        set { actionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    nonisolated static func decodeLenient<T: Decodable>(_ data: Data) -> [T] {
        guard !data.isEmpty else { return [] }
        let wrapped = (try? JSONDecoder().decode([LenientDecodable<T>].self, from: data)) ?? []
        return wrapped.compactMap(\.value)
    }

    init(
        name: String,
        enabled: Bool = true,
        isBuiltIn: Bool = false,
        sortOrder: Int = 0,
        triggerMode: TriggerMode = .automatic,
        notifyBeforeApply: Bool = false,
        writeBackToPasteboard: Bool = false,
        conditions: [RuleCondition] = [],
        actions: [RuleAction] = []
    ) {
        self.name = name
        self.enabled = enabled
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.triggerModeRaw = triggerMode.rawValue
        self.notifyBeforeApply = notifyBeforeApply
        self.writeBackToPasteboard = writeBackToPasteboard
        self.conditions = conditions
        self.actions = actions
    }

    /// Whether this rule should surface as an option for `item` in ⌘K / right-
    /// click menus. Two gates:
    /// 1. The rule's own conditions must match the clip (empty = always match).
    /// 2. At least one action must accept the clip's content type (`inputKind`) —
    ///    a rule made only of text transforms is meaningless on an image, while
    ///    pin / move-to-group / run-Shortcut apply to anything.
    ///
    /// `targetAppBundleID`: the app the panel was opened from, so "paste target is …"
    /// conditions can pick the rules shown for it. `nil` in the main window.
    func matches(item: ClipItem, targetAppBundleID: String? = nil) -> Bool {
        if !conditions.isEmpty {
            let input = ConditionInput(
                content: item.content,
                contentType: item.contentType,
                sourceApp: item.sourceAppBundleID,
                targetApp: targetAppBundleID,
                isSensitive: item.isSensitive,
                isPinned: item.isPinned,
                groupName: item.groupName
            )
            guard AutomationEngine.matchesConditions(conditions, logic: conditionLogic, input: input) else { return false }
        }
        // Output-only rule ("save to folder" with no actions): the output is the work.
        // A webhook only sends text.
        if actions.isEmpty {
            switch outputMode {
            case .saveToFile: return true
            case .postWebhook: return item.contentType.isMergeable
            default: return false
            }
        }
        // An AI rewrite needs text; offering it on an image would only run the
        // metadata leftovers and silently skip the part the rule is about — unless
        // the chain recognises the image's text first.
        let yieldsText = item.contentType.isMergeable
            || (item.contentType == .image && actions.contains(.runOCR))
        if !yieldsText, actions.contains(where: { $0.isAsync && $0.inputKind == .text }) {
            return false
        }
        return actions.contains { $0.inputKind.accepts(item.contentType) }
    }
}

/// Wraps a `Decodable` so a failing element decodes to `nil` instead of failing
/// the surrounding array.
struct LenientDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
