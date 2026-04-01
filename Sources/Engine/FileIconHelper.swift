import SwiftUI

struct FileIconInfo {
    let symbol: String
    let color: Color
}

func fileIconInfo(_ path: String) -> FileIconInfo {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        return FileIconInfo(symbol: "folder.fill", color: .cyan)
    }

    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()

    switch ext {
    // Images
    case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico":
        return FileIconInfo(symbol: "photo.fill", color: .green)
    case "svg":
        return FileIconInfo(symbol: "square.on.square", color: .green)
    case "psd":
        return FileIconInfo(symbol: "paintbrush.fill", color: .blue)
    case "sketch", "fig":
        return FileIconInfo(symbol: "pencil.and.ruler.fill", color: .orange)

    // Videos
    case "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "3gp":
        return FileIconInfo(symbol: "play.rectangle.fill", color: .purple)

    // Audio
    case "mp3", "wav", "aac", "flac", "m4a", "ogg", "wma", "aiff", "alac", "opus":
        return FileIconInfo(symbol: "music.note", color: .pink)

    // PDF
    case "pdf":
        return FileIconInfo(symbol: "doc.richtext.fill", color: .red)

    // Word
    case "doc", "docx":
        return FileIconInfo(symbol: "doc.fill", color: .blue)
    case "rtf", "rtfd":
        return FileIconInfo(symbol: "doc.fill", color: .blue)
    case "pages":
        return FileIconInfo(symbol: "doc.fill", color: .orange)

    // Text / Markdown
    case "txt":
        return FileIconInfo(symbol: "doc.text.fill", color: .gray)
    case "md", "markdown":
        return FileIconInfo(symbol: "doc.text.fill", color: .indigo)

    // Spreadsheets
    case "xls", "xlsx":
        return FileIconInfo(symbol: "tablecells.fill", color: .green)
    case "csv", "tsv":
        return FileIconInfo(symbol: "tablecells", color: .green)
    case "numbers":
        return FileIconInfo(symbol: "tablecells.fill", color: .green)

    // Presentations
    case "ppt", "pptx":
        return FileIconInfo(symbol: "rectangle.fill.on.rectangle.fill", color: .orange)
    case "key", "keynote":
        return FileIconInfo(symbol: "rectangle.fill.on.rectangle.fill", color: .blue)

    // Archives
    case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
        return FileIconInfo(symbol: "doc.zipper", color: .gray)

    // Disk images / installers
    case "dmg":
        return FileIconInfo(symbol: "externaldrive.fill", color: .gray)
    case "iso":
        return FileIconInfo(symbol: "externaldrive.fill", color: .gray)
    case "pkg", "mpkg":
        return FileIconInfo(symbol: "shippingbox.fill", color: .brown)
    case "deb", "rpm":
        return FileIconInfo(symbol: "shippingbox.fill", color: .brown)

    // Executables / Apps
    case "app":
        return FileIconInfo(symbol: "app.fill", color: .blue)
    case "exe", "msi":
        return FileIconInfo(symbol: "desktopcomputer", color: .blue)

    // Code
    case "swift":
        return FileIconInfo(symbol: "swift", color: .orange)
    case "py":
        return FileIconInfo(symbol: "doc.text.fill", color: .yellow)
    case "js", "ts", "jsx", "tsx":
        return FileIconInfo(symbol: "doc.text.fill", color: .yellow)
    case "java", "kt":
        return FileIconInfo(symbol: "doc.text.fill", color: .red)
    case "c", "cpp", "h", "hpp", "m", "mm":
        return FileIconInfo(symbol: "doc.text.fill", color: .blue)
    case "go":
        return FileIconInfo(symbol: "doc.text.fill", color: .cyan)
    case "rs":
        return FileIconInfo(symbol: "doc.text.fill", color: .orange)
    case "rb":
        return FileIconInfo(symbol: "doc.text.fill", color: .red)
    case "php":
        return FileIconInfo(symbol: "doc.text.fill", color: .indigo)
    case "html", "htm":
        return FileIconInfo(symbol: "globe", color: .orange)
    case "css", "scss", "less":
        return FileIconInfo(symbol: "paintbrush", color: .blue)
    case "json":
        return FileIconInfo(symbol: "curlybraces", color: .gray)
    case "xml", "plist":
        return FileIconInfo(symbol: "angle.brackets", color: .gray)

    // Config
    case "yaml", "yml", "toml", "ini", "conf", "cfg":
        return FileIconInfo(symbol: "gearshape.fill", color: .gray)
    case "env":
        return FileIconInfo(symbol: "lock.fill", color: .gray)

    // Shell / Scripts
    case "sh", "bash", "zsh", "fish":
        return FileIconInfo(symbol: "terminal.fill", color: .gray)

    // Data
    case "sql", "db", "sqlite", "sqlite3":
        return FileIconInfo(symbol: "cylinder.fill", color: .blue)

    // Fonts
    case "ttf", "otf", "woff", "woff2":
        return FileIconInfo(symbol: "textformat", color: .purple)

    // 3D / CAD
    case "obj", "stl", "fbx", "blend":
        return FileIconInfo(symbol: "cube.fill", color: .orange)

    // Default
    default:
        return FileIconInfo(symbol: "doc.fill", color: .gray)
    }
}

