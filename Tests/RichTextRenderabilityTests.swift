import AppKit
import Foundation
import Testing
@testable import PasteMemo

/// #88：VS Code 复制的代码在"文本"模式下整段渲染成 LastResort 的 "?" 方框，
/// 而同一条在列表里（纯文本）显示正常。方框出现的条件是码点没有任何字体覆盖，
/// 所以判据落在"解出来的码点本身是不是可渲染的"，而不是字体是否装了——
/// 字体缺字形会被 NSLayoutManager 自动替换，不会变成方框。
@Suite("Rich text renderability gate")
@MainActor
struct RichTextRenderabilityTests {

    private func attributed(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string)
    }

    /// 把 ASCII 整体平移到私用区——这正是 #88 截图里 9 个字符对 9 个方框的形状。
    private func shiftedToPrivateUse(_ string: String, by offset: UInt32) -> String {
        String(String.UnicodeScalarView(string.unicodeScalars.compactMap {
            UnicodeScalar(offset + $0.value)
        }))
    }

    @Test("正常文本通过")
    func plainTextPasses() {
        #expect(NativeTextView.isRenderable(attributed("</Button>")))
        #expect(NativeTextView.isRenderable(attributed("let x = 1\nprint(x)")))
        #expect(NativeTextView.isRenderable(attributed("中文内容也要正常显示")))
        #expect(NativeTextView.isRenderable(attributed("emoji 🎉 和符号 ±≠∑")))
    }

    @Test("整段私用区码点被否决（#88 的形状）")
    func allPrivateUseRejected() {
        #expect(!NativeTextView.isRenderable(attributed(shiftedToPrivateUse("</Button>", by: 0xE000))))
        #expect(!NativeTextView.isRenderable(attributed(shiftedToPrivateUse("</Button>", by: 0xF000))))
    }

    @Test("整段未分配码点被否决")
    func allUnassignedRejected() {
        #expect(!NativeTextView.isRenderable(attributed(String(repeating: "\u{0378}", count: 9))))
    }

    @Test("夹带少量私用区图标的正常文本不受影响")
    func occasionalPrivateUseIconsPass() {
        // 终端 / Nerd Font 用户复制的 Powerline 提示符：图标是私用区，正文是正常文本
        #expect(NativeTextView.isRenderable(attributed("\u{E0B0} ~/Documents/Dev \u{E0B0} main \u{F09B} ok")))
    }

    @Test("空白与图片占位符不参与判断")
    func whitespaceAndAttachmentsIgnored() {
        // 纯图片富文本：正文只有 attachment 占位符，不该被当成坏数据
        #expect(NativeTextView.isRenderable(attributed("\u{FFFC}")))
        #expect(NativeTextView.isRenderable(attributed("   \n\t  ")))
        #expect(NativeTextView.isRenderable(attributed("")))
    }

    @Test("恰好过半私用区仍然否决，少于半数放行")
    func thresholdBoundary() {
        // 10 个可见字符里 5 个私用区 → 不足"过半可渲染"，否决
        #expect(!NativeTextView.isRenderable(attributed("abcde\u{E000}\u{E001}\u{E002}\u{E003}\u{E004}")))
        // 11 个可见字符里 5 个私用区 → 多数仍可读，放行
        #expect(NativeTextView.isRenderable(attributed("abcdef\u{E000}\u{E001}\u{E002}\u{E003}\u{E004}")))
    }

    /// 复现用例：这份 HTML 写进剪贴板后，Dev 版预览里就是 #88 截图里的 9 个方框
    /// （纯文本 `</Button>` 正常，富文本整段是私用区码点）。
    @Test("#88 的剪贴板数据被判为不可渲染")
    func issue88ClipboardPayloadRejected() throws {
        let html = """
        <meta charset='utf-8'><div style="color: #bbbebf;background-color: #121314;\
        font-family: Menlo, Monaco, monospace;font-size: 13px;white-space: pre;">\
        <div><span style="color: #ff7b72;">&#xE03C;&#xE02F;</span>\
        <span style="color: #d2a8ff;">&#xE042;&#xE075;&#xE074;&#xE074;&#xE06F;&#xE06E;</span>\
        <span style="color: #ff7b72;">&#xE03E;</span></div></div>
        """
        let decoded = try #require(NSAttributedString(html: Data(html.utf8), documentAttributes: nil))
        // 解码本身是"成功"的——坏就坏在解出来的码点没有任何字体覆盖
        #expect(decoded.string.trimmingCharacters(in: .newlines).count == 9)
        #expect(!NativeTextView.isRenderable(decoded))
    }

    /// 端到端：走 VS Code 真实的 HTML 形状，确认正常内容不会被这道闸误伤。
    @Test("VS Code 风格 HTML 正常解码并通过")
    func vscodeStyleHTMLPasses() throws {
        let html = """
        <meta charset='utf-8'><div style="color: #bbbebf;background-color: #121314;\
        font-family: Menlo, Monaco, 'Courier New', monospace;font-size: 13px;\
        white-space: pre;"><div><span style="color: #ff7b72;">&lt;/</span>\
        <span style="color: #d2a8ff;">Button</span><span style="color: #ff7b72;">&gt;</span></div></div>
        """
        let decoded = try #require(NSAttributedString(html: Data(html.utf8), documentAttributes: nil))
        #expect(decoded.string.contains("</Button>"))
        #expect(NativeTextView.isRenderable(decoded))
    }
}
