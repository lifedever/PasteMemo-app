import Foundation
import Testing
@testable import PasteMemo

@Suite("SMSCodeWatcher Tests")
struct SMSCodeWatcherTests {

    /// Round-trip through the same NSArchiver/NSUnarchiver pair chat.db uses for
    /// `attributedBody`. Both classes are Swift-unavailable; reached via the
    /// ObjC runtime exactly like production code.
    @Test("typedstream round-trip decodes the message body")
    func typedStreamRoundTrip() throws {
        let original = NSAttributedString(string: "【测试】您的验证码是 483920，请勿泄露。")
        let archiver = try #require(NSClassFromString("NSArchiver") as? NSObject.Type)
        let data = try #require(
            archiver.perform(
                NSSelectorFromString("archivedDataWithRootObject:"), with: original
            )?.takeUnretainedValue() as? Data
        )
        #expect(SMSCodeWatcher.decodeTypedStream(data) == original.string)
    }

    @Test("Garbage data decodes to nil, not a crash")
    func garbageData() {
        #expect(SMSCodeWatcher.decodeTypedStream(Data([0x00, 0x01, 0x02])) == nil)
        #expect(SMSCodeWatcher.decodeTypedStream(Data()) == nil)
    }

    @Test("Messages app display name resolves to something")
    func messagesDisplayName() {
        #expect(!SMSCodeWatcher.messagesAppDisplayName().isEmpty)
    }
}
