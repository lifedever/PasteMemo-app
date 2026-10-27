import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import PasteMemo

/// Reproduces the 2026-10-27 crashes headlessly: rows on screen while their clips are deleted
/// and the delete is saved, then the rows are drawn again. Before `isGone`, the redraw read the
/// saved-deleted clip's external-storage rich text and Core Data / SwiftData trapped.
@Suite("ClipRow redraw after a saved delete", .serialized)
@MainActor
struct ClipRowDeletedRenderTests {
    @Test("Rows first drawn after their clips' delete was saved don't touch the clips")
    func redrawAfterSavedDelete() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rowcrash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: Schema([ClipItem.self, AutomationRule.self, SmartGroup.self]),
            configurations: [ModelConfiguration(url: root.appendingPathComponent("PasteMemo.store"))]
        )
        let context = container.mainContext
        // Rich text big enough for external storage, like the clips in the crash.
        let items = (0..<6).map { index in
            ClipItem(content: "text \(index)", contentType: .text,
                     richTextData: Data(repeating: UInt8(index), count: 300_000), richTextType: "html")
        }
        items.forEach(context.insert)
        try context.save()

        // Fetched fresh, like the storage page's rows: stored values are faults, and external
        // ones load from their file on first read — the read that threw in the crash.
        let viewContext = ModelContext(container)
        let fetched = try viewContext.fetch(FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.content)]))
        #expect(fetched.count == items.count)

        // Deleted and saved before any row has read its rich text: that attribute is still an
        // unresolved fault. A row first drawn now (a lazy cell scrolling in, a list rebuilt mid
        // delete) is the crash: SwiftData traps "backing data was detached from a context
        // without resolving attribute faults … \ClipItem.richTextData".
        for item in fetched { viewContext.delete(item) }
        try viewContext.save()
        #expect(fetched.allSatisfy { !$0.isDeleted }, "precondition: the flag reads false once saved")

        let host = NSHostingView(rootView: Rows(items: fetched, generation: 0, container: container))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        window.close()

        #expect(fetched.allSatisfy { $0.isGone })
    }
}

private struct Rows: View {
    let items: [ClipItem]
    let generation: Int
    let container: ModelContainer

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items, id: \.persistentModelID) { ClipRow(item: $0, isSelected: false) }
            }
            .id(generation)
        }
        .frame(width: 420, height: 500)
        .modelContainer(container)
    }
}
