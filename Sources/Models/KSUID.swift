import Foundation

/// K-Sorted Unique IDentifier (KSUID) generator.
///
/// Generates 27-character, time-sortable, globally-unique identifiers.
/// IDs are naturally K-sorted because the timestamp is encoded in the
/// leading bytes, so lexicographic ordering matches creation-time ordering.
///
/// Format (20 bytes total):
///   - 4 bytes: unsigned big-endian timestamp (seconds since KSUID epoch)
///   - 16 bytes: cryptographically-random payload
///   → Base62-encoded into 27 characters.
///
/// KSUID epoch: 2014-05-13 00:00:00 UTC (1_400_000_000 Unix seconds).
///
/// Reference: https://github.com/segmentio/ksuid
enum KSUID {
    /// KSUID epoch (2014-05-13T00:00:00Z) in Unix seconds.
    private static let epoch: UInt32 = 1_400_000_000

    /// Base62 alphabet used by KSUID.
    private static let base62Chars: [Character] = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    )

    /// Number of raw bytes (4 timestamp + 16 random).
    private static let rawByteCount = 20

    /// Number of characters in the encoded string.
    static let stringLength = 27

    /// Generate a new KSUID string.
    ///
    /// Example: `"2mAy5aFv2MfVhR0PcwZd6sIEWBK"`
    static func generate() -> String {
        let now = UInt32(Date().timeIntervalSince1970) &- epoch
        var bytes = [UInt8](repeating: 0, count: rawByteCount)

        // Timestamp: 4 bytes big-endian.
        bytes[0] = UInt8((now >> 24) & 0xFF)
        bytes[1] = UInt8((now >> 16) & 0xFF)
        bytes[2] = UInt8((now >>  8) & 0xFF)
        bytes[3] = UInt8( now        & 0xFF)

        // Payload: 16 random bytes.
        for i in 0..<16 {
            bytes[4 + i] = UInt8.random(in: 0...255)
        }

        return base62Encode(bytes)
    }

    /// Base62-encode 20 raw bytes into a 27-character string.
    ///
    /// Uses iterative division: treats the byte array as a big-endian
    /// big integer and repeatedly divides by 62, collecting remainders.
    private static func base62Encode(_ bytes: [UInt8]) -> String {
        var remaining = bytes
        var result = [Character]()
        result.reserveCapacity(stringLength)

        /// Divide the big-endian byte array by 62 in place, returning the remainder.
        func divideBy62(_ arr: inout [UInt8]) -> UInt8 {
            var rem: UInt16 = 0
            for i in 0..<arr.count {
                let current = UInt16(rem) << 8 | UInt16(arr[i])
                arr[i] = UInt8(current / 62)
                rem = current % 62
            }
            return UInt8(rem)
        }

        // Repeatedly divide until all bytes are zero.
        while remaining.contains(where: { $0 != 0 }) {
            let rem = divideBy62(&remaining)
            result.append(base62Chars[Int(rem)])
        }

        // Pad with '0' to reach exactly stringLength characters.
        while result.count < stringLength {
            result.append(base62Chars[0])
        }

        return String(result.reversed())
    }
}
