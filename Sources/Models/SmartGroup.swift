import Foundation
import SwiftData

@Model
final class SmartGroup {
    var name: String = ""
    var icon: String = "folder"
    var count: Int = 0
    var sortOrder: Int = 0
    var color: String?

    init(name: String, icon: String = "folder", sortOrder: Int = 0, color: String? = nil) {
        self.name = name
        self.icon = icon
        self.sortOrder = sortOrder
        self.color = color
    }

    static let availableIcons: [String] = [
        // 文件与容器
        "folder", "folder.fill", "tray", "tray.full",
        "archivebox", "doc", "doc.text", "note.text",
        // 标记与收藏
        "bookmark", "tag", "star", "heart",
        "flag", "pin", "rosette", "seal",
        // 工作与生活
        "briefcase", "house", "building.2", "storefront",
        "graduationcap", "person", "person.2", "figure.walk",
        // 网络与通信
        "globe", "link", "envelope", "phone",
        "bubble.left", "antenna.radiowaves.left.and.right", "wifi", "network",
        // 创意与媒体
        "camera", "photo", "music.note", "film",
        "paintbrush", "pencil", "highlighter", "theatermasks",
        // 工具与设置
        "wrench", "gear", "hammer", "slider.horizontal.3",
        "terminal", "chevron.left.forwardslash.chevron.right", "cpu", "memorychip",
        // 自然与天气
        "leaf", "flame", "drop", "bolt",
        "sun.max", "moon", "cloud", "snowflake",
        // 购物与财务
        "cart", "creditcard", "gift", "bag",
        "dollarsign.circle", "banknote", "chart.bar", "chart.pie",
        // 交通与旅行
        "airplane", "car", "bicycle", "map",
        "location", "compass.drawing", "binoculars", "suitcase",
        // 娱乐与运动
        "gamecontroller", "sportscourt", "trophy", "medal",
        "puzzlepiece", "dice", "headphones", "guitars",
        // 健康与安全
        "heart.text.square", "cross.case", "shield", "lock",
        "key", "hand.raised", "eye", "faceid",
        // 食物与饮品
        "cup.and.saucer", "fork.knife", "birthday.cake", "wineglass",
    ]
}
