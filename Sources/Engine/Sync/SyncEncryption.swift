import Foundation

struct SyncEncryptionMeta: Codable {
    let enabled: Bool
    let keyFingerprint: String
    let salt: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case keyFingerprint = "key_fingerprint"
        case salt
    }
}

struct PeerEncryptionInfo: Codable, Hashable {
    let enabled: Bool
    let keyFingerprint: String
    let salt: String
}

enum SyncEncryption {
    static let enabledKey = "syncEncryptionEnabled"
    static let saltKey = "syncEncryptionSalt"
    static let fingerprintKey = "syncEncryptionKeyFingerprint"
    static let passphraseKey = "syncEncryptionPassphrase"
    static let peerInfoKey = "syncPeerEncryptionInfo"
    static let peerPassphrasesKey = "syncPeerPassphrases"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var saltBase64: String? {
        UserDefaults.standard.string(forKey: saltKey)
    }

    static var keyFingerprint: String? {
        UserDefaults.standard.string(forKey: fingerprintKey)
    }

    static func ownPassphrase(clientID: String) -> String? {
        _ = clientID
        guard let value = UserDefaults.standard.string(forKey: passphraseKey),
              !value.isEmpty else { return nil }
        return value
    }

    static func setOwnPassphrase(_ passphrase: String, clientID: String) {
        _ = clientID
        UserDefaults.standard.set(passphrase, forKey: passphraseKey)
    }

    static func clearOwnPassphrase(clientID: String) {
        _ = clientID
        UserDefaults.standard.removeObject(forKey: passphraseKey)
    }

    static func peerPassphrase(peerID: String) -> String? {
        guard let map = UserDefaults.standard.dictionary(forKey: peerPassphrasesKey) as? [String: String],
              let value = map[peerID],
              !value.isEmpty else { return nil }
        return value
    }

    static func setPeerPassphrase(_ passphrase: String, peerID: String) {
        var map = (UserDefaults.standard.dictionary(forKey: peerPassphrasesKey) as? [String: String]) ?? [:]
        map[peerID] = passphrase
        UserDefaults.standard.set(map, forKey: peerPassphrasesKey)
    }

    static func clearPeerPassphrase(peerID: String) {
        var map = (UserDefaults.standard.dictionary(forKey: peerPassphrasesKey) as? [String: String]) ?? [:]
        map.removeValue(forKey: peerID)
        UserDefaults.standard.set(map, forKey: peerPassphrasesKey)
    }

    static func hasPeerPassphrase(peerID: String) -> Bool {
        peerPassphrase(peerID: peerID) != nil
    }

    static func uploadMeta() -> SyncEncryptionMeta {
        if isEnabled, let fp = keyFingerprint {
            return SyncEncryptionMeta(enabled: true, keyFingerprint: fp, salt: saltBase64)
        }
        return SyncEncryptionMeta(enabled: false, keyFingerprint: "", salt: nil)
    }

    static func peerInfo(for peerID: String) -> PeerEncryptionInfo? {
        guard let map = UserDefaults.standard.dictionary(forKey: peerInfoKey) as? [String: Data],
              let data = map[peerID] else { return nil }
        return try? JSONDecoder().decode(PeerEncryptionInfo.self, from: data)
    }

    static func setPeerInfo(_ info: PeerEncryptionInfo, for peerID: String) {
        var map = (UserDefaults.standard.dictionary(forKey: peerInfoKey) as? [String: Data]) ?? [:]
        if let data = try? JSONEncoder().encode(info) {
            map[peerID] = data
        }
        UserDefaults.standard.set(map, forKey: peerInfoKey)
    }

    static func removePeerInfo(for peerID: String) {
        var map = (UserDefaults.standard.dictionary(forKey: peerInfoKey) as? [String: Data]) ?? [:]
        map.removeValue(forKey: peerID)
        UserDefaults.standard.set(map, forKey: peerInfoKey)
        clearPeerPassphrase(peerID: peerID)
    }

    static func resetSyncWatermarks() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SyncSettings.lastCompletedAtKey)
        defaults.removeObject(forKey: SyncSettings.peerLastPullAtKey)
        defaults.removeObject(forKey: SyncSettings.peerLastTrashSyncAtKey)
    }

    @MainActor
    static func purgeServerItems(clientID: String, baseURL: String, token: String) async throws {
        guard let base = SyncSettings.normalizedServerURL(baseURL),
              let encoded = clientID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: base + "/api/v1/clients/\(encoded)/items") else {
            throw SyncError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.serverMessage(L10n.tr("sync.error.invalidResponse"))
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.httpStatus(http.statusCode, bodyText)
        }
    }

    static func verifyPeerPassphrase(_ passphrase: String, info: PeerEncryptionInfo) throws -> Bool {
        guard let saltData = Data(base64Encoded: info.salt) else { return false }
        return SyncCrypto.verifyPassphrase(passphrase, salt: saltData, expectedFingerprint: info.keyFingerprint)
    }

    @MainActor
    static func applyEncryptionChange(
        enabled: Bool,
        passphrase: String,
        clientID: String,
        baseURL: String,
        token: String
    ) async throws -> Bool {
        let wasEnabled = isEnabled
        var newSalt: Data?
        var newFingerprint: String?
        var configChanged = wasEnabled != enabled

        if enabled {
            if wasEnabled,
               let existingSalt = saltBase64.flatMap({ Data(base64Encoded: $0) }),
               let existingFP = keyFingerprint,
               SyncCrypto.verifyPassphrase(passphrase, salt: existingSalt, expectedFingerprint: existingFP) {
                setOwnPassphrase(passphrase, clientID: clientID)
                return false
            }
            newSalt = SyncCrypto.generateSalt()
            guard let salt = newSalt else { throw CryptoError.keyDerivationFailed }
            newFingerprint = try SyncCrypto.keyFingerprint(password: passphrase, salt: salt)
            configChanged = true
        }

        guard configChanged else { return false }

        try await purgeServerItems(clientID: clientID, baseURL: baseURL, token: token)
        resetSyncWatermarks()

        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: enabledKey)

        if enabled, let salt = newSalt, let fp = newFingerprint {
            defaults.set(salt.base64EncodedString(), forKey: saltKey)
            defaults.set(fp, forKey: fingerprintKey)
            setOwnPassphrase(passphrase, clientID: clientID)
        } else {
            defaults.removeObject(forKey: saltKey)
            defaults.removeObject(forKey: fingerprintKey)
            clearOwnPassphrase(clientID: clientID)
        }
        return true
    }

    static func savePeerPassphrase(_ passphrase: String, peerID: String, info: PeerEncryptionInfo) throws {
        guard try verifyPeerPassphrase(passphrase, info: info) else {
            throw CryptoError.wrongPassword
        }
        setPeerPassphrase(passphrase, peerID: peerID)
        setPeerInfo(info, for: peerID)
    }
}
