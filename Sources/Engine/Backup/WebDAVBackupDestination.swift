import Foundation

struct WebDAVBackupDestination: BackupDestination {

    let serverURL: String
    let username: String
    let password: String
    let remotePath: String

    var displayName: String { "WebDAV" }

    var isAvailable: Bool {
        get async {
            guard let url = buildURL("") else { return false }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "OPTIONS"
            applyAuth(&request)
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        }
    }

    func upload(data: Data, fileName: String) async throws {
        guard let url = buildURL(fileName) else {
            throw BackupError.backupFailed("Invalid WebDAV URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BackupError.backupFailed("Upload failed with status \(code)")
        }
    }

    func download(fileName: String) async throws -> Data {
        guard let url = buildURL(fileName) else {
            throw BackupError.restoreFailed("Invalid WebDAV URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw BackupError.restoreFailed("Download failed with status \(code)")
        }
        return data
    }

    func list() async throws -> [BackupMetadata] {
        guard let url = buildURL("") else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)

        let propfindBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
            <D:prop>
                <D:getcontentlength/>
                <D:getlastmodified/>
                <D:displayname/>
            </D:prop>
        </D:propfind>
        """
        request.httpBody = Data(propfindBody.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) || http.statusCode == 207 else {
            return []
        }

        return parseWebDAVResponse(data)
    }

    func delete(fileName: String) async throws {
        guard let url = buildURL(fileName) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(&request)

        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) || code == 404 else {
            throw BackupError.backupFailed("Delete failed with status \(code)")
        }
    }

    // MARK: - Scheme Resolution

    enum SchemeResolution {
        /// Full URL with a confirmed scheme. `insecure` means plain HTTP.
        case resolved(url: String, statusCode: Int, insecure: Bool)
        /// The server answered TLS but its certificate is invalid — do NOT
        /// fall back to HTTP: that would silently send credentials in
        /// plain text to a server that does support TLS.
        case certificateError(String)
        case unreachable(String)
        case invalidURL
    }

    /// Resolves a user-entered server address into a full http(s) URL.
    /// Addresses without a scheme are probed with HTTPS first, then HTTP.
    /// A bare "host:port" string parses as scheme="host" in Foundation
    /// (RFC 3986 allows dots in schemes), so URLSession would otherwise
    /// fail with the cryptic NSURLErrorUnsupportedURL.
    static func resolveServerURL(_ input: String, username: String, password: String) async -> SchemeResolution {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidURL }

        if trimmed.contains("://") {
            let lower = trimmed.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
                return .invalidURL
            }
            switch await probe(trimmed, username: username, password: password) {
            case .reachable(let status):
                return .resolved(url: trimmed, statusCode: status, insecure: lower.hasPrefix("http://"))
            case .certificate(let msg):
                return .certificateError(msg)
            case .failed(let msg):
                return .unreachable(msg)
            case .invalid:
                return .invalidURL
            }
        }

        switch await probe("https://" + trimmed, username: username, password: password) {
        case .reachable(let status):
            return .resolved(url: "https://" + trimmed, statusCode: status, insecure: false)
        case .certificate(let msg):
            return .certificateError(msg)
        case .invalid:
            return .invalidURL
        case .failed:
            switch await probe("http://" + trimmed, username: username, password: password) {
            case .reachable(let status):
                return .resolved(url: "http://" + trimmed, statusCode: status, insecure: true)
            case .certificate(let msg):
                return .certificateError(msg)
            case .failed(let msg):
                return .unreachable(msg)
            case .invalid:
                return .invalidURL
            }
        }
    }

    private enum ProbeOutcome {
        case reachable(Int)
        case certificate(String)
        case failed(String)
        case invalid
    }

    /// Any HTTP response (even 401/404) proves the scheme works at the
    /// transport level; the status code is passed through so callers can
    /// distinguish auth problems from reachability.
    private static func probe(_ urlString: String, username: String, password: String) async -> ProbeOutcome {
        guard let url = encodeURL(urlString) else { return .invalid }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "OPTIONS"
        let credentials = "\(username):\(password)"
        if let data = credentials.data(using: .utf8) {
            request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(URLError(.badServerResponse).localizedDescription)
            }
            return .reachable(http.statusCode)
        } catch let error as URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return .certificate(error.localizedDescription)
            default:
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Percent-encodes a raw URL string the same way for probing and for
    /// actual requests, and requires a host to be present.
    private static func encodeURL(_ raw: String) -> URL? {
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "%3A", with: ":")
            .replacingOccurrences(of: "%2F", with: "/")
        guard let url = URL(string: encoded ?? raw), url.host != nil else { return nil }
        return url
    }

    // MARK: - Private

    private func buildURL(_ fileName: String) -> URL? {
        var base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        // Scheme-less input normally gets resolved (and persisted) by the
        // test-connection flow or BackupScheduler before reaching here;
        // default to HTTPS as a safe fallback.
        if !base.contains("://") { base = "https://" + base }
        let lower = base.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        if !remotePath.isEmpty {
            if !base.hasSuffix("/") { base += "/" }
            let path = remotePath.hasPrefix("/") ? String(remotePath.dropFirst()) : remotePath
            base += path
        }
        if !fileName.isEmpty {
            if !base.hasSuffix("/") { base += "/" }
            base += fileName
        }
        return Self.encodeURL(base)
    }

    private func applyAuth(_ request: inout URLRequest) {
        let credentials = "\(username):\(password)"
        guard let data = credentials.data(using: .utf8) else { return }
        request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
    }

    private func parseWebDAVResponse(_ data: Data) -> [BackupMetadata] {
        let parser = WebDAVResponseParser(data: data)
        return parser.parse()
    }
}

// MARK: - WebDAV XML Parser

private final class WebDAVResponseParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var results: [BackupMetadata] = []
    private var currentElement = ""
    private var currentHref = ""
    private var currentLength: Int64 = 0
    private var isInResponse = false

    init(data: Data) {
        self.data = data
    }

    func parse() -> [BackupMetadata] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return results
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let local = element.components(separatedBy: ":").last ?? element
        currentElement = local
        if local == "response" { isInResponse = true; currentHref = ""; currentLength = 0 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch currentElement.components(separatedBy: ":").last ?? currentElement {
        case "href": currentHref += trimmed
        case "getcontentlength": currentLength = Int64(trimmed) ?? 0
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        let local = element.components(separatedBy: ":").last ?? element
        guard local == "response", isInResponse else { return }
        isInResponse = false

        let fileName = currentHref.components(separatedBy: "/").last ?? ""
        guard fileName.hasSuffix(".pastememo"),
              let parsed = BackupFileNameParser.parse(fileName) else { return }

        results.append(BackupMetadata(
            fileName: fileName,
            slot: parsed.slot,
            createdAt: parsed.date,
            itemCount: parsed.itemCount,
            fileSize: currentLength
        ))
    }
}
