import Testing
@testable import PasteMemo

/// 贴边条介绍窗口什么时候弹：只给老用户弹一次，全新安装的用户直接记为看过。
@Suite("Shelf intro launch decision")
struct ShelfIntroTests {

    @Test("老用户升级上来，第一次启动弹出")
    func upgradedUserSeesIntro() {
        let action = ShelfIntro.launchAction(seen: false, hasCompletedOnboarding: true, needsAccessibility: false)
        #expect(action == .present)
    }

    @Test("全新安装：不弹，直接记为看过，引导完下次启动也不会冒出来")
    func freshInstallMarksSeen() {
        let action = ShelfIntro.launchAction(seen: false, hasCompletedOnboarding: false, needsAccessibility: true)
        #expect(action == .markSeen)
    }

    @Test("权限丢了的老用户：这次先处理权限，介绍留到下次")
    func lostAccessibilityPostpones() {
        let action = ShelfIntro.launchAction(seen: false, hasCompletedOnboarding: true, needsAccessibility: true)
        #expect(action == .nothing)
    }

    @Test("看过了就不再弹")
    func seenNeverRepeats() {
        let action = ShelfIntro.launchAction(seen: true, hasCompletedOnboarding: true, needsAccessibility: false)
        #expect(action == .nothing)
    }
}
