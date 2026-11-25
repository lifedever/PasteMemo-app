import Foundation
import Testing
@testable import PasteMemo

@Suite("Auto-install idle gate")
struct AutoInstallGateTests {
    private let idle = AutoInstallGate.requiredIdleSeconds

    @Test("闲置够久、PasteMemo 不在前台、没在接力、没开编辑窗口 → 可以装")
    func readyWhenIdleAndUnused() {
        #expect(AutoInstallGate.isReady(
            idleSeconds: idle, appIsActive: false, relayActive: false, hasOpenWorkWindow: false
        ))
    }

    @Test("闲置不够久不装")
    func notReadyWhenRecentlyUsed() {
        #expect(!AutoInstallGate.isReady(
            idleSeconds: idle - 1, appIsActive: false, relayActive: false, hasOpenWorkWindow: false
        ))
    }

    @Test("PasteMemo 在前台、接力进行中、开着编辑窗口，任一成立都不装")
    func notReadyWhileInUse() {
        #expect(!AutoInstallGate.isReady(
            idleSeconds: idle * 10, appIsActive: true, relayActive: false, hasOpenWorkWindow: false
        ))
        #expect(!AutoInstallGate.isReady(
            idleSeconds: idle * 10, appIsActive: false, relayActive: true, hasOpenWorkWindow: false
        ))
        #expect(!AutoInstallGate.isReady(
            idleSeconds: idle * 10, appIsActive: false, relayActive: false, hasOpenWorkWindow: true
        ))
    }

    @Test("读得到系统闲置秒数")
    func systemIdleSecondsIsNonNegative() {
        #expect(AutoInstallGate.systemIdleSeconds() >= 0)
    }
}

@Suite("Update check interval")
struct UpdateCheckIntervalTests {
    @Test("没设过时按界面显示的默认值（24 小时）走，不是 6 小时")
    func defaultMatchesSettingsUI() {
        #expect(UpdateChecker.checkIntervalHours(saved: nil) == UpdateChecker.defaultCheckIntervalHours)
        #expect(UpdateChecker.defaultCheckIntervalHours == 24)
    }

    @Test("用户选的值照用，最短 6 小时")
    func savedValueWithFloor() {
        #expect(UpdateChecker.checkIntervalHours(saved: 12) == 12)
        #expect(UpdateChecker.checkIntervalHours(saved: 72) == 72)
        #expect(UpdateChecker.checkIntervalHours(saved: 0) == 6)
    }
}

@Suite("Release notes on the update page")
struct ReleaseNotesLineTests {
    @Test("标题、列表项、普通行分开；加粗按 markdown 解析")
    func parsesKinds() {
        let lines = ReleaseNotesLine.parse("""
        ## 更新内容

        - **新增** 自动安装更新
        * 另一种列表符号
        普通一行
        """)
        #expect(lines.map(\.kind) == [.heading, .bullet, .bullet, .text])
        #expect(lines.map { String($0.text.characters) } == [
            "更新内容", "新增 自动安装更新", "另一种列表符号", "普通一行",
        ])
        let bold = lines[1].text.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        #expect(bold.map { String(lines[1].text[$0.range].characters) } == "新增")
    }
}

@Suite("Update notification body")
struct UpdateNotesPlainTextTests {
    @Test("去掉列表符号、加粗和标题行")
    func stripsMarkdown() {
        let notes = """
        ## 更新内容

        - **新增** 自动安装更新
        - **修复** 全屏时更新窗口抢前台（#101，感谢 @someone 的反馈）
        """
        #expect(UpdateNotifier.plainNotes(notes) == """
        新增 自动安装更新
        修复 全屏时更新窗口抢前台（#101，感谢 @someone 的反馈）
        """)
    }

    @Test("没有更新内容时正文为空")
    func emptyNotes() {
        #expect(UpdateNotifier.plainNotes(nil) == "")
        #expect(UpdateNotifier.plainNotes("\n\n") == "")
    }
}
