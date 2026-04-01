import Foundation
import CryptoKit
import CommonCrypto

enum DataPorterCrypto {

    private static let MAGIC: [UInt8] = [0x50, 0x4D, 0x45, 0x4D] // "PMEM"
    private static let FORMAT_VERSION: UInt8 = 0x01
    private static let FLAG_PLAINTEXT: UInt8 = 0x00
    private static let FLAG_ENCRYPTED: UInt8 = 0x01
    private static let HEADER_SIZE = 6 // 4 magic + 1 version + 1 flags
    private static let SALT_SIZE = 32
    private static let PBKDF2_ITERATIONS: UInt32 = 600_000

    static func wrapPlaintext(_ data: Data) -> Data {
        var output = Data(MAGIC)
        output.append(FORMAT_VERSION)
        output.append(FLAG_PLAINTEXT)
        output.append(data)
        return output
    }

    static func encrypt(data: Data, password: String) throws -> Data {
        let salt = generateSalt()
        let key = try deriveKey(password: password, salt: salt)

        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptoError.encryptionFailed
        }

        var output = Data(MAGIC)
        output.append(FORMAT_VERSION)
        output.append(FLAG_ENCRYPTED)
        output.append(salt)
        output.append(combined)
        return output
    }

    static func decrypt(fileData: Data, password: String) throws -> Data {
        guard fileData.count > HEADER_SIZE else {
            throw CryptoError.invalidFormat
        }
        try validateHeader(fileData)

        let flags = fileData[5]
        if flags == FLAG_PLAINTEXT {
            return fileData.dropFirst(HEADER_SIZE)
        }

        guard flags == FLAG_ENCRYPTED else {
            throw CryptoError.invalidFormat
        }
        guard fileData.count > HEADER_SIZE + SALT_SIZE else {
            throw CryptoError.invalidFormat
        }

        let salt = fileData[HEADER_SIZE..<(HEADER_SIZE + SALT_SIZE)]
        let sealedData = fileData[(HEADER_SIZE + SALT_SIZE)...]

        let key = try deriveKey(password: password, salt: Data(salt))
        let sealedBox = try AES.GCM.SealedBox(combined: sealedData)

        do {
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw CryptoError.wrongPassword
        }
    }

    static func isEncrypted(_ fileData: Data) -> Bool {
        guard fileData.count > HEADER_SIZE else { return false }
        guard Array(fileData.prefix(4)) == MAGIC else { return false }
        return fileData[5] == FLAG_ENCRYPTED
    }

    // MARK: - Private

    private static func validateHeader(_ data: Data) throws {
        guard Array(data.prefix(4)) == MAGIC else {
            throw CryptoError.invalidFormat
        }
        guard data[4] == FORMAT_VERSION else {
            throw CryptoError.unsupportedVersion
        }
    }

    private static func generateSalt() -> Data {
        var salt = Data(count: SALT_SIZE)
        salt.withUnsafeMutableBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, SALT_SIZE, ptr)
        }
        return salt
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
                        PBKDF2_ITERATIONS,
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

// MARK: - Errors

enum CryptoError: LocalizedError {
    case invalidFormat
    case unsupportedVersion
    case encryptionFailed
    case wrongPassword
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Invalid file format."
        case .unsupportedVersion: return "Unsupported file version."
        case .encryptionFailed: return "Encryption failed."
        case .wrongPassword: return "Wrong password."
        case .keyDerivationFailed: return "Key derivation failed."
        }
    }
}
