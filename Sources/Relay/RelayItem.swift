import Foundation

struct RelayItem: Identifiable {
    let id: UUID
    var content: String
    var state: ItemState

    enum ItemState {
        case pending, current, done, skipped
    }

    init(content: String) {
        self.id = UUID()
        self.content = content
        self.state = .pending
    }
}
