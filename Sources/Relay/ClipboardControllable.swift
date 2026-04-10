import Foundation

@MainActor
protocol ClipboardControllable: AnyObject {
    var isMonitoringPaused: Bool { get }
    func pauseMonitoring()
    func resumeMonitoring()
}
