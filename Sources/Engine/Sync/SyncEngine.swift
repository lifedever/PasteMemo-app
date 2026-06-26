import Foundation
import SwiftData

struct SyncClipPayload: Codable {
    let itemID: String
    let createdAt: String
    let lastUsedAt: String
    let content: String
    let contentType: String
    let sourceApp: String?
    let sourceAppBundleID: String?
    let isFavorite: Bool
    let isPinned: Bool
    let isSensitive: Bool
    let linkTitle: String?
    let displayTitle: String?
    let codeLanguage: String?
    let richTextType: String?
    let groupName: String?
    let filePaths: String?
    let originalImageFilePath: String?
    let agentSource: String?
    let ocrText: String?
    let ocrStatus: String?
    let ocrUpdatedAt: String?
    let ocrErrorMessage: String?
    let ocrVersion: Int?
    let imageDataBase64: String?
    let faviconDataBase64: String?
    let richTextDataBase64: String?
    let pasteboardSnapshotBase64: String?
    let truncated: Bool
    let encrypted: Bool
    let payloadEncrypted: String?
    let originClientID: String?
    let originHostname: String?
    let originIP: String?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case content
        case contentType = "content_type"
        case sourceApp = "source_app"
        case sourceAppBundleID = "source_app_bundle_id"
        case isFavorite = "is_favorite"
        case isPinned = "is_pinned"
        case isSensitive = "is_sensitive"
        case linkTitle = "link_title"
        case displayTitle = "display_title"
        case codeLanguage = "code_language"
        case richTextType = "rich_text_type"
        case groupName = "group_name"
        case filePaths = "file_paths"
        case originalImageFilePath = "original_image_file_path"
        case agentSource = "agent_source"
        case ocrText = "ocr_text"
        case ocrStatus = "ocr_status"
        case ocrUpdatedAt = "ocr_updated_at"
        case ocrErrorMessage = "ocr_error_message"
        case ocrVersion = "ocr_version"
        case imageDataBase64 = "image_data_base64"
        case faviconDataBase64 = "favicon_data_base64"
        case richTextDataBase64 = "rich_text_data_base64"
        case pasteboardSnapshotBase64 = "pasteboard_snapshot_base64"
        case truncated
        case encrypted
        case payloadEncrypted = "payload_encrypted"
        case originClientID = "origin_client_id"
        case originHostname = "origin_hostname"
        case originIP = "origin_ip"
    }
}

struct SyncUploadRequest: Codable {
    let clientID: String
    let hostname: String
    let sentAt: String
    let encryption: SyncEncryptionMeta?
    let items: [SyncClipPayload]

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case hostname
        case sentAt = "sent_at"
        case encryption
        case items
    }
}

struct SyncResult {
    let uploaded: Int
    let downloaded: Int
    let deleted: Int
}

struct SyncUploadResponse: Codable {
    let acceptedCount: Int
    let dedupedCount: Int
    let serverTime: String

    enum CodingKeys: String, CodingKey {
        case acceptedCount = "accepted_count"
        case dedupedCount = "deduped_count"
        case serverTime = "server_time"
    }
}

enum SyncError: Error {
    case notConfigured
    case invalidURL
    case noItems
    case httpStatus(Int, String)
    case serverMessage(String)
    case transport(Error)
    case passphraseRequired(String)

    @MainActor
    func localizedDescription() -> String {
        switch self {
        case .notConfigured:
            return L10n.tr("sync.error.notConfigured")
        case .invalidURL:
            return L10n.tr("sync.error.invalidURL")
        case .noItems:
            return L10n.tr("sync.error.noItems")
        case .httpStatus(let code, let body):
            return L10n.tr("sync.error.http", code, body)
        case .serverMessage(let message):
            return message
        case .transport(let error):
            return error.localizedDescription
        case .passphraseRequired(let peerID):
            return L10n.tr("sync.error.passphraseRequired", peerID)
        }
    }
}

