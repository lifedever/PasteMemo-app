import Foundation
import AppKit

actor LinkMetadataFetcher {
    static let shared = LinkMetadataFetcher()

    private var inFlightURLs: Set<String> = []

    struct LinkMetadata: Sendable {
        let title: String?
        let faviconData: Data?
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "heif", "svg", "ico", "tiff", "tif"
    ]

    // Caps below ensure preview metadata fetches never balloon into full-file
    // downloads when users copy direct binary links (dmg/zip/PDF/large image)
    // — see issue #46.
    private static let titleByteLimit = 50_000        // body bytes parsed for <title>
    private static let titleResponseCap = 5_000_000   // reject HTML > 5MB at HEAD
    private static let faviconByteLimit = 200_000     // favicon hard cap

    static func isImageURL(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:image/") { return true }
        guard let url = URL(string: trimmed) else { return false }
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    func fetchMetadata(urlString: String) async -> LinkMetadata {
        // Defence in depth: callers already gate on offline mode, but enforcing
        // it inside the actor means a future call site won't accidentally
        // sneak past the master switch.
        if UserDefaults.standard.bool(forKey: "offlineModeEnabled") {
            return LinkMetadata(title: nil, faviconData: nil)
        }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let host = url.host,
              !inFlightURLs.contains(trimmed) else {
            return LinkMetadata(title: nil, faviconData: nil)
        }

        inFlightURLs.insert(trimmed)
        defer { inFlightURLs.remove(trimmed) }

        async let titleResult = fetchTitle(url: url)
        async let faviconResult = fetchFavicon(host: host)

        return LinkMetadata(title: await titleResult, faviconData: await faviconResult)
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private func fetchTitle(url: URL) async -> String? {
        // 1. HEAD probe — reject non-HTML and oversized HTML before any body
        //    bytes hit the wire. This is the primary guard against accidental
        //    full-file downloads when users copy direct binary links.
        if let probe = await headProbe(url: url) {
            switch probe {
            case .reject:
                return nil
            case .pass, .unknown:
                break
            }
        }

        // 2. Stream the body with Range hint and a hard byte ceiling. Even if
        //    HEAD said HTML or returned 405/unsupported, we double-check the
        //    response Content-Type before reading bytes, and cancel the task
        //    the instant we exceed `titleByteLimit`.
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            // Anti-bot filters (baidu, many CDN WAFs) reject barebones UAs and
            // serve an empty or interstitial body. Use a current Safari string
            // so we receive the real HTML and can extract <title>.
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            request.setValue("bytes=0-\(Self.titleByteLimit - 1)", forHTTPHeaderField: "Range")

            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

            guard let http = response as? HTTPURLResponse else {
                asyncBytes.task.cancel()
                return nil
            }

            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard Self.isHTMLContentType(ct) else {
                asyncBytes.task.cancel()
                return nil
            }

            var buffer = Data()
            buffer.reserveCapacity(Self.titleByteLimit)
            for try await byte in asyncBytes {
                buffer.append(byte)
                if buffer.count >= Self.titleByteLimit {
                    asyncBytes.task.cancel()
                    break
                }
            }

            return decodeTitle(from: buffer)
        } catch {
            return nil
        }
    }

    private enum HeadProbeResult {
        case pass            // HEAD returned HTML within size cap
        case reject          // HEAD returned non-HTML or oversized — abort
        case unknown         // HEAD failed/405/501 — fall through to GET guard
    }

    private func headProbe(url: URL) async -> HeadProbeResult? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .unknown
        }

        // Some servers reject HEAD outright. The streaming GET will guard us.
        if http.statusCode == 405 || http.statusCode == 501 {
            return .unknown
        }

        let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard Self.isHTMLContentType(ct) else {
            return .reject
        }

        if let lengthStr = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(lengthStr), length > Self.titleResponseCap {
            return .reject
        }

        return .pass
    }

    private static func isHTMLContentType(_ ct: String) -> Bool {
        ct.contains("text/html") ||
            ct.contains("application/xhtml") ||
            ct.contains("application/xml")
    }

    private func decodeTitle(from data: Data) -> String? {
        if let html = String(data: data, encoding: .utf8), let title = extractTitle(from: html) {
            return title
        }
        // Fall back to GBK / GB18030 for legacy sites like baidu.com that
        // still serve in that encoding when UA is not explicitly mobile.
        let gbkEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let html = String(data: data, encoding: String.Encoding(rawValue: gbkEncoding)) {
            return extractTitle(from: html)
        }
        return nil
    }

    private func extractTitle(from html: String) -> String? {
        guard let startRange = html.range(of: "<title", options: .caseInsensitive),
              let tagClose = html.range(of: ">", range: startRange.upperBound..<html.endIndex),
              let endRange = html.range(of: "</title>", options: .caseInsensitive, range: tagClose.upperBound..<html.endIndex)
        else { return nil }

        let title = String(html[tagClose.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")

        return title.isEmpty ? nil : String(title.prefix(200))
    }

    private func fetchFavicon(host: String) async -> Data? {
        let candidates = [
            "https://\(host)/favicon.ico",
            "https://www.google.com/s2/favicons?domain=\(host)&sz=64",
        ]

        for urlString in candidates {
            guard let url = URL(string: urlString) else { continue }
            if let data = await fetchFaviconCandidate(url: url) {
                return data
            }
        }
        return nil
    }

    private func fetchFaviconCandidate(url: URL) async -> Data? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3

            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                asyncBytes.task.cancel()
                return nil
            }

            // Servers occasionally return an HTML "404"-style page on favicon
            // misses with 200 OK; require an image MIME so we don't ingest
            // arbitrary HTML/JS as `faviconData`.
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard ct.hasPrefix("image/") else {
                asyncBytes.task.cancel()
                return nil
            }

            if let lengthStr = http.value(forHTTPHeaderField: "Content-Length"),
               let length = Int(lengthStr), length > Self.faviconByteLimit {
                asyncBytes.task.cancel()
                return nil
            }

            var buffer = Data()
            buffer.reserveCapacity(Self.faviconByteLimit)
            for try await byte in asyncBytes {
                buffer.append(byte)
                if buffer.count >= Self.faviconByteLimit {
                    asyncBytes.task.cancel()
                    return nil
                }
            }

            guard buffer.count > 100, NSImage(data: buffer) != nil else { return nil }
            return buffer
        } catch {
            return nil
        }
    }
}
