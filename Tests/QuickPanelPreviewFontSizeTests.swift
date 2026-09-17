import Foundation
import Testing
@testable import PasteMemo

@Suite("Quick panel preview font size")
struct QuickPanelPreviewFontSizeTests {

    @Test("default is the pre-existing 13pt")
    func defaultMatchesLegacyHardcodedSize() {
        #expect(QuickPanelPreviewFontSize.defaultPoints == 13)
        #expect(QuickPanelPreviewFontSize.resolved(13) == 13)
        #expect(QuickPanelPreviewFontSize.resolved(0) == 13)
        #expect(QuickPanelPreviewFontSize.resolved(99) == 13)
    }

    @Test("options are concrete point sizes in increasing order")
    func optionsAreConcretePoints() {
        #expect(QuickPanelPreviewFontSize.options == [11, 12, 13, 14, 15, 16, 18, 20])
        #expect(QuickPanelPreviewFontSize.options.contains(QuickPanelPreviewFontSize.defaultPoints))
        for size in QuickPanelPreviewFontSize.options {
            #expect(QuickPanelPreviewFontSize.resolved(size) == size)
        }
    }
}