func fileIconForPath(_ path: String) -> String {
    fileIconInfo(path).symbol
}

/// Returns the macOS system icon for a file path (folder, app, document, etc.)
func systemIcon(forFile path: String) -> NSImage {
    NSWorkspace.shared.icon(forFile: path)
}

/// Parse hex/rgb color string to NSColor
func parseColor(_ text: String) -> NSColor? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // #RGB or #RRGGBB or #RRGGBBAA
    if t.hasPrefix("#") {
        let hex = String(t.dropFirst())
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)

        switch hex.count {
        case 3:
            let r = CGFloat((rgb >> 8) & 0xF) / 15
            let g = CGFloat((rgb >> 4) & 0xF) / 15
            let b = CGFloat(rgb & 0xF) / 15
            return NSColor(red: r, green: g, blue: b, alpha: 1)
        case 6:
            let r = CGFloat((rgb >> 16) & 0xFF) / 255
            let g = CGFloat((rgb >> 8) & 0xFF) / 255
            let b = CGFloat(rgb & 0xFF) / 255
            return NSColor(red: r, green: g, blue: b, alpha: 1)
        case 8:
            let r = CGFloat((rgb >> 24) & 0xFF) / 255
            let g = CGFloat((rgb >> 16) & 0xFF) / 255
            let b = CGFloat((rgb >> 8) & 0xFF) / 255
            let a = CGFloat(rgb & 0xFF) / 255
            return NSColor(red: r, green: g, blue: b, alpha: a)
        default: return nil
        }
    }

    // rgb(r,g,b) / rgba(r,g,b,a)
    if t.hasPrefix("rgb") {
        let nums = t.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .compactMap { Double($0) }
        guard nums.count >= 3 else { return nil }
        return NSColor(
            red: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255,
            alpha: nums.count >= 4 ? nums[3] : 1
        )
    }

    return nil
}

@MainActor private var appIconCache: [String: NSImage] = [:]
@MainActor private var appIconMissCache: Set<String> = []

/// Resolve icon by bundleID first, fallback to name. Results are cached.
@MainActor func appIcon(forBundleID bundleID: String?, name: String?) -> NSImage? {
    let cacheKey = "\(bundleID ?? "")|\(name ?? "")"
    if let cached = appIconCache[cacheKey] { return cached }
    if appIconMissCache.contains(cacheKey) { return nil }

    let icon = resolveAppIcon(bundleID: bundleID, name: name)
    if let icon {
        appIconCache[cacheKey] = icon
    } else {
        appIconMissCache.insert(cacheKey)
    }
    return icon
}

@MainActor func clearAppIconCache() {
    appIconCache.removeAll()
    appIconMissCache.removeAll()
}

private func resolveAppIcon(bundleID: String?, name: String?) -> NSImage? {
    let workspace = NSWorkspace.shared
    if let bundleID, !bundleID.isEmpty,
       let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
        return workspace.icon(forFile: url.path)
    }
    if let name, !name.isEmpty {
        let fallbackBundleID = bundleId(for: name)
        if let url = workspace.urlForApplication(withBundleIdentifier: fallbackBundleID)
            ?? findAppByName(name) {
            return workspace.icon(forFile: url.path)
        }
    }
    return nil
}

private func bundleId(for appName: String) -> String {
    let mapping: [String: String] = [
        "Finder": "com.apple.finder",
        "Safari": "com.apple.Safari",
        "Google Chrome": "com.google.Chrome",
        "Code": "com.microsoft.VSCode",
        "Terminal": "com.apple.Terminal",
    ]
    return mapping[appName] ?? ""
}

private func findAppByName(_ name: String) -> URL? {
    let fm = FileManager.default
    let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
    for dir in dirs {
        let directURL = URL(fileURLWithPath: dir).appendingPathComponent("\(name).app")
        if fm.fileExists(atPath: directURL.path) { return directURL }
    }
    // Fallback: match by localized display name (e.g. "自动操作" → "Automator.app")
    for dir in dirs {
        guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
        for item in contents where item.hasSuffix(".app") {
            let appPath = (dir as NSString).appendingPathComponent(item)
            let appURL = URL(fileURLWithPath: appPath)
            if localizedAppName(at: appURL) == name { return appURL }
        }
    }
    return NSWorkspace.shared.runningApplications
        .first { $0.localizedName == name }
        .flatMap { $0.bundleURL }
}

/// Resolve localized app name from bundle (reads CFBundleDisplayName / CFBundleName from localized InfoPlist.strings)
private func localizedAppName(at appURL: URL) -> String? {
    guard let bundle = Bundle(url: appURL) else { return nil }
    if let displayName = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String {
        return displayName
    }
    if let bundleName = bundle.localizedInfoDictionary?["CFBundleName"] as? String {
        return bundleName
    }
    return bundle.infoDictionary?["CFBundleDisplayName"] as? String
        ?? bundle.infoDictionary?["CFBundleName"] as? String
}
