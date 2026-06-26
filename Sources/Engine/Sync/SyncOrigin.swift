import Foundation

enum SyncOrigin {
    @MainActor
    static func stampLocal(on clip: ClipItem) {
        clip.originClientID = SyncSettings.ensureClientID()
        clip.originHostname = localHostname()
        clip.originIP = localIPAddress() ?? ""
    }

    static func localHostname() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            if name == "lo0" { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            let ip = String(decoding: hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !ip.isEmpty { return ip }
        }
        return nil
    }

    static func isLocalOrigin(originClientID: String?, localClientID: String) -> Bool {
        guard let originClientID, !originClientID.isEmpty else { return true }
        return SyncSettings.clientIDsMatch(originClientID, localClientID)
    }
}
