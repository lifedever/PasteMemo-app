import AppKit

@MainActor
@Observable
final class OptionKeyMonitor {
    static let shared = OptionKeyMonitor()
    var isOptionPressed = false
    private init() {}
}
