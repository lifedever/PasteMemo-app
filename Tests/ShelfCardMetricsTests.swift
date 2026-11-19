import CoreGraphics
import Testing
@testable import PasteMemo

/// 贴边条卡片的宽度规则：所有类型共用三档，短文字窄、长文字和多行宽、图片按横竖。
@Suite("Shelf card metrics")
struct ShelfCardMetricsTests {

    @Test("一行 16 字以内算短文字，用窄卡")
    func shortTextIsNarrow() {
        #expect(ShelfCardText.isShort("ipcheck 1.2.3.4"))
        #expect(ShelfCardMetrics.textWidth(for: "13800138000") == ShelfCardMetrics.narrowWidth)
    }

    @Test("带换行的不算短文字，哪怕字很少")
    func multilineIsNotShort() {
        #expect(!ShelfCardText.isShort("a\nb"))
    }

    @Test("中等长度用中等宽度")
    func mediumText() {
        let text = "明天下午三点在 3 楼会议室，记得带报销发票"
        #expect(ShelfCardMetrics.textWidth(for: text) == ShelfCardMetrics.mediumWidth)
    }

    @Test("超过 60 字或超过两行用宽卡")
    func longOrMultilineTextIsWide() {
        #expect(ShelfCardMetrics.textWidth(for: String(repeating: "字", count: 61)) == ShelfCardMetrics.wideWidth)
        #expect(ShelfCardMetrics.textWidth(for: "一\n二\n三") == ShelfCardMetrics.wideWidth)
    }

    @Test("图片分三档：竖图窄、方图中、横图宽")
    func imageWidthTiers() {
        #expect(ShelfCardMetrics.imageWidth(aspect: 0.3) == ShelfCardMetrics.narrowWidth)
        #expect(ShelfCardMetrics.imageWidth(aspect: 0.79) == ShelfCardMetrics.narrowWidth)
        #expect(ShelfCardMetrics.imageWidth(aspect: 0.8) == ShelfCardMetrics.mediumWidth)
        #expect(ShelfCardMetrics.imageWidth(aspect: 1) == ShelfCardMetrics.mediumWidth)
        #expect(ShelfCardMetrics.imageWidth(aspect: 1.3) == ShelfCardMetrics.mediumWidth)
        #expect(ShelfCardMetrics.imageWidth(aspect: 1.31) == ShelfCardMetrics.wideWidth)
        #expect(ShelfCardMetrics.imageWidth(aspect: 3) == ShelfCardMetrics.wideWidth)
    }

    @Test("类型颜色按类型分：同一类型同一种颜色，几种常用类型互不相同")
    func kindTonesByType() {
        #expect(ShelfCardKind.tone(for: .text) == .amber)
        #expect(ShelfCardKind.tone(for: .image) == .pink)
        #expect(ShelfCardKind.tone(for: .link) == .blue)
        #expect(ShelfCardKind.tone(for: .code) == .violet)
        #expect(ShelfCardKind.tone(for: .color) == .teal)
        #expect(ShelfCardKind.tone(for: .document) == ShelfCardKind.tone(for: .file))
    }
}
