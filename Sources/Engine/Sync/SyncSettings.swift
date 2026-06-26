import Foundation

enum SyncSettings {
    static let enabledKey = "syncEnabled"
    static let clientIDKey = "syncClientID"
    static let serverURLKey = "syncServerURL"
    static let tokenKey = "syncToken"
    static let intervalMinutesKey = "syncIntervalMinutes"
    static let intervalSecondsKey = "syncIntervalSeconds" // legacy
    static let intervalHoursKey = "syncIntervalHours" // legacy
    static let batchSizeKey = "syncBatchSize"
    static let lastCompletedAtKey = "syncLastCompletedAt"
    static let lastSyncCountKey = "syncLastSyncCount"
    static let lastSyncDownloadedKey = "syncLastSyncDownloaded"
    static let lastSyncDeletedKey = "syncLastSyncDeleted"
    static let lastErrorKey = "syncLastError"
    static let autoPausedKey = "syncAutoPaused"
    static let selectedPeerIDsKey = "syncSelectedPeerClientIDs"
    static let peerLastPullAtKey = "syncPeerLastPullAtByClient"
    static let peerLastTrashSyncAtKey = "syncPeerLastTrashSyncAtByClient"

    static let defaultBatchSize = 20
    static let defaultServerURL = "http://127.0.0.1:8787"
    static let minBatchSize = 1
    static let maxBatchSize = 500
    static let defaultIntervalMinutes = 5
    static let minIntervalMinutes = 1
    static let maxIntervalMinutes = 10_080
    static let binaryFieldCap = 10 * 1024 * 1024
    /// Keep each HTTP request below the server body limit (see sync-server handleSync).
    static let maxRequestBodyBytes = 48 * 1024 * 1024

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var isAutoPaused: Bool {
        UserDefaults.standard.bool(forKey: autoPausedKey)
    }

    static var lastCompletedAt: Date? {
        UserDefaults.standard.object(forKey: lastCompletedAtKey) as? Date
    }

    static var batchSize: Int {
        let raw = UserDefaults.standard.integer(forKey: batchSizeKey)
        if raw <= 0 { return defaultBatchSize }
        return min(max(raw, minBatchSize), maxBatchSize)
    }

    static func clampIntervalMinutes(_ value: Int) -> Int {
        min(max(value, minIntervalMinutes), maxIntervalMinutes)
    }

    static var intervalMinutes: Int {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: intervalMinutesKey) != nil {
            let raw = defaults.integer(forKey: intervalMinutesKey)
            if raw > 0 { return clampIntervalMinutes(raw) }
        }
        if defaults.object(forKey: intervalSecondsKey) != nil {
            let raw = defaults.integer(forKey: intervalSecondsKey)
            if raw > 0 {
                let minutes = clampIntervalMinutes(max(1, raw / 60))
                defaults.set(minutes, forKey: intervalMinutesKey)
                return minutes
            }
        }
        let legacyHours = defaults.integer(forKey: intervalHoursKey)
        if legacyHours > 0 {
            let minutes = clampIntervalMinutes(legacyHours * 60)
            defaults.set(minutes, forKey: intervalMinutesKey)
            return minutes
        }
        return defaultIntervalMinutes
    }

    static var interval: TimeInterval {
        TimeInterval(intervalMinutes * 60)
    }

    static func ensureClientID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: clientIDKey), !existing.isEmpty {
            return existing
        }
        let id = KSUID.generate()
        defaults.set(id, forKey: clientIDKey)
        return id
    }

    /// Generate a new client ID and persist it. Existing sync history under the
    /// old ID will not be migrated; the server will treat this Mac as a new device.
    @discardableResult
    static func regenerateClientID() -> String {
        let id = KSUID.generate()
        UserDefaults.standard.set(id, forKey: clientIDKey)
        return id
    }

    static func normalizedServerURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var value = trimmed
        if !value.contains("://") {
            value = "http://\(value)"
        }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.string
    }

    static func syncEndpoint(from baseURL: String) -> URL? {
        guard let base = normalizedServerURL(baseURL) else { return nil }
        return URL(string: base + "/api/v1/sync")
    }

    static func clientsEndpoint(from baseURL: String) -> URL? {
        guard let base = normalizedServerURL(baseURL) else { return nil }
        return URL(string: base + "/api/v1/clients")
    }

    static func pullEndpoint(from baseURL: String) -> URL? {
        guard let base = normalizedServerURL(baseURL) else { return nil }
        return URL(string: base + "/api/v1/pull")
    }

    static func trashEndpoint(from baseURL: String) -> URL? {
        guard let base = normalizedServerURL(baseURL) else { return nil }
        return URL(string: base + "/api/v1/trash")
    }

    static func purgeClientItemsEndpoint(from baseURL: String, clientID: String) -> URL? {
        guard let base = normalizedServerURL(baseURL),
              let encoded = clientID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: base + "/api/v1/clients/\(encoded)/items")
    }

    static var selectedPeerIDs: Set<String> {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: selectedPeerIDsKey) ?? []
            return Set(raw)
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: selectedPeerIDsKey)
        }
    }

    static func lastPullAt(peerID: String) -> Date? {
        guard let map = UserDefaults.standard.dictionary(forKey: peerLastPullAtKey) as? [String: Double] else {
            return nil
        }
        guard let ts = map[peerID] else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    static func setLastPullAt(peerID: String, date: Date) {
        var map = (UserDefaults.standard.dictionary(forKey: peerLastPullAtKey) as? [String: Double]) ?? [:]
        map[peerID] = date.timeIntervalSince1970
        UserDefaults.standard.set(map, forKey: peerLastPullAtKey)
    }

    static func lastTrashSyncAt(clientID: String) -> Date? {
        guard let map = UserDefaults.standard.dictionary(forKey: peerLastTrashSyncAtKey) as? [String: Double] else {
            return nil
        }
        guard let ts = map[clientID] else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    static func setLastTrashSyncAt(clientID: String, date: Date) {
        var map = (UserDefaults.standard.dictionary(forKey: peerLastTrashSyncAtKey) as? [String: Double]) ?? [:]
        map[clientID] = date.timeIntervalSince1970
        UserDefaults.standard.set(map, forKey: peerLastTrashSyncAtKey)
    }

    static func clientIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    static func pruneSelectedPeers(matching clientID: String) {
        let pruned = selectedPeerIDs.filter { !clientIDsMatch($0, clientID) }
        if pruned.count != selectedPeerIDs.count {
            selectedPeerIDs = pruned
        }
    }
}

enum SyncBatchSizeOption: Int, CaseIterable, Identifiable {
    case ten = 10
    case twenty = 20
    case fifty = 50
    case hundred = 100
    case twoHundred = 200
    case fiveHundred = 500

    var id: Int { rawValue }

    var label: String { "\(rawValue)" }
}
