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

    static func testConnection(serverURL: String, username: String, password: String) async -> Bool {
        let dest = WebDAVBackupDestination(
            serverURL: serverURL,
            username: username,
            password: password,
            remotePath: ""
        )
        return await dest.isAvailable
    }

    // MARK: - Private

    private func buildURL(_ fileName: String) -> URL? {
        var base = serverURL
        if !remotePath.isEmpty {
            if !base.hasSuffix("/") { base += "/" }
            let path = remotePath.hasPrefix("/") ? String(remotePath.dropFirst()) : remotePath
            base += path
        }
        if !fileName.isEmpty {
            if !base.hasSuffix("/") { base += "/" }
            base += fileName
        }
        guard let encoded = base.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "%3A", with: ":")
            .replacingOccurrences(of: "%2F", with: "/")
        else { return URL(string: base) }
        return URL(string: encoded)
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
