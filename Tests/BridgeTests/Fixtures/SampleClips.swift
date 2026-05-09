import Foundation
import SwiftData
@testable import PasteMemo

@MainActor
enum SampleClips {
    /// 创建 in-memory ModelContainer 用于测试
    static func makeContainer() -> ModelContainer {
        let schema = Schema([ClipItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: config)
    }

    /// 通用 5 条样本，覆盖 sensitive / source app 等场景
    static func seed(in context: ModelContext) -> [ClipItem] {
        let now = Date()
        let items: [ClipItem] = [
            // 0: 普通文本
            {
                let i = ClipItem(content: "Hello world", contentType: .text,
                                 sourceApp: "Xcode", sourceAppBundleID: "com.apple.dt.Xcode",
                                 createdAt: now)
                return i
            }(),
            // 1: 敏感项（密码）
            {
                let i = ClipItem(content: "P@ssw0rd_Sec3et!", contentType: .text,
                                 sourceApp: "1Password", sourceAppBundleID: "com.1password.1password",
                                 createdAt: now.addingTimeInterval(-60))
                i.isSensitive = true
                return i
            }(),
            // 2: 黑名单源 App（假定 com.evil.app 在黑名单中）
            {
                let i = ClipItem(content: "from blocklisted app", contentType: .text,
                                 sourceApp: "EvilApp", sourceAppBundleID: "com.evil.app",
                                 createdAt: now.addingTimeInterval(-120))
                return i
            }(),
            // 3: 长文本（验证 preview 截断）
            {
                let long = String(repeating: "A", count: 500)
                let i = ClipItem(content: long, contentType: .text,
                                 sourceApp: "Notes", sourceAppBundleID: "com.apple.Notes",
                                 createdAt: now.addingTimeInterval(-180))
                return i
            }(),
            // 4: 图片 + OCR
            {
                let i = ClipItem(content: "[Image]", contentType: .image,
                                 imageData: Data([0x89, 0x50, 0x4E, 0x47]),
                                 sourceApp: "Preview", sourceAppBundleID: "com.apple.Preview",
                                 createdAt: now.addingTimeInterval(-240))
                i.ocrText = "extracted text"
                return i
            }(),
        ]
        for item in items { context.insert(item) }
        try? context.save()
        return items
    }
}
