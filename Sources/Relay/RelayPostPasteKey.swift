import CoreGraphics
import Foundation

enum RelayPostPasteKey: String, CaseIterable {
    case none
    case `return`
    case tab
    case space
    case up
    case down
    case left
    case right

    static let userDefaultsKey = "relayPostPasteKey"

    var keyCode: CGKeyCode? {
        switch self {
        case .none: return nil
        case .return: return 0x24
        case .tab: return 0x30
        case .space: return 0x31
        case .up: return 0x7E
        case .down: return 0x7D
        case .left: return 0x7B
        case .right: return 0x7C
        }
    }

    static var current: RelayPostPasteKey {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? Self.none.rawValue
        return RelayPostPasteKey(rawValue: raw) ?? .none
    }
}
