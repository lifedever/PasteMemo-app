import Testing
@testable import PasteMemo

/// 快捷面板标签栏的顺序解析。存下来的顺序要能扛住「类型下线」「新增类型」两头的变化，
/// 否则老用户升级后要么看到不存在的标签，要么新类型永远不出现。
@Suite("QuickPanel tab order")
struct QuickPanelTabOrderTests {

    @Test("空配置退回默认顺序")
    func emptyFallsBackToDefault() {
        #expect(QuickPanelSettings.resolvedTabOrderIDs(from: "") == QuickPanelSettings.defaultTabOrderIDs)
    }

    @Test("存过的顺序被尊重，缺的补到末尾")
    func savedOrderWinsAndMissingAppended() {
        let resolved = QuickPanelSettings.resolvedTabOrderIDs(from: "image,all")
        #expect(resolved.prefix(2) == ["image", "all"])
        // 没存过的项一个都不能丢——新增类型默认可见是既定取舍
        #expect(Set(resolved) == Set(QuickPanelSettings.defaultTabOrderIDs))
    }

    @Test("未知 id 和重复项被丢掉")
    func dropsUnknownAndDuplicates() {
        let resolved = QuickPanelSettings.resolvedTabOrderIDs(from: "all,all,not-a-type,image")
        #expect(resolved.prefix(2) == ["all", "image"])
        #expect(!resolved.contains("not-a-type"))
        #expect(resolved.count == Set(resolved).count)
    }

    @Test("置顶不参与排序，全部和类型才是可排序项")
    func pinnedStaysOutOfOrdering() {
        // 固定在标签栏第一位，所以不能出现在顺序列表里——老配置存过也要被丢掉
        #expect(QuickPanelTabItem.parse("pinned") == nil)
        #expect(!QuickPanelSettings.defaultTabOrderIDs.contains("pinned"))
        #expect(QuickPanelSettings.resolvedTabOrderIDs(from: "pinned,all") == QuickPanelSettings.resolvedTabOrderIDs(from: "all"))

        #expect(QuickPanelTabItem.parse("all") == .all)
        #expect(QuickPanelTabItem.parse("image") == .type(.image))
        #expect(QuickPanelTabItem.parse("mixed") == nil)
    }

    @Test("隐藏集合按 id 读，兼容只存过类型的老配置")
    func hiddenIDsParseLegacyValues() {
        #expect(QuickPanelSettings.hiddenTabIDs(from: "image,code") == ["image", "code"])
        #expect(QuickPanelSettings.hiddenTabIDs(from: "pinned,all") == ["pinned", "all"])
        #expect(QuickPanelSettings.hiddenTabIDs(from: "").isEmpty)
    }

    @Test("短信是独立筛选项，参与排序和显隐")
    func smsIsASortableTab() {
        #expect(QuickPanelTabItem.parse("sms") == .sms)
        #expect(QuickPanelSettings.defaultTabOrderIDs.contains("sms"))
        // 短信排末尾：小众维度，不该挤掉高频标签。老用户存过的顺序里没有它，
        // 补进来时同样落在末尾，新老用户看到的位置一致。
        #expect(QuickPanelSettings.defaultTabOrderIDs.last == "sms")
        let resolved = QuickPanelSettings.resolvedTabOrderIDs(from: "all,text,image")
        #expect(resolved.prefix(3) == ["all", "text", "image"])
        #expect(resolved.last == "sms")
    }
}
