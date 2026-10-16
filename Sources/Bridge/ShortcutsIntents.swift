import AppIntents
import Foundation
import SwiftData

// Actions PasteMemo offers to Shortcuts and Spotlight.
//
// Titles are written out as `LocalizedStringResource("…", table:)` literals on purpose:
// the build-time metadata extractor only reads literals, not a helper's return value.
// They live in the app bundle's own
// `Contents/Resources/<lang>.lproj/AppIntents.strings` (the build scripts copy them
// from `Sources/Localization`): Shortcuts resolves them in its own process and never
// looks into the SwiftPM resource bundle `L10n` reads. The metadata Shortcuts needs is
// generated at build time by `scripts/appintents-metadata.sh`.
//
// Same privacy line as the MCP bridge: sensitive clips and clips from apps on the
// AI-access blocklist are never handed out.

enum PasteMemoIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingFound
    case ruleNotFound
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingFound: return LocalizedStringResource("intent.error.nothingFound", table: "AppIntents")
        case .ruleNotFound: return LocalizedStringResource("intent.error.ruleNotFound", table: "AppIntents")
        case .failed(let message): return "\(message)"
        }
    }
}

/// History reads shared by the intents: newest first (the panel's order), text-like
/// clips only, privacy filter applied.
@MainActor
enum IntentClipReader {
    static func visibleTextClips(matching query: String?, limit: Int) throws -> [String] {
        let context = PasteMemoApp.sharedModelContainer.mainContext
        var descriptor = FetchDescriptor<ClipItem>(sortBy: [
            SortDescriptor(\.lastUsedAt, order: .reverse),
            SortDescriptor(\.createdAt, order: .reverse),
        ])
        descriptor.fetchLimit = 10_000   // same scan cap as the MCP search
        let guardLayer = PrivacyGuard(allowSensitive: false,
                                      sourceAppBlocklist: MCPSourceAppBlocklist.shared.blockedBundleIDs)
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let items = guardLayer.filter(try context.fetch(descriptor)).filter { item in
            guard item.contentType.isMergeable else { return false }
            return needle.isEmpty || item.content.localizedCaseInsensitiveContains(needle)
        }
        return items.prefix(limit).map(\.content)
    }
}

struct OpenQuickPanelIntent: AppIntent {
    static let title = LocalizedStringResource("intent.openQuickPanel.title", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource("intent.openQuickPanel.description", table: "AppIntents"))

    @MainActor
    func perform() async throws -> some IntentResult {
        HotkeyManager.shared.showQuickPanel()
        return .result()
    }
}

struct SearchClipsIntent: AppIntent {
    static let title = LocalizedStringResource("intent.searchClips.title", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource("intent.searchClips.description", table: "AppIntents"))

    @Parameter(title: LocalizedStringResource("intent.searchClips.query", table: "AppIntents"))
    var query: String

    @Parameter(title: LocalizedStringResource("intent.searchClips.limit", table: "AppIntents"),
               default: 10, inclusiveRange: (1, 100))
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        .result(value: try IntentClipReader.visibleTextClips(matching: query, limit: limit))
    }
}

struct GetRecentClipIntent: AppIntent {
    static let title = LocalizedStringResource("intent.recentClip.title", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource("intent.recentClip.description", table: "AppIntents"))

    /// 1 = the newest, like ⌘1 in the Quick Panel.
    @Parameter(title: LocalizedStringResource("intent.recentClip.position", table: "AppIntents"),
               default: 1, inclusiveRange: (1, 100))
    var position: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let clips = try IntentClipReader.visibleTextClips(matching: nil, limit: position)
        guard clips.count >= position else { throw PasteMemoIntentError.nothingFound }
        return .result(value: clips[position - 1])
    }
}

/// An automation rule, as Shortcuts shows it in a picker.
struct RuleEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("intent.rule.type", table: "AppIntents"))
    static let defaultQuery = RuleEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct RuleEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [RuleEntity.ID]) async throws -> [RuleEntity] {
        try Self.rules().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [RuleEntity] {
        try Self.rules()
    }

    /// Enabled rules that can work on plain text.
    @MainActor
    static func rules() throws -> [RuleEntity] {
        let context = PasteMemoApp.sharedModelContainer.mainContext
        let descriptor = FetchDescriptor<AutomationRule>(predicate: #Predicate { $0.enabled },
                                                         sortBy: [SortDescriptor(\.sortOrder)])
        return try context.fetch(descriptor)
            .filter { rule in rule.actions.contains { $0.kind == .transform && $0.inputKind == .text } }
            .map { RuleEntity(id: $0.ruleID, name: $0.isBuiltIn ? L10n.tr($0.name) : $0.name) }
    }
}

struct ProcessTextWithRuleIntent: AppIntent {
    static let title = LocalizedStringResource("intent.processText.title", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource("intent.processText.description", table: "AppIntents"))

    @Parameter(title: LocalizedStringResource("intent.processText.rule", table: "AppIntents"))
    var rule: RuleEntity

    @Parameter(title: LocalizedStringResource("intent.processText.text", table: "AppIntents"),
               inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let context = PasteMemoApp.sharedModelContainer.mainContext
        let ruleID = rule.id
        let descriptor = FetchDescriptor<AutomationRule>(predicate: #Predicate { $0.ruleID == ruleID })
        guard let stored = try context.fetch(descriptor).first else { throw PasteMemoIntentError.ruleNotFound }
        do {
            return .result(value: try await ActionExecutor.transformText(text, with: stored.actions))
        } catch let error as AIError {
            throw PasteMemoIntentError.failed(error.userMessage)
        }
    }
}

struct PasteMemoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenQuickPanelIntent(),
            phrases: ["Open \(.applicationName)", "Show \(.applicationName) quick panel"],
            shortTitle: LocalizedStringResource("intent.openQuickPanel.short", table: "AppIntents"),
            systemImageName: "list.bullet.rectangle"
        )
        AppShortcut(
            intent: SearchClipsIntent(),
            phrases: ["Search \(.applicationName)", "Search clipboard history in \(.applicationName)"],
            shortTitle: LocalizedStringResource("intent.searchClips.short", table: "AppIntents"),
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: GetRecentClipIntent(),
            phrases: ["Get the latest clip from \(.applicationName)"],
            shortTitle: LocalizedStringResource("intent.recentClip.short", table: "AppIntents"),
            systemImageName: "doc.on.clipboard"
        )
    }
}
