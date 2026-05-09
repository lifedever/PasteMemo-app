import Foundation
import SwiftUI

private let MCP_BLOCKLIST_IDS_KEY = "mcpSourceAppBlocklist"
private let MCP_BLOCKLIST_NAMES_KEY = "mcpSourceAppBlocklistNames"

/// MCP 专属源 App 黑名单 — 与 IgnoredAppsManager 语义不同：
/// - IgnoredAppsManager: 不录入剪贴板（PasteMemo 自己也看不到）
/// - 本类:                录了但 Agent 看不到（PasteMemo 仍可用）
@Observable
@MainActor
final class MCPSourceAppBlocklist {
    static let shared = MCPSourceAppBlocklist()

    private(set) var blockedBundleIDs: Set<String> = []
    private(set) var appNames: [String: String] = [:]

    var blockedApps: [(bundleID: String, name: String)] {
        blockedBundleIDs.map { id in
            (bundleID: id, name: appNames[id] ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    init() {
        loadFromDefaults()
    }

    func add(bundleID: String, name: String) {
        blockedBundleIDs.insert(bundleID)
        appNames[bundleID] = name
        saveToDefaults()
    }

    func remove(bundleID: String) {
        blockedBundleIDs.remove(bundleID)
        appNames.removeValue(forKey: bundleID)
        saveToDefaults()
    }

    func isBlocked(_ bundleID: String) -> Bool {
        blockedBundleIDs.contains(bundleID)
    }

    private func loadFromDefaults() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: MCP_BLOCKLIST_IDS_KEY),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            blockedBundleIDs = ids
        }
        if let data = defaults.data(forKey: MCP_BLOCKLIST_NAMES_KEY),
           let names = try? JSONDecoder().decode([String: String].self, from: data) {
            appNames = names
        }
    }

    private func saveToDefaults() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(blockedBundleIDs) {
            defaults.set(data, forKey: MCP_BLOCKLIST_IDS_KEY)
        }
        if let data = try? JSONEncoder().encode(appNames) {
            defaults.set(data, forKey: MCP_BLOCKLIST_NAMES_KEY)
        }
    }
}
