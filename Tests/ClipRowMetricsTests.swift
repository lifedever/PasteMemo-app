import AppKit
import Foundation
import Testing
@testable import PasteMemo

@Suite("Clip Row Metrics")
struct ClipRowMetricsTests {
    // MARK: - 数量缩写

    @Test("Counts abbreviate with k/M and drop trailing .0")
    func abbreviateFormatsMagnitudes() {
        #expect(ClipRowMetrics.abbreviate(0) == "0")
        #expect(ClipRowMetrics.abbreviate(348) == "348")
        #expect(ClipRowMetrics.abbreviate(999) == "999")
        #expect(ClipRowMetrics.abbreviate(1_234) == "1.2k")
        #expect(ClipRowMetrics.abbreviate(12_000) == "12k")
        #expect(ClipRowMetrics.abbreviate(999_500) == "999.5k")
        // k 路径四舍五入会撞到 1000k，交给 M 路径报「1M」
        #expect(ClipRowMetrics.abbreviate(999_999) == "1M")
        #expect(ClipRowMetrics.abbreviate(3_400_000) == "3.4M")
        #expect(ClipRowMetrics.abbreviate(2_000_000) == "2M")
    }

    // MARK: - 文本测量

    @Test("Line count follows newlines, not the trailing-newline illusion")
    func measureTextCountsLines() {
        #expect(ClipRowMetrics.measureText("one line").lines == 1)
        #expect(ClipRowMetrics.measureText("a\nb\nc").lines == 3)
        // 末尾换行后面确实还有一个（空）行,与属性面板的 components(separatedBy:) 口径一致
        #expect(ClipRowMetrics.measureText("a\nb\n").lines == 3)
        #expect(ClipRowMetrics.measureText("").lines == 1)
    }

    @Test("Char count counts characters, not UTF-8 bytes")
    func measureTextCountsCharactersNotBytes() {
        let metrics = ClipRowMetrics.measureText("中文三字")
        #expect(metrics.chars == 4)
        #expect(metrics.bytes == 12)
    }

    @Test("Oversized text reports bytes only — exact grapheme counting is O(n)")
    func measureTextSkipsCountingForBulkContent() {
        let bulk = String(repeating: "x", count: ClipRowMetrics.bulkTextBytes + 1)
        let metrics = ClipRowMetrics.measureText(bulk)
        #expect(metrics.chars == nil)
        #expect(metrics.lines == nil)
        #expect(metrics.bytes == ClipRowMetrics.bulkTextBytes + 1)
    }

    @Test("Blank lines count as lines — paragraphs separated by an empty line qualify")
    @MainActor func blankLineParagraphsQualify() {
        // 4 字节 / 3 行。任何按「每行至少 1 个字符」估算的短路都会漏掉这条。
        let metrics = ClipRowMetrics.measureText("a\n\nb")
        #expect(metrics.lines == 3)
        #expect(ClipRowMetrics.label(for: metrics) != nil)
    }

    // MARK: - 显示门槛

    @Test("Labels appear only once the title stops telling the whole story")
    @MainActor func labelSuppressesFullyVisibleContent() {
        // 短词短语:标题栏完整显示得下,报数字纯属噪音
        let shortLine = ClipRowMetrics.measureText("合约期限不一致")
        #expect(ClipRowMetrics.label(for: shortLine) == nil)

        // 超过标题可见长度:字数开始有信息量
        let sentence = ClipRowMetrics.measureText(String(repeating: "文", count: ClipRowMetrics.minChars))
        #expect(ClipRowMetrics.label(for: sentence) != nil)

        // 第二行的存在本身就是信息:标题只取第一行
        let twoLines = ClipRowMetrics.measureText("a\nb")
        #expect(ClipRowMetrics.label(for: twoLines) != nil)
    }

