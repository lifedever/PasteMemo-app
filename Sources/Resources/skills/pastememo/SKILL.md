---
name: pastememo
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

  - Writing to clipboard: "put this on my clipboard" / "复制这个" / "帮我复制"

  - Asking what's currently copied: "what's on my clipboard" / "我现在剪贴板里有啥"

  Provides 5 MCP tools backed by PasteMemo: clipboard_get_current,
  clipboard_search, clipboard_get, clipboard_list_recent_apps, clipboard_set.
---

# PasteMemo Clipboard Bridge

You have access to the user's clipboard history through the PasteMemo MCP server.

## When to use

Trigger on **implicit references** to recently copied content, not just explicit
"search my clipboard":
- "fix the error I just copied" → `clipboard_get_current` first
- "find the JSON I copied earlier from Postman" → `clipboard_search(content_type=code, source_app_bundle_id=...)`
- "what link did I copy 10 minutes ago" → `clipboard_search(content_type=link, since=...)`
- "put this on my clipboard" → `clipboard_set`

## Workflow

1. **Vague reference** → start with `clipboard_search` (returns previews + IDs)
2. **Need full content** → call `clipboard_get(id)`. Don't dump preview into context if user wants the whole thing
3. **Filtering by app** → if user mentions an app ("from Slack", "from Xcode"), call `clipboard_list_recent_apps` first to find the bundle ID, then narrow `clipboard_search`
4. **Image with text** → `clipboard_get` returns `ocr_text` for image clips. Use that before requesting `include_image_data` (image bytes are expensive)

## Privacy

- The server already filters sensitive items (passwords, tokens) and blacklisted source apps. You don't need to re-filter.
- When echoing clipboard content back to the user, **don't quote large blocks unnecessarily** — summarize unless user asks for verbatim.
- Before `clipboard_set`: if writing anything that looks like a credential, confirm with user first.

## Anti-patterns

- Don't `clipboard_search` on every message "just in case" — only when user references past content
- Don't request `include_image_data: true` unless user explicitly wants the image processed (OCR text is usually enough)
- Don't loop `clipboard_get` over many IDs from a search — pick the most relevant one or two
