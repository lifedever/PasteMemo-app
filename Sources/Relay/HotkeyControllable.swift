import Foundation

@MainActor
protocol HotkeyControllable: AnyObject {
    func disableHotkey()
    func enableHotkey()
}
