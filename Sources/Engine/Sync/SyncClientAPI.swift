import Foundation

struct SyncRemoteClient: Codable, Identifiable, Hashable {
    let clientID: String
    let lastIP: String
    let lastHostname: String
    let lastSyncAt: String
    let lastSyncCount: Int
    let totalSyncCount: Int
    let itemCount: Int
    let encryptionEnabled: Bool
    let encryptionKeyFingerprint: String
    let encryptionSalt: String

    var id: String { clientID }

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case lastIP = "last_ip"
        case lastHostname = "last_hostname"
        case lastSyncAt = "last_sync_at"
        case lastSyncCount = "last_sync_count"
        case totalSyncCount = "total_sync_count"
        case itemCount = "item_count"
        case encryptionEnabled = "encryption_enabled"
        case encryptionKeyFingerprint = "encryption_key_fingerprint"
        case encryptionSalt = "encryption_salt"
    }

    var peerEncryptionInfo: PeerEncryptionInfo? {
        guard encryptionEnabled, !encryptionSalt.isEmpty else { return nil }
        return PeerEncryptionInfo(
            enabled: true,
            keyFingerprint: encryptionKeyFingerprint,
            salt: encryptionSalt
        )
    }

    var needsPeerPassphrase: Bool {
        guard let info = peerEncryptionInfo else { return false }
        return !SyncEncryption.hasPeerPassphrase(peerID: clientID)
            || SyncEncryption.peerInfo(for: clientID) != info
    }

    @MainActor
    var displayName: String {
        if !lastHostname.isEmpty { return lastHostname }
        if clientID.count > 12 {
            return String(clientID.prefix(8)) + "…"
        }
        return clientID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try container.decode(String.self, forKey: .clientID)
        lastIP = try container.decodeIfPresent(String.self, forKey: .lastIP) ?? ""
        lastHostname = try container.decodeIfPresent(String.self, forKey: .lastHostname) ?? ""
        lastSyncAt = try container.decodeIfPresent(String.self, forKey: .lastSyncAt) ?? ""
        lastSyncCount = try container.decodeIfPresent(Int.self, forKey: .lastSyncCount) ?? 0
        totalSyncCount = try container.decodeIfPresent(Int.self, forKey: .totalSyncCount) ?? 0
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
        encryptionEnabled = try container.decodeIfPresent(Bool.self, forKey: .encryptionEnabled) ?? false
        encryptionKeyFingerprint = try container.decodeIfPresent(String.self, forKey: .encryptionKeyFingerprint) ?? ""
        encryptionSalt = try container.decodeIfPresent(String.self, forKey: .encryptionSalt) ?? ""
    }
}

struct SyncPullResponse: Codable {
    let items: [SyncClipPayload]
    let hasMore: Bool
    let nextCursor: SyncPullCursor?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
}

struct SyncPullCursor: Codable {
    let createdAt: String?
    let itemID: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case itemID = "item_id"
        case deletedAt = "deleted_at"
    }
}

struct SyncTrashItem: Codable {
    let itemID: String
    let deletedAt: String

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case deletedAt = "deleted_at"
    }
}

struct SyncTrashResponse: Codable {
    let items: [SyncTrashItem]
    let hasMore: Bool
    let nextCursor: SyncPullCursor?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
}

enum SyncClientAPI {
    @MainActor
    static func fetchRemoteClients(baseURL: String, token: String) async throws -> [SyncRemoteClient] {
        guard let endpoint = SyncSettings.clientsEndpoint(from: baseURL) else {
            throw SyncError.invalidURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.serverMessage(L10n.tr("sync.error.invalidResponse"))
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.httpStatus(http.statusCode, bodyText)
        }
        return try JSONDecoder().decode([SyncRemoteClient].self, from: data)
    }
}
