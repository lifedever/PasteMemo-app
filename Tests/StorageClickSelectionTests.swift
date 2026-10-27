import Testing
@testable import PasteMemo

@Suite("StorageClickSelection")
struct StorageClickSelectionTests {
    private let order = ["a", "b", "c", "d", "e"]

    @Test("A plain click toggles one row and leaves the others selected")
    func toggles() {
        var clicks = StorageClickSelection<String>()
        var selection: Set<String> = ["e"]
        clicks.click("b", extendingRange: false, order: order, selection: &selection)
        #expect(selection == ["b", "e"])
        clicks.click("b", extendingRange: false, order: order, selection: &selection)
        #expect(selection == ["e"])
    }

    @Test("⇧-click selects from the anchor to the clicked row, either direction")
    func range() {
        var clicks = StorageClickSelection<String>()
        var selection: Set<String> = []
        clicks.click("b", extendingRange: false, order: order, selection: &selection)
        clicks.click("d", extendingRange: true, order: order, selection: &selection)
        #expect(selection == ["b", "c", "d"])
        clicks.click("a", extendingRange: true, order: order, selection: &selection)
        #expect(selection == ["a", "b", "c", "d"])
        #expect(clicks.anchor == "b")
    }

    @Test("⇧-click with no anchor (or an anchor no longer listed) acts like a plain click")
    func noAnchor() {
        var clicks = StorageClickSelection<String>()
        var selection: Set<String> = []
        clicks.click("c", extendingRange: true, order: order, selection: &selection)
        #expect(selection == ["c"] && clicks.anchor == "c")
        clicks.click("e", extendingRange: true, order: ["d", "e"], selection: &selection)
        #expect(selection == ["c", "e"])
    }
}