@MainActor
enum SyncEngine {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func performSync(
        container: ModelContainer,
        progress: @escaping (_ current: Int, _ total: Int) -> Void
    ) async throws -> SyncResult {
        let defaults = UserDefaults.standard
        let baseURL = defaults.string(forKey: SyncSettings.serverURLKey) ?? ""
        let token = defaults.string(forKey: SyncSettings.tokenKey) ?? ""
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SyncError.notConfigured
        }
        guard let uploadEndpoint = SyncSettings.syncEndpoint(from: baseURL) else {
            throw SyncError.invalidURL
        }

        let clientID = SyncSettings.ensureClientID()
        let since = SyncSettings.lastCompletedAt
        let batchSize = SyncSettings.batchSize
        let localItems = try fetchItems(container: container, since: since)
            .filter { SyncOrigin.isLocalOrigin(originClientID: $0.originClientID, localClientID: clientID) }

        let peerIDs = eligiblePeerIDs(
            from: SyncSettings.selectedPeerIDs.filter { !SyncSettings.clientIDsMatch($0, clientID) }
        )
        let remoteClients = (try? await SyncClientAPI.fetchRemoteClients(baseURL: baseURL, token: token)) ?? []
        let peerByID = Dictionary(uniqueKeysWithValues: remoteClients.map { ($0.clientID.lowercased(), $0) })
        let trashTargets = syncTrashTargets(clientID: clientID, peerIDs: Set(peerIDs))
        let estimatedPull = peerIDs.isEmpty ? 0 : max(1, batchSize)
        let estimatedTrash = trashTargets.isEmpty ? 0 : max(1, batchSize)
        let totalWork = max(localItems.count, 1) + estimatedPull + estimatedTrash
        var workDone = 0
        progress(0, totalWork)

