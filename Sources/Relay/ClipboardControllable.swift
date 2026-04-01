import Foundation

@MainActor
protocol ClipboardControllable: AnyObject {
    func pauseMonitoring()
    func resumeMonitoring()
}
