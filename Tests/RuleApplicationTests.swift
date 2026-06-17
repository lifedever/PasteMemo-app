import Foundation
import SwiftData
import Testing
@testable import PasteMemo

/// Covers the rule-application paths that the pure-function engine tests miss:
/// metadata actions (move to group / pin / mark sensitive) landing on a clip, and
/// `process()` producing actions for non-text clips. These are exactly the seams
/// where image/video rules silently no-op'd before (issue #71) and where the
/// quick-panel manual path forgot metadata actions.
@Suite("Rule application")
@MainActor
struct RuleApplicationTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([ClipItem.self, SmartGroup.self, AutomationRule.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    // MARK: - applyMetadataActions

    @Test("assignGroup lands on an image clip without rewriting its content (issue #71)")
    func metadataAssignsGroupOnImage() throws {
        let context = ModelContext(try makeContainer())
        let item = ClipItem(content: "[Image]", contentType: .image)
        context.insert(item)

        ClipboardManager.shared.applyMetadataActions(
            [.assignGroup(name: "图片")], to: item, context: context
        )

        #expect(item.groupName == "图片")
        #expect(item.content == "[Image]") // image placeholder must stay intact
        let groups = try context.fetch(FetchDescriptor<SmartGroup>())
        #expect(groups.contains { $0.name == "图片" })
    }

    @Test("pin + markSensitive flags apply to a clip")
    func metadataSetsFlags() throws {
        let context = ModelContext(try makeContainer())
        let item = ClipItem(content: "hello", contentType: .text)
        context.insert(item)

        ClipboardManager.shared.applyMetadataActions([.pin, .markSensitive], to: item, context: context)

        #expect(item.isPinned)
        #expect(item.isSensitive)
    }

    @Test("empty group name is ignored")
    func metadataEmptyGroupIgnored() throws {
        let context = ModelContext(try makeContainer())
        let item = ClipItem(content: "hello", contentType: .text)
        context.insert(item)

        ClipboardManager.shared.applyMetadataActions([.assignGroup(name: "")], to: item, context: context)

        #expect(item.groupName == nil)
    }

    // MARK: - process() boundary

    @Test("process() returns actions for an image rule — engine never re-gates by type (issue #71)")
    func processAppliesToImageRule() throws {
        let context = ModelContext(try makeContainer())
        UserDefaults.standard.set(true, forKey: "automationEnabled")

        let rule = AutomationRule(
            name: "归档图片",
            enabled: true,
            isBuiltIn: false,
            sortOrder: 0,
            triggerMode: .automatic,
            conditions: [.contentType(.image)],
            actions: [.assignGroup(name: "图片")]
        )
        context.insert(rule)
        try context.save()

        let result = AutomationEngine.shared.process(
            content: "[Image]", contentType: .image, sourceApp: nil, context: context
        )

        switch result {
        case .applied(_, _, let actions, _):
            #expect(actions.contains(.assignGroup(name: "图片")))
        default:
            Issue.record("expected .applied for an image rule, got \(result)")
        }
    }
}
