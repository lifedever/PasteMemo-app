import Foundation
import AppKit

actor LinkMetadataFetcher {
    static let shared = LinkMetadataFetcher()

    private var inFlightURLs: Set<String> = []

    struct LinkMetadata: Sendable {
        let title: String?
        let faviconData: Data?
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

    private func fetchTitle(url: URL) async -> String? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data.prefix(50000), encoding: .utf8) else { return nil }
            return extractTitle(from: html)
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
