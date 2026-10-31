import Foundation
import Testing
@testable import PasteMemo

/// Multi-paste separates groups with line breaks written as text, never a synthetic Return —
/// Return sends in chat inputs (DingTalk sent the first image on its own).
@Suite("Multi-paste line breaks")
@MainActor
struct MultiPasteLineBreakTests {
    private typealias Group = ClipboardManager.PasteGroup

    private func describe(_ groups: [Group]) -> [String] {
        groups.map { group in
            switch group {
            case .text(let content, let rich, _): rich == nil ? "text(\(content))" : "rich(\(content))"
            case .image: "image"
            case .files(let paths): "files(\(paths.count))"
            case .clipItem: "clipItem"
            }
        }
    }

    private let image = Group.image(Data([0x01]))
    private let rich = Group.text("R", richTextData: Data([0x02]), richTextType: "rtf")

    @Test("images and files next to each other stay on one line")
    func mediaRun() {
        let groups = ClipboardManager.insertingLineBreaks([image, image, .files(["/a", "/b"]), image])
        #expect(describe(groups) == ["image", "image", "files(2)", "image"])
    }

    @Test("text before media carries the break at its end, text after media at its start")
    func textAroundMedia() {
        let groups = ClipboardManager.insertingLineBreaks([
            .text("a", richTextData: nil, richTextType: nil), image,
            .text("b", richTextData: nil, richTextType: nil), image,
        ])
        #expect(describe(groups) == ["text(a\n)", "image", "text(\nb\n)", "image"])
    }

    @Test("no plain text to carry it: the break is its own paste")
    func richNextToMedia() {
        let groups = ClipboardManager.insertingLineBreaks([image, rich, rich])
        #expect(describe(groups) == ["image", "text(\n)", "rich(R)", "text(\n)", "rich(R)"])
    }

    @Test("rich text next to plain text: the plain one carries the break")
    func richNextToPlain() {
        let groups = ClipboardManager.insertingLineBreaks([
            rich, .text("p", richTextData: nil, richTextType: nil), rich,
        ])
        #expect(describe(groups) == ["rich(R)", "text(\np\n)", "rich(R)"])
    }

    @Test("a single group is left alone")
    func single() {
        #expect(describe(ClipboardManager.insertingLineBreaks([.text("x", richTextData: nil, richTextType: nil)])) == ["text(x)"])
        #expect(describe(ClipboardManager.insertingLineBreaks([])) == [])
    }
}
