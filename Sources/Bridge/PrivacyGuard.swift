import Foundation

/// 出口过滤层 — 所有 MCP 读工具的响应必须经过 filter()。
struct PrivacyGuard {
    let allowSensitive: Bool
    let sourceAppBlocklist: Set<String>

    func filter(_ items: [ClipItem]) -> [ClipItem] {
        items.filter { item in
            if !allowSensitive && item.isSensitive { return false }
            if let bid = item.sourceAppBundleID, sourceAppBlocklist.contains(bid) { return false }
            return true
        }
    }

    /// 把 content 裁剪到 ≤ 200 字符。也用于 search 工具响应。
    static func truncatePreview(_ s: String, maxLength: Int = 200) -> String {
        if s.count <= maxLength { return s }
        return String(s.prefix(maxLength))
    }
}
