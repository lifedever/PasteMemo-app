import Foundation

@MainActor
protocol ClipboardControllable: AnyObject {
    var isMonitoringPaused: Bool { get }
    func pauseMonitoring()
    func resumeMonitoring()
    func pauseMonitoring(persistent: Bool)
    func resumeMonitoring(persistent: Bool)
}
