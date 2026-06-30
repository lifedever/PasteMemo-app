import Foundation
import CryptoKit
import CommonCrypto

enum SyncCrypto {
    private static let saltSize = 32
    private static let pbkdf2Iterations: UInt32 = 600_000

    static func generateSalt() -> Data {
        var salt = Data(count: saltSize)
        salt.withUnsafeMutableBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, saltSize, ptr)
        }
        return salt
    }

    static func keyFingerprint(password: String, salt: Data) throws -> String {
        let key = try deriveKey(password: password, salt: salt)
        let hash = SHA256.hash(data: key.withUnsafeBytes { Data($0) })
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func verifyPassphrase(_ password: String, salt: Data, expectedFingerprint: String) -> Bool {
        guard let actual = try? keyFingerprint(password: password, salt: salt) else { return false }
        return actual.caseInsensitiveCompare(expectedFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    static func encryptPayloadJSON(_ json: Data, password: String) throws -> String {
        let encrypted = try DataPorterCrypto.encrypt(data: json, password: password)
        return encrypted.base64EncodedString()
    }

    static func decryptPayloadJSON(_ base64: String, password: String) throws -> Data {
        guard let data = Data(base64Encoded: base64) else {
            throw CryptoError.invalidFormat
        }
        return try DataPorterCrypto.decrypt(fileData: data, password: password)
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: 32)

        let status = derivedKey.withUnsafeMutableBytes { derivedBuffer in
            salt.withUnsafeBytes { saltBuffer in
                passwordData.withUnsafeBytes { passwordBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw CryptoError.keyDerivationFailed
        }
        return SymmetricKey(data: derivedKey)
    }
}