    @Test("Char count and line count qualify independently")
    @MainActor func eachNumberEarnsItsPlaceSeparately() {
        // 短的多行:只报行数——「5 字」对这条没有任何意义
        let shortMultiline = ClipRowMetrics.measureText("a\nb")
        let shortLabel = try? #require(ClipRowMetrics.label(for: shortMultiline))
        #expect(shortLabel?.contains("2") == true)
        #expect(ClipRowMetrics.label(for: shortMultiline)?.contains("·") == false)

        // 长的单行:只报字数,不该冒出「1 行」
        let longSingleLine = ClipRowMetrics.measureText(String(repeating: "文", count: 50))
        #expect(ClipRowMetrics.label(for: longSingleLine)?.contains("·") == false)

        // 又长又多行:两个都报
        let both = ClipRowMetrics.measureText(String(repeating: "文", count: 50) + "\n" + String(repeating: "字", count: 50))
        #expect(ClipRowMetrics.label(for: both)?.contains("·") == true)
    }

    @Test("Bulk text falls back to a byte size label")
    @MainActor func labelReportsSizeForBulkText() {
        let bulk = ClipRowMetrics.TextMetrics(chars: nil, lines: nil, bytes: 12_400_000)
        let label = ClipRowMetrics.label(for: bulk)
        #expect(label != nil)
        #expect(label?.contains("MB") == true)
    }

    @Test("Image label can drop dimensions when the title already shows them")
    @MainActor func imageLabelHonorsDimensionSuppression() {
        let metrics = ClipRowMetrics.ImageMetrics(width: 2560, height: 1600, bytes: 1_258_291)
        #expect(ClipRowMetrics.label(for: metrics)?.contains("2560×1600") == true)
        #expect(ClipRowMetrics.label(for: metrics, includeDimensions: false)?.contains("2560×1600") == false)

        // 尺寸读到了但文件已删/无法 stat:仍然值得报尺寸
        let noBytes = ClipRowMetrics.ImageMetrics(width: 800, height: 600, bytes: nil)
        #expect(ClipRowMetrics.label(for: noBytes) == "800×600")
        #expect(ClipRowMetrics.label(for: noBytes, includeDimensions: false) == nil)
    }

    // MARK: - 图片测量

    @Test("Local image dimensions come from the file header, and misses stay nil")
    func measuresLocalImageWithoutDecoding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliprowmetrics-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 25,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        let png = try #require(rep?.representation(using: .png, properties: [:]))
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metrics = ClipRowMetrics.measureImage(
            content: url.path, originalImagePath: nil, legacyBytes: nil
        )
        #expect(metrics?.width == 40)
        #expect(metrics?.height == 25)
        #expect((metrics?.bytes ?? 0) > 0)

        // 源文件被删/被移走的条目不该报出假数字
        #expect(ClipRowMetrics.measureImage(
            content: "/nonexistent/gone.png", originalImagePath: nil, legacyBytes: nil
        ) == nil)
    }

    // MARK: - 链接域名

    @Test("Link host strips www and tolerates a missing scheme")
    func linkHostNormalizesDomains() {
        #expect(ClipRowMetrics.linkHost("https://github.com/lifedever/PasteMemo") == "github.com")
        #expect(ClipRowMetrics.linkHost("https://www.apple.com/mac/") == "apple.com")
        #expect(ClipRowMetrics.linkHost("example.com/path") == "example.com")
    }

    @Test("Data URIs never get parsed as links — the content can be megabytes")
    func linkHostRejectsDataURIs() {
        let dataURI = "data:image/png;base64," + String(repeating: "A", count: 4_096)
        #expect(ClipRowMetrics.linkHost(dataURI) == nil)
    }

    @Test("Link parsing is bounded so a giant string can't stall the row")
    func linkHostParsesOnlyAHeadWindow() {
        let long = "https://example.com/" + String(repeating: "a", count: 100_000)
        #expect(ClipRowMetrics.linkHost(long) == "example.com")
    }
}
