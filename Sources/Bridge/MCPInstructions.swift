import Foundation

/// MCP server-level instructions returned in the `initialize` response's
/// `instructions` field (per MCP 2024-11-05 spec).
///
/// Claude Code / Cursor / Codex 等 client 在 initialize 完成后会把这段文本
/// 自动注入 system prompt，无需单独的 skill 文件。SKILL.md 只负责"何时触发"
/// （触发词 + 多语言匹配），这里负责"怎么用"（API 形态、翻页、反模式等）。
/// 因此 API 一变，只需要改这里跟着 App 一起发版，~/.claude/skills/ 那边
/// 几乎不用动。
enum MCPInstructions {
    static let text = """
PasteMemo 剪贴板桥 — AI Agent 使用说明

## 工具一览

- clipboard_get_current        —— 读取当前剪贴板（不写入历史）
- clipboard_search             —— 搜索剪贴板历史，返回 { items, total, total_capped }
- clipboard_get                —— 按 ID 取单条全量内容（含 OCR 文字、图片字节等）
- clipboard_list_recent_apps   —— 最近活跃来源 App 列表（用来反查 bundle ID）
- clipboard_set                —— 写入剪贴板（写入会被标记为 AI Agent 来源）

## 工作流

1. 用户说"那个 / 我刚才复制的..." → 优先 clipboard_get_current
2. 含糊引用 → 先 clipboard_search 拿预览 + ID
3. 需要完整内容 → clipboard_get(id)，不要把预览当全量直接用
4. 用户提到具体 App（"从微信复制的..."）→ 先 clipboard_list_recent_apps
   找到 bundle ID，再用 clipboard_search 的 source_app_bundle_id 收窄
5. 图片含文字 → clipboard_get 默认返回 ocr_text，优先用它；不要随手
   include_image_data: true（图片字节很贵）

## 找很久之前的记录

- search 默认按时间倒序，单次最多 100 条
- 往回翻：用 since + until 组成时间窗口，把 until 设为上一批最老一条的
  created_at，继续翻
- total 字段是窗口内的总匹配数（已应用所有过滤 + 隐私）
- total_capped: true 表示扫描命中安全上限（10000 条），需要把窗口再收窄

## 隐私

- server 已过滤敏感项（密码、token）和黑名单 App，不要重复过滤
- 把剪贴板内容回显给用户时，默认总结，不要大段原样引用
- clipboard_set 写入看起来像凭据的内容前必须先和用户确认

## 反模式

- 不要每条消息都"以防万一"调一次 clipboard_search
- 不要循环 clipboard_get 拉一堆 ID，挑最相关的一两条
- 图片不要默认 include_image_data: true，先看 ocr_text 够不够
"""
}
