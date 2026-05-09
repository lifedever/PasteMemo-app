---
name: {{SERVER_KEY}}
description: |
  Use when user references something they recently copied, pasted, or had on their
  clipboard — explicitly OR implicitly. Trigger on:

  - Implicit references in any language: "the thing I just copied" / "我刚才复制的" /
    "上次复制的那段" / "earlier I copied" / "the JSON from before" / "that error
    message" / "那个链接" / "私がコピーしたもの" / "방금 복사한" /
    "ce que je viens de copier" / "was ich kopiert habe" / "lo que copié" /
    "quello che ho copiato" / "то что я скопировал" / "yang saya salin tadi"

  - Explicit PasteMemo invocations: "从 PasteMemo 找..." / "用 PasteMemo 查..." /
    "PasteMemo 里那个..." / "search PasteMemo for..." / "look in my PasteMemo
    history" / "check PasteMemo" / "PasteMemo の履歴から" / "PasteMemo에서 찾아줘"

  - Slash command: user typed `/{{SERVER_KEY}} ...` — treat the rest of the message
    as the clipboard-related need, then operate via the MCP tools below.

  - Writing to clipboard: "put this on my clipboard" / "复制这个" / "帮我复制"

  - Asking what's currently copied: "what's on my clipboard" / "我现在剪贴板里有啥"
---

# PasteMemo 剪贴板桥

无论用户是隐式引用剪贴板（"我刚才复制的那段..."）、显式调用（"从 PasteMemo 里
找..."），还是用 `/{{SERVER_KEY}} <需求>` 强制触发，统一使用 PasteMemo MCP server
提供的工具完成需求。

工具的完整列表、参数、返回结构、翻页策略、隐私规则、反模式等细节，由 PasteMemo
MCP server 在会话启动时通过 `initialize` 响应的 `instructions` 字段自动下发到
system prompt（你的上下文里会出现 `## {{SERVER_KEY}}` 段落）——**以那份内容为准**。

如果会话里看不到那段 server instructions，多半是 PasteMemo 没在运行 / MCP socket
没连上：如实告诉用户，不要凭印象瞎编工具用法。
