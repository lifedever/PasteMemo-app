import Foundation
import SwiftUI

private let IGNORED_APPS_KEY = "ignoredApps"
private let IGNORED_APPS_NAMES_KEY = "ignoredAppsNames"

@Observable
@MainActor
final class IgnoredAppsManager {
    static let shared = IgnoredAppsManager()

    private(set) var ignoredBundleIDs: Set<String> = []
    private(set) var appNames: [String: String] = [:]

    var ignoredApps: [(bundleID: String, name: String)] {
        ignoredBundleIDs.map { id in
            (bundleID: id, name: appNames[id] ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private init() {
        loadFromDefaults()
    }

    func addApp(bundleID: String, name: String) {
        ignoredBundleIDs.insert(bundleID)
        appNames[bundleID] = name
        saveToDefaults()
    }

    func removeApp(bundleID: String) {
        ignoredBundleIDs.remove(bundleID)
        appNames.removeValue(forKey: bundleID)
        saveToDefaults()
    }

    func isIgnored(_ bundleID: String) -> Bool {
        ignoredBundleIDs.contains(bundleID)
    }

    private func loadFromDefaults() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: IGNORED_APPS_KEY),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            ignoredBundleIDs = ids
        }
        if let data = defaults.data(forKey: IGNORED_APPS_NAMES_KEY),
           let names = try? JSONDecoder().decode([String: String].self, from: data) {
            appNames = names
        }
    }

    private func saveToDefaults() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(ignoredBundleIDs) {
            defaults.set(data, forKey: IGNORED_APPS_KEY)
        }
        if let data = try? JSONEncoder().encode(appNames) {
            defaults.set(data, forKey: IGNORED_APPS_NAMES_KEY)
        }
    }
}
