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

    static func isImageURL(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:image/") { return true }
        guard let url = URL(string: trimmed) else { return false }
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    func fetchMetadata(urlString: String) async -> LinkMetadata {
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
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            // Anti-bot filters (baidu, many CDN WAFs) reject barebones UAs and
            // serve an empty or interstitial body. Use a current Safari string
            // so we receive the real HTML and can extract <title>.
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            let (data, _) = try await URLSession.shared.data(for: request)
            let sliced = data.prefix(50000)
            if let html = String(data: sliced, encoding: .utf8), let title = extractTitle(from: html) {
                return title
            }
            // Fall back to GBK / GB18030 for legacy sites like baidu.com that
            // still serve in that encoding when UA is not explicitly mobile.
            let gbkEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            if let html = String(data: sliced, encoding: String.Encoding(rawValue: gbkEncoding)) {
                return extractTitle(from: html)
            }
            return nil
        } catch {
            return nil
        }
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
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      data.count > 100 else { continue }
                // Validate it's an image
                if NSImage(data: data) != nil { return data }
            } catch {
                continue
            }
        }
        return nil
    }
}
