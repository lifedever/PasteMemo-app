import Foundation
import Combine
import SwiftData

@MainActor
@Observable
final class SnippetStore {
    private(set) var items: [SnippetItem] = []
    private(set) var totalCount = 0

    static let sortModeKey = "snippetSortMode"

    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            reload()
        }
    }

    var sortMode: HistorySortMode = {
        let raw = UserDefaults.standard.string(forKey: SnippetStore.sortModeKey) ?? HistorySortMode.lastUsed.rawValue
        return HistorySortMode(rawValue: raw) ?? .lastUsed
    }() {
        didSet {
            guard sortMode != oldValue else { return }
            UserDefaults.standard.set(sortMode.rawValue, forKey: Self.sortModeKey)
            reload()
        }
    }

    private var modelContext: ModelContext?
    private var observer: AnyCancellable?

    func configure(modelContext: ModelContext) {
        let isFirstTime = self.modelContext == nil
        self.modelContext = modelContext
        if isFirstTime {
            observer = NotificationCenter.default.publisher(for: .snippetDidUpdate)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.reload()
                }
        }
        reload()
    }

    func reload() {
        guard let modelContext else { return }

        let descriptor = FetchDescriptor<SnippetItem>()
        let fetched = (try? modelContext.fetch(descriptor)) ?? []

        let sorted = fetched.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }

            switch sortMode {
            case .created:
                return lhs.createdAt > rhs.createdAt
            case .lastUsed:
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedSearch.isEmpty {
            items = sorted
        } else {
            let terms = trimmedSearch
                .split(whereSeparator: \ .isWhitespace)
                .map(String.init)
            items = sorted.filter { matches($0, terms: terms) }
        }

        totalCount = items.count
    }

    func removeItem(id: PersistentIdentifier) {
        items.removeAll { $0.persistentModelID == id }
        totalCount = items.count
    }

    private func matches(_ snippet: SnippetItem, terms: [String]) -> Bool {
        let haystack = [snippet.resolvedTitle, snippet.content, snippet.groupName ?? ""] + snippet.tags
        return terms.allSatisfy { term in
            haystack.contains(where: { $0.localizedCaseInsensitiveContains(term) })
        }
    }
}
