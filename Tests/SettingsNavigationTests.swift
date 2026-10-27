import Testing
@testable import PasteMemo

@Suite("SettingsNavigationModel")
@MainActor
struct SettingsNavigationTests {
    @Test("Subpages join the back / forward history")
    func subpageHistory() {
        let nav = SettingsNavigationModel()
        var titles: [String] = []
        nav.onLocationChange = { titles.append($0) }

        nav.select(.data)
        nav.push(.storageManage)
        nav.push(.storageGroup(.source("微信")))
        #expect(nav.subpage == .storageGroup(.source("微信")))
        #expect(titles.last == "微信")

        nav.goBack()
        #expect(nav.selection == .data && nav.subpage == .storageManage)
        nav.goBack()
        #expect(nav.selection == .data && nav.subpage == nil)
        nav.goBack()
        #expect(nav.selection == .general && nav.subpage == nil)
        #expect(!nav.canGoBack)

        nav.goForward()
        nav.goForward()
        #expect(nav.selection == .data && nav.subpage == .storageManage)
        #expect(nav.canGoForward)
    }

    @Test("Picking the current category in the sidebar leaves its subpage")
    func sidebarReturnsToRoot() {
        let nav = SettingsNavigationModel()
        nav.select(.data)
        nav.push(.storageManage)
        nav.select(.data)
        #expect(nav.subpage == nil)
        nav.goBack()
        #expect(nav.subpage == .storageManage)
    }

    @Test("Switching category drops the subpage; going back restores it")
    func otherCategory() {
        let nav = SettingsNavigationModel()
        nav.select(.data)
        nav.push(.storageManage)
        nav.select(.about)
        #expect(nav.selection == .about && nav.subpage == nil)
        nav.goBack()
        #expect(nav.selection == .data && nav.subpage == .storageManage)
    }

    @Test("A new page from the middle of history cuts off the forward part")
    func truncatesForward() {
        let nav = SettingsNavigationModel()
        nav.select(.data)
        nav.push(.storageManage)
        nav.goBack()
        nav.push(.storageGroup(.category(.image)))
        #expect(!nav.canGoForward)
        nav.goBack()
        #expect(nav.subpage == nil)
    }
}
