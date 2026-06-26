import Foundation

/// K-Sortable Unique Identifier (segmentio/ksuid compatible).
enum KSUID {
    static let encodedLength = 27
    static let byteLength = 20

    private static let timestampBytes = 4
    private static let payloadBytes = 16
    private static let epoch: TimeInterval = 1_400_000_000
    private static let base62 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let zeroPadding = Array("000000000000000000000000000".utf8)

    /// Returns a new base62-encoded KSUID string.
    static func generate(at date: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: byteLength)
        let ts = UInt32(date.timeIntervalSince1970 - epoch)
        bytes[0] = UInt8((ts >> 24) & 0xFF)
        bytes[1] = UInt8((ts >> 16) & 0xFF)
        bytes[2] = UInt8((ts >> 8) & 0xFF)
        bytes[3] = UInt8(ts & 0xFF)

        let payload = randomPayload()
        bytes.replaceSubrange(timestampBytes..<byteLength, with: payload)
        return encode(bytes)
    }

    private static func randomPayload() -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: payloadBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, payloadBytes, &buffer)
        guard status == errSecSuccess else {
            fatalError("KSUID: SecRandomCopyBytes failed with status \(status)")
        }
        return buffer
    }

    /// Encodes 20 raw bytes to a 27-character base62 string.
    private static func encode(_ src: [UInt8]) -> String {
        precondition(src.count == byteLength)

        let srcBase: UInt64 = 4_294_967_296
        let dstBase: UInt64 = 62

        let parts: [UInt32] = [
            UInt32(src[0]) << 24 | UInt32(src[1]) << 16 | UInt32(src[2]) << 8 | UInt32(src[3]),
            UInt32(src[4]) << 24 | UInt32(src[5]) << 16 | UInt32(src[6]) << 8 | UInt32(src[7]),
            UInt32(src[8]) << 24 | UInt32(src[9]) << 16 | UInt32(src[10]) << 8 | UInt32(src[11]),
            UInt32(src[12]) << 24 | UInt32(src[13]) << 16 | UInt32(src[14]) << 8 | UInt32(src[15]),
            UInt32(src[16]) << 24 | UInt32(src[17]) << 16 | UInt32(src[18]) << 8 | UInt32(src[19]),
        ]

        var dst = [UInt8](repeating: base62[0], count: encodedLength)
        var n = encodedLength
        var bp = parts

        while !bp.isEmpty {
            var quotient: [UInt32] = []
            var remainder: UInt64 = 0

            for c in bp {
                let value = UInt64(c) + remainder * srcBase
                let digit = value / dstBase
                remainder = value % dstBase
                if !quotient.isEmpty || digit != 0 {
                    quotient.append(UInt32(digit))
                }
            }

            n -= 1
            dst[n] = base62[Int(remainder)]
            bp = quotient
        }

        if n > 0 {
            dst.replaceSubrange(0..<n, with: zeroPadding[0..<n])
        }
        return String(bytes: dst, encoding: .ascii)!
    }
}
