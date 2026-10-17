import Foundation
import Testing
@testable import PasteMemo

/// SMS-code clips keep their Messages attribution even when macOS's verification-code
/// AutoFill writes the same code to the pasteboard around the watcher's own write
/// (2026-10-17: the code landed as a Google Chrome clip with no SMS text).
@Suite("SMS code attribution")
struct SMSCodeAttributionTests {

    private let sms = "【腾讯科技】954136（微信公众平台验证码，十分钟内有效）"

    private func recent(secondsAgo: TimeInterval, now: Date) -> ClipboardManager.SMSCodeWrite {
        ClipboardManager.SMSCodeWrite(code: "954136", message: sms, at: now.addingTimeInterval(-secondsAgo))
    }

    @Test("the watcher's marker wins, with or without a recent write")
    func markerWins() {
        let now = Date()
        #expect(ClipboardManager.smsBody(marker: "body", pasteboardText: "954136", recent: nil, now: now) == "body")
        #expect(ClipboardManager.smsBody(marker: "body", pasteboardText: "x", recent: recent(secondsAgo: 1, now: now), now: now) == "body")
    }

    @Test("an unmarked write of the same code right after the watcher's still counts as the SMS code")
    func sameCodeWithoutMarker() {
        let now = Date()
        #expect(ClipboardManager.smsBody(marker: nil, pasteboardText: "954136", recent: recent(secondsAgo: 0.25, now: now), now: now) == sms)
        #expect(ClipboardManager.smsBody(marker: nil, pasteboardText: " 954136\n", recent: recent(secondsAgo: 5, now: now), now: now) == sms)
    }

    @Test("a different text, an expired write, or no write at all is an ordinary copy")
    func ordinaryCopies() {
        let now = Date()
        #expect(ClipboardManager.smsBody(marker: nil, pasteboardText: "954137", recent: recent(secondsAgo: 1, now: now), now: now) == nil)
        #expect(ClipboardManager.smsBody(marker: nil, pasteboardText: "954136", recent: recent(secondsAgo: 61, now: now), now: now) == nil)
        #expect(ClipboardManager.smsBody(marker: nil, pasteboardText: "954136", recent: nil, now: now) == nil)
        #expect(ClipboardManager.smsBody(marker: nil, pasteboardText: nil, recent: recent(secondsAgo: 1, now: now), now: now) == nil)
    }

    @Test("a clip captured from the frontmost app is re-attributed to Messages with the SMS text")
    @MainActor
    func adoptAttribution() {
        let landed = ClipItem(content: "954136", contentType: .text, sourceApp: "Google Chrome", sourceAppBundleID: "com.google.Chrome")
        landed.isSensitive = true
        let fromWatcher = ClipItem(content: "954136", contentType: .text, sourceApp: "信息", sourceAppBundleID: "com.apple.MobileSMS")
        fromWatcher.smsMessageText = sms

        ClipboardManager.adoptSMSAttribution(landed, from: fromWatcher)

        #expect(landed.sourceAppBundleID == "com.apple.MobileSMS")
        #expect(landed.sourceApp == "信息")
        #expect(landed.smsMessageText == sms)
        #expect(!landed.isSensitive)
        #expect(landed.content == "954136")
    }

    @Test("this template's code itself is extracted")
    func templateExtracts() {
        #expect(VerificationCodeExtractor.extract(from: sms) == "954136")
    }
}
