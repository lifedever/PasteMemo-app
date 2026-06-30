import Foundation
import Testing
@testable import PasteMemo

@Suite("KSUID")
struct KSUIDTests {
    @Test("encoded length is 27 characters")
    func encodedLength() {
        let id = KSUID.generate()
        #expect(id.count == KSUID.encodedLength)
    }

    @Test("uses only base62 alphabet")
    func alphabet() {
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let id = KSUID.generate()
        #expect(id.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    @Test("later timestamps sort lexicographically after earlier ones")
    func timeOrdering() {
        let earlier = KSUID.generate(at: Date(timeIntervalSince1970: 1_700_000_000))
        let later = KSUID.generate(at: Date(timeIntervalSince1970: 1_700_000_001))
        #expect(earlier < later)
    }

    @Test("new clip items receive KSUID itemIDs")
    @MainActor
    func clipItemDefaultID() {
        let item = ClipItem(content: "hello", contentType: .text)
        #expect(item.itemID.count == KSUID.encodedLength)
        #expect(!item.itemID.contains("-"))
    }
}
