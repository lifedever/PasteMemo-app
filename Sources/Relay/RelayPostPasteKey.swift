import CoreGraphics
import Foundation

enum RelayPostPasteKey: String, CaseIterable {
    case none
    case `return`
    case tab
    case down
    case space

    static let userDefaultsKey = "relayPostPasteKey"

    var keyCode: CGKeyCode? {
        switch self {
        case .none: return nil
        case .return: return 0x24
        case .tab: return 0x30
        case .down: return 0x7D
        case .space: return 0x31
        }
    }

    static var current: RelayPostPasteKey {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? Self.none.rawValue
        return RelayPostPasteKey(rawValue: raw) ?? .none
    }
}