        var uploaded = 0
        if !localItems.isEmpty {
            let total = localItems.count
            for batchStart in stride(from: 0, to: total, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, total)
                let batch = Array(localItems[batchStart..<batchEnd])
                let payloads = try prepareUploadPayloads(batch.map { buildPayload(from: $0, localClientID: clientID) }, clientID: clientID)
                try await uploadBatch(
                    endpoint: uploadEndpoint,
                    token: token,
                    clientID: clientID,
                    payloads: payloads
                )
                workDone = batchEnd
                progress(min(workDone, totalWork), max(totalWork, workDone))
                await Task.yield()
            }
            uploaded = total
        }

        var downloaded = 0
        if let pullEndpoint = SyncSettings.pullEndpoint(from: baseURL) {
            for peerID in peerIDs.sorted() {
                let pulled = try await pullFromPeer(
                    endpoint: pullEndpoint,
                    token: token,
                    peerID: peerID,
                    peerByID: peerByID,
                    container: container,
                    progress: { current, total in
                        progress(min(workDone + current, workDone + total), workDone + max(total, 1))
                    }
                )
                downloaded += pulled
                workDone += max(pulled, 1)
            }
        }

        var deleted = 0
        if let trashEndpoint = SyncSettings.trashEndpoint(from: baseURL) {
            for targetID in trashTargets {
                let removed = try await syncTrashFromClient(
                    endpoint: trashEndpoint,
                    token: token,
                    clientID: targetID,
                    container: container,
                    progress: { current, total in
                        progress(min(workDone + current, workDone + total), max(totalWork, workDone + max(total, 1)))
                    }
                )
                deleted += removed
                workDone += max(removed, 1)
            }
        }

        if uploaded == 0 && downloaded == 0 && deleted == 0 {
            throw SyncError.noItems
        }
        return SyncResult(uploaded: uploaded, downloaded: downloaded, deleted: deleted)
    }

    private static func syncTrashTargets(clientID: String, peerIDs: Set<String>) -> [String] {
        var seen = Set<String>()
        var targets: [String] = []
        for id in [clientID] + peerIDs.sorted() {
            let key = id.lowercased()
            guard seen.insert(key).inserted else { continue }
            targets.append(id)
        }
        return targets
    }

    private static func pullFromPeer(
        endpoint: URL,
        token: String,
        peerID: String,
        peerByID: [String: SyncRemoteClient],
        container: ModelContainer,
        progress: @escaping (_ current: Int, _ total: Int) -> Void
    ) async throws -> Int {
        let since = SyncSettings.lastPullAt(peerID: peerID)
        let sinceString = since.map { isoFormatter.string(from: $0) }
        var cursor: SyncPullCursor?
        var imported = 0
        var page = 0

        while true {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            var query: [URLQueryItem] = [
                URLQueryItem(name: "client_id", value: peerID),
                URLQueryItem(name: "limit", value: "\(SyncSettings.batchSize)"),
            ]
            if let sinceString { query.append(URLQueryItem(name: "since", value: sinceString)) }
            if let cursor, let createdAt = cursor.createdAt {
                query.append(URLQueryItem(name: "cursor_created_at", value: createdAt))
                query.append(URLQueryItem(name: "cursor_item_id", value: cursor.itemID))
            }
            components.queryItems = query

            guard let url = components.url else { throw SyncError.invalidURL }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
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

            let pull: SyncPullResponse
            do {
                pull = try JSONDecoder().decode(SyncPullResponse.self, from: data)
            } catch {
                throw SyncError.serverMessage(L10n.tr("sync.error.decodeFailed", error.localizedDescription))
            }
            if !pull.items.isEmpty {
                let peerPassword = SyncEncryption.peerPassphrase(peerID: peerID)
                let decrypted = try pull.items.map { try decryptPayloadIfNeeded($0, password: peerPassword) }
                let peer = peerByID[peerID.lowercased()]
                let added = try importPayloads(
                    decrypted,
                    peerID: peerID,
                    peerHostname: peer?.lastHostname ?? "",
                    peerIP: peer?.lastIP ?? "",
                    container: container
                )
                imported += added
            }

            page += 1
            progress(imported, max(imported, page * SyncSettings.batchSize))

            guard pull.hasMore, let next = pull.nextCursor else { break }
            cursor = next
        }

        SyncSettings.setLastPullAt(peerID: peerID, date: Date())
        return imported
    }

    private static func syncTrashFromClient(
        endpoint: URL,
        token: String,
        clientID: String,
        container: ModelContainer,
        progress: @escaping (_ current: Int, _ total: Int) -> Void
    ) async throws -> Int {
        let since = SyncSettings.lastTrashSyncAt(clientID: clientID)
        let sinceString = since.map { isoFormatter.string(from: $0) }
        var cursor: SyncPullCursor?
        var removed = 0
        var page = 0

        while true {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            var query: [URLQueryItem] = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "limit", value: "\(SyncSettings.batchSize)"),
            ]
            if let sinceString { query.append(URLQueryItem(name: "since", value: sinceString)) }
            if let cursor, let deletedAt = cursor.deletedAt {
                query.append(URLQueryItem(name: "cursor_deleted_at", value: deletedAt))
                query.append(URLQueryItem(name: "cursor_item_id", value: cursor.itemID))
            }
            components.queryItems = query

            guard let url = components.url else { throw SyncError.invalidURL }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 60

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncError.serverMessage(L10n.tr("sync.error.invalidResponse"))
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                throw SyncError.httpStatus(http.statusCode, bodyText)
            }

            let trash: SyncTrashResponse
            do {
                trash = try JSONDecoder().decode(SyncTrashResponse.self, from: data)
            } catch {
                throw SyncError.serverMessage(L10n.tr("sync.error.decodeFailed", error.localizedDescription))
            }

            if !trash.items.isEmpty {
                let itemIDs = trash.items.map(\.itemID)
                removed += try deleteLocalItems(itemIDs: itemIDs, container: container)
            }

            page += 1
            progress(removed, max(removed, page * SyncSettings.batchSize))

            guard trash.hasMore, let next = trash.nextCursor else { break }
            cursor = next
        }

        SyncSettings.setLastTrashSyncAt(clientID: clientID, date: Date())
        return removed
    }

    private static func deleteLocalItems(itemIDs: [String], container: ModelContainer) throws -> Int {
        guard !itemIDs.isEmpty else { return 0 }
        let context = ModelContext(container)
        var toDelete: [ClipItem] = []
        for itemID in itemIDs {
            let remoteID = itemID
            let descriptor = FetchDescriptor<ClipItem>(
                predicate: #Predicate<ClipItem> { $0.itemID == remoteID }
            )
            toDelete.append(contentsOf: try context.fetch(descriptor))
        }
        guard !toDelete.isEmpty else { return 0 }
        ClipItemStore.deleteAndNotify(toDelete, from: context)
        return toDelete.count
    }

    /// Delete every local item whose `originClientID` belongs to one of the supplied peers.
    /// Used by full sync to drop the local copy of a peer's data so the next pull re-imports it cleanly.
    static func deleteLocalItemsFromPeers(peerIDs: [String], container: ModelContainer?) {
        guard let container, !peerIDs.isEmpty else { return }
        let normalizedPeers = Set(peerIDs.map { $0.lowercased() })
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate<ClipItem> { item in
                item.originClientID != nil
            }
        )
        guard let items = try? context.fetch(descriptor) else { return }
        let toDelete = items.filter { item in
            guard let origin = item.originClientID?.lowercased(), !origin.isEmpty else { return false }
            return normalizedPeers.contains(origin)
        }
        guard !toDelete.isEmpty else { return }
        ClipItemStore.deleteAndNotify(toDelete, from: context)
    }

    /// Purge this client and every selected peer's data on the server. Used by full sync so the
    /// subsequent `syncNow` re-uploads everything from scratch.
    static func purgeAllForFullSync(
        clientID: String,
        peerIDs: [String],
        baseURL: String,
        token: String
    ) async throws {
        let targets = [clientID] + peerIDs
        for target in targets {
            try await SyncEncryption.purgeServerItems(
                clientID: target,
                baseURL: baseURL,
                token: token
            )
        }
    }

    private static func importPayloads(
        _ payloads: [SyncClipPayload],
        peerID: String,
        peerHostname: String,
        peerIP: String,
        container: ModelContainer
    ) throws -> Int {
        let context = ModelContext(container)
        var imported = 0
        for payload in payloads {
            if try importPayload(payload, peerID: peerID, peerHostname: peerHostname, peerIP: peerIP, context: context) {
                imported += 1
            }
        }
        if imported > 0 {
            try context.save()
            ClipItemStore.saveAndNotify(context)
        }
        return imported
    }

    private static func importPayload(
        _ payload: SyncClipPayload,
        peerID: String,
        peerHostname: String,
        peerIP: String,
        context: ModelContext
    ) throws -> Bool {
        let remoteID = payload.itemID
        let descriptor = FetchDescriptor<ClipItem>(
            predicate: #Predicate<ClipItem> { $0.itemID == remoteID }
        )
        if (try context.fetchCount(descriptor)) > 0 {
            return false
        }

        let createdAt = isoFormatter.date(from: payload.createdAt) ?? Date()
        let lastUsedAt = isoFormatter.date(from: payload.lastUsedAt) ?? createdAt
        let contentType = ClipContentType(rawValue: payload.contentType) ?? .text

        let clip = ClipItem(
            content: payload.content,
            contentType: contentType,
            imageData: decodeBase64(payload.imageDataBase64),
            originalImageFilePath: payload.originalImageFilePath,
            sourceApp: payload.sourceApp,
            sourceAppBundleID: payload.sourceAppBundleID,
            isFavorite: payload.isFavorite,
            isPinned: payload.isPinned,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            codeLanguage: payload.codeLanguage,
            richTextData: decodeBase64(payload.richTextDataBase64),
            richTextType: payload.richTextType,
            filePaths: payload.filePaths,
            agentSource: payload.agentSource
        )
        clip.itemID = remoteID
        clip.isSensitive = payload.isSensitive
        clip.linkTitle = payload.linkTitle
        clip.displayTitle = payload.displayTitle
        clip.faviconData = decodeBase64(payload.faviconDataBase64)
        clip.groupName = payload.groupName
        clip.pasteboardSnapshot = decodeBase64(payload.pasteboardSnapshotBase64)
        clip.ocrText = payload.ocrText
        clip.ocrStatus = payload.ocrStatus ?? clip.ocrStatus
        if let ocrUpdatedAt = payload.ocrUpdatedAt {
            clip.ocrUpdatedAt = isoFormatter.date(from: ocrUpdatedAt)
        }
        clip.ocrErrorMessage = payload.ocrErrorMessage
        if let ocrVersion = payload.ocrVersion {
            clip.ocrVersion = ocrVersion
        }
        clip.originClientID = payload.originClientID ?? peerID
        clip.originHostname = payload.originHostname ?? peerHostname
        clip.originIP = payload.originIP ?? peerIP
        context.insert(clip)
        return true
    }

    private static func decodeBase64(_ raw: String?) -> Data? {
        guard let raw, !raw.isEmpty else { return nil }
        return Data(base64Encoded: raw)
    }

    private static func fetchItems(container: ModelContainer, since: Date?) throws -> [ClipItem] {
        let context = ModelContext(container)
        let descriptor: FetchDescriptor<ClipItem>
        if let since {
            descriptor = FetchDescriptor<ClipItem>(
                predicate: #Predicate<ClipItem> { $0.createdAt > since },
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
        } else {
            descriptor = FetchDescriptor<ClipItem>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
        }
        return try context.fetch(descriptor)
    }

    private static func buildPayload(from clip: ClipItem, localClientID: String) -> SyncClipPayload {
        var truncated = false
        let imageData = encodeBinary(clip.imageBytesForExport(), truncated: &truncated)
        let faviconData = encodeBinary(clip.faviconData, truncated: &truncated)
        let richTextData = encodeBinary(clip.richTextData, truncated: &truncated)
        let pasteboardData = encodeBinary(clip.pasteboardSnapshot, truncated: &truncated)

        let originID = clip.originClientID ?? localClientID
        let originHost = clip.originHostname ?? SyncOrigin.localHostname()
        let originIP = clip.originIP ?? SyncOrigin.localIPAddress() ?? ""

        return SyncClipPayload(
            itemID: jsonSafeString(clip.itemID),
            createdAt: isoFormatter.string(from: clip.createdAt),
            lastUsedAt: isoFormatter.string(from: clip.lastUsedAt),
            content: jsonSafeString(clip.content),
            contentType: clip.contentType.rawValue,
            sourceApp: clip.sourceApp.map(jsonSafeString),
            sourceAppBundleID: clip.sourceAppBundleID.map(jsonSafeString),
            isFavorite: clip.isFavorite,
            isPinned: clip.isPinned,
            isSensitive: clip.isSensitive,
            linkTitle: clip.linkTitle.map(jsonSafeString),
            displayTitle: clip.displayTitle.map(jsonSafeString),
            codeLanguage: clip.codeLanguage.map(jsonSafeString),
            richTextType: clip.richTextType.map(jsonSafeString),
            groupName: clip.groupName.map(jsonSafeString),
            filePaths: clip.filePaths.map(jsonSafeString),
            originalImageFilePath: clip.originalImageFilePath.map(jsonSafeString),
            agentSource: clip.agentSource.map(jsonSafeString),
            ocrText: clip.ocrText.map(jsonSafeString),
            ocrStatus: clip.ocrStatus,
            ocrUpdatedAt: clip.ocrUpdatedAt.map { isoFormatter.string(from: $0) },
            ocrErrorMessage: clip.ocrErrorMessage.map(jsonSafeString),
            ocrVersion: clip.ocrVersion,
            imageDataBase64: imageData,
            faviconDataBase64: faviconData,
            richTextDataBase64: richTextData,
            pasteboardSnapshotBase64: pasteboardData,
            truncated: truncated,
            encrypted: false,
            payloadEncrypted: nil,
            originClientID: jsonSafeString(originID),
            originHostname: jsonSafeString(originHost),
            originIP: jsonSafeString(originIP)
        )
    }

    private static func eligiblePeerIDs(from selected: Set<String>) -> [String] {
        selected.filter { peerID in
            guard let info = SyncEncryption.peerInfo(for: peerID), info.enabled else { return true }
            return SyncEncryption.hasPeerPassphrase(peerID: peerID)
        }.sorted()
    }

    private static func prepareUploadPayloads(_ payloads: [SyncClipPayload], clientID: String) throws -> [SyncClipPayload] {
        guard SyncEncryption.isEnabled else { return payloads }
        guard let password = SyncEncryption.ownPassphrase(clientID: clientID) else {
            throw SyncError.passphraseRequired(clientID)
        }
        return try payloads.map { try encryptPayloadForUpload($0, password: password) }
    }

    private static func encryptPayloadForUpload(_ payload: SyncClipPayload, password: String) throws -> SyncClipPayload {
        let encoder = JSONEncoder()
        let inner = SyncClipPayload(
            itemID: payload.itemID,
            createdAt: payload.createdAt,
            lastUsedAt: payload.lastUsedAt,
            content: payload.content,
            contentType: payload.contentType,
            sourceApp: payload.sourceApp,
            sourceAppBundleID: payload.sourceAppBundleID,
            isFavorite: payload.isFavorite,
            isPinned: payload.isPinned,
            isSensitive: payload.isSensitive,
            linkTitle: payload.linkTitle,
            displayTitle: payload.displayTitle,
            codeLanguage: payload.codeLanguage,
            richTextType: payload.richTextType,
            groupName: payload.groupName,
            filePaths: payload.filePaths,
            originalImageFilePath: payload.originalImageFilePath,
            agentSource: payload.agentSource,
            ocrText: payload.ocrText,
            ocrStatus: payload.ocrStatus,
            ocrUpdatedAt: payload.ocrUpdatedAt,
            ocrErrorMessage: payload.ocrErrorMessage,
            ocrVersion: payload.ocrVersion,
            imageDataBase64: payload.imageDataBase64,
            faviconDataBase64: payload.faviconDataBase64,
            richTextDataBase64: payload.richTextDataBase64,
            pasteboardSnapshotBase64: payload.pasteboardSnapshotBase64,
            truncated: payload.truncated,
            encrypted: false,
            payloadEncrypted: nil,
            originClientID: payload.originClientID,
            originHostname: payload.originHostname,
            originIP: payload.originIP
        )
        let json = try encoder.encode(inner)
        let encryptedBase64 = try SyncCrypto.encryptPayloadJSON(json, password: password)
        return SyncClipPayload(
            itemID: payload.itemID,
            createdAt: payload.createdAt,
            lastUsedAt: payload.lastUsedAt,
            content: "",
            contentType: payload.contentType,
            sourceApp: nil,
            sourceAppBundleID: nil,
            isFavorite: false,
            isPinned: false,
            isSensitive: false,
            linkTitle: nil,
            displayTitle: nil,
            codeLanguage: nil,
            richTextType: nil,
            groupName: nil,
            filePaths: nil,
            originalImageFilePath: nil,
            agentSource: nil,
            ocrText: nil,
            ocrStatus: nil,
            ocrUpdatedAt: nil,
            ocrErrorMessage: nil,
            ocrVersion: nil,
            imageDataBase64: nil,
            faviconDataBase64: nil,
            richTextDataBase64: nil,
            pasteboardSnapshotBase64: nil,
            truncated: false,
            encrypted: true,
            payloadEncrypted: encryptedBase64,
            originClientID: nil,
            originHostname: nil,
            originIP: nil
        )
    }

    private static func decryptPayloadIfNeeded(_ payload: SyncClipPayload, password: String?) throws -> SyncClipPayload {
        guard payload.encrypted else { return payload }
        guard let enc = payload.payloadEncrypted, !enc.isEmpty else {
            throw SyncError.serverMessage(L10n.tr("sync.error.missingEncryptedPayload"))
        }
        guard let password else {
            throw SyncError.passphraseRequired("")
        }
        let json = try SyncCrypto.decryptPayloadJSON(enc, password: password)
        return try JSONDecoder().decode(SyncClipPayload.self, from: json)
    }

    /// Strip characters that break JSON UTF-8 decoding on the server.
    private static func jsonSafeString(_ value: String) -> String {
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            let v = scalar.value
            if (0xD800...0xDFFF).contains(v) || v == 0 { continue }
            scalars.append(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func stripBinaryFields(_ payload: SyncClipPayload) -> SyncClipPayload {
        SyncClipPayload(
            itemID: payload.itemID,
            createdAt: payload.createdAt,
            lastUsedAt: payload.lastUsedAt,
            content: payload.content,
            contentType: payload.contentType,
            sourceApp: payload.sourceApp,
            sourceAppBundleID: payload.sourceAppBundleID,
            isFavorite: payload.isFavorite,
            isPinned: payload.isPinned,
            isSensitive: payload.isSensitive,
            linkTitle: payload.linkTitle,
            displayTitle: payload.displayTitle,
            codeLanguage: payload.codeLanguage,
            richTextType: payload.richTextType,
            groupName: payload.groupName,
            filePaths: payload.filePaths,
            originalImageFilePath: payload.originalImageFilePath,
            agentSource: payload.agentSource,
            ocrText: payload.ocrText,
            ocrStatus: payload.ocrStatus,
            ocrUpdatedAt: payload.ocrUpdatedAt,
            ocrErrorMessage: payload.ocrErrorMessage,
            ocrVersion: payload.ocrVersion,
            imageDataBase64: nil,
            faviconDataBase64: nil,
            richTextDataBase64: nil,
            pasteboardSnapshotBase64: nil,
            truncated: true,
            encrypted: payload.encrypted,
            payloadEncrypted: payload.payloadEncrypted,
            originClientID: payload.originClientID,
            originHostname: payload.originHostname,
            originIP: payload.originIP
        )
    }

    private static func encodeBinary(_ data: Data?, truncated: inout Bool) -> String? {
        guard let data, !data.isEmpty else { return nil }
        if data.count > SyncSettings.binaryFieldCap {
            truncated = true
            return nil
        }
        return data.base64EncodedString()
    }

    private static func uploadBatch(
        endpoint: URL,
        token: String,
        clientID: String,
        payloads: [SyncClipPayload]
    ) async throws {
        try await uploadBatchAdaptive(
            endpoint: endpoint,
            token: token,
            clientID: clientID,
            payloads: payloads,
            allowBinaryStrip: true
        )
    }

    private static func uploadBatchAdaptive(
        endpoint: URL,
        token: String,
        clientID: String,
        payloads: [SyncClipPayload],
        allowBinaryStrip: Bool
    ) async throws {
        guard !payloads.isEmpty else { return }

        let body = try encodeRequestBody(clientID: clientID, payloads: payloads)
        if body.count <= SyncSettings.maxRequestBodyBytes {
            try await sendRequest(endpoint: endpoint, token: token, body: body)
            return
        }

        if payloads.count == 1 {
            if allowBinaryStrip, payloads[0].imageDataBase64 != nil
                || payloads[0].pasteboardSnapshotBase64 != nil
                || payloads[0].richTextDataBase64 != nil {
                let stripped = stripBinaryFields(payloads[0])
                try await uploadBatchAdaptive(
                    endpoint: endpoint,
                    token: token,
                    clientID: clientID,
                    payloads: [stripped],
                    allowBinaryStrip: false
                )
                return
            }
            throw SyncError.serverMessage(L10n.tr("sync.error.payloadTooLarge"))
        }

        let mid = payloads.count / 2
        try await uploadBatchAdaptive(
            endpoint: endpoint,
            token: token,
            clientID: clientID,
            payloads: Array(payloads[..<mid]),
            allowBinaryStrip: allowBinaryStrip
        )
        try await uploadBatchAdaptive(
            endpoint: endpoint,
            token: token,
            clientID: clientID,
            payloads: Array(payloads[mid...]),
            allowBinaryStrip: allowBinaryStrip
        )
    }

    private static func encodeRequestBody(clientID: String, payloads: [SyncClipPayload]) throws -> Data {
        let requestBody = SyncUploadRequest(
            clientID: clientID,
            hostname: jsonSafeString(SyncOrigin.localHostname()),
            sentAt: isoFormatter.string(from: Date()),
            encryption: SyncEncryption.uploadMeta(),
            items: payloads
        )
        let encoder = JSONEncoder()
        let body = try encoder.encode(requestBody)
        _ = try JSONSerialization.jsonObject(with: body)
        return body
    }

    private static func sendRequest(endpoint: URL, token: String, body: Data) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 120

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SyncError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.serverMessage(L10n.tr("sync.error.invalidResponse"))
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.httpStatus(http.statusCode, bodyText)
        }

        _ = try? JSONDecoder().decode(SyncUploadResponse.self, from: data)
    }
}
