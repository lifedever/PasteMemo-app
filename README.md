# PasteMemo

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/PasteMemo-site@main/logo.svg" width="128" height="128" alt="PasteMemo Icon">
</p>

<h3 align="center">PasteMemo</h3>

<p align="center">
  <strong>A smart clipboard manager for macOS.</strong><br>
  Copy once, access anywhere, paste instantly.
</p>

<p align="center">
  <a href="https://github.com/lifedever/PasteMemo/releases/latest"><img src="https://img.shields.io/github/v/release/lifedever/PasteMemo?style=flat-square&color=F97316&label=Latest" alt="Latest Release"></a>
  <a href="https://github.com/lifedever/PasteMemo/releases"><img src="https://img.shields.io/github/downloads/lifedever/PasteMemo/total?style=flat-square&color=7C3AED&label=Downloads" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/license-GPL--3.0-green?style=flat-square" alt="License">
</p>

<p align="center">
  <a href="https://github.com/lifedever/PasteMemo/releases/latest">⬇️ Download</a> | <a href="https://www.lifedever.com/PasteMemo/">🌐 Website</a> | <a href="https://www.lifedever.com">❤️ Sponsor</a>
</p>

<p align="center">
  <a href="README_zh.md">中文文档</a>
</p>

---

## Screenshots

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/uPic/2026/03/CS2026-03-20-15.50.58@2x.png" width="720" alt="PasteMemo Main Window">
</p>

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/uPic/2026/03/CS2026-03-20-15.49.56@2x.png" width="720" alt="PasteMemo Quick Paste">
</p>

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/it/2026/03/quick-actions.png" width="720" alt="PasteMemo Quick Actions">
</p>

<p align="center">
  <img src="https://cdn.jsdelivr.net/gh/lifedever/images@master/it/2026/03/relay-mode.png" width="720" alt="PasteMemo Relay Mode">
</p>

## Highlights

- **Copy -> File, Instantly** -- Paste copied text as a `.txt` file, paste screenshots as image files. Drag directly into Finder or any file dialog.
- **AI Terminal Ready** -- Seamlessly paste images and files into AI terminals. Built for developers who live in the command line.
- **Smart Recognition** -- Automatically detects content type -- links with favicons, code snippets, colors, phone numbers, files -- with intelligent previews.
- **Beyond Copy-Paste** -- Paste file paths, filenames, save to folders, or paste-and-enter for terminal commands. Every clip is a multi-tool.

## Features

### Clipboard Management

- **Automatic Capture** -- Monitors the system clipboard in real-time. Text, images, files, links, code -- everything is saved.
- **Content Type Detection** -- Automatically classifies content: text, links, images, code, colors, phone numbers, files, documents, archives, audio, video, and more.
- **Rich Preview** -- Links show live web previews with favicons. Code gets syntax highlighting. Colors display swatches. Phone numbers show action buttons.
- **Pin to Top** -- Pin frequently used clips so they're always at the top of the list.
- **Search** -- Full-text search across all clipboard history. Find anything instantly.
- **Filter by Type** -- Filter by content type: text, links, images, code, colors, files, etc.
- **Filter by App** -- See which app each clip came from. Filter by source -- Chrome, VS Code, Figma, Slack, etc.
- **History Retention** -- Configure how long to keep history: forever, or auto-delete after 1-365 days.

### Quick Paste Panel

- **Global Hotkey** -- Press Cmd+Shift+V (customizable, supports F1-F12) from anywhere to open the Quick Paste panel.
- **Keyboard Navigation** -- Cmd+1 to Cmd+9 to paste directly. Arrow keys to navigate. Enter to paste. Full keyboard workflow.
- **Quick Actions (Cmd+K)** -- Command palette for paste, copy, pin, delete, and more -- all without leaving the keyboard.
- **Paste + Enter** -- Shift+Enter pastes and presses Enter. Perfect for terminal commands and chat apps.

### Relay Mode

- **Batch Paste** -- Copy multiple items, then paste them one by one in order. Ideal for filling forms, data entry, or repetitive workflows.
- **Text Splitting** -- Split text by a delimiter (comma, newline, etc.) to quickly build a relay queue.
- **Visual Queue** -- See your relay queue with a clear list. Current item is highlighted. Progress is tracked.

### Clipboard Automation

- **Rule Engine** -- Define conditions + actions to automatically process clipboard content.
- **Auto Trigger** -- Rules run silently when you copy. E.g., auto-clean tracking parameters from URLs.
- **Manual Trigger** -- Apply transformations via the command palette or right-click menu.
- **Built-in Rules** -- Clean URL tracking params, lowercase emails, remove blank lines, and more.

### Privacy & Security

- **Sensitive Detection** -- Automatically detects passwords and sensitive data, masks them in the UI.
- **Ignored Apps** -- Exclude specific apps (e.g., password managers) from clipboard monitoring.
- **Open Source** -- Full source code available. You know exactly what runs on your Mac.

### Customization

- **Themes** -- System, Light, or Dark mode.
- **Sound Effects** -- Customizable copy and paste sounds, or disable them entirely.
- **11 Languages** -- English, Simplified Chinese, Traditional Chinese, Japanese, Korean, German, French, Spanish, Italian, Russian, Indonesian

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+Shift+V (customizable) | Open/close Quick Paste panel |
| Cmd+1 - Cmd+9 | Paste the Nth item directly |
| Up / Down | Navigate history |
| Enter | Paste selected item |
| Shift+Enter | Paste and press Enter |
| Cmd+K | Open Quick Actions |
| Cmd+F | Focus search |
| Esc | Close panel |

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel Mac

## Install

### Homebrew (Recommended)

```bash
brew tap lifedever/tap
brew install --cask pastememo
```

Update to the latest version:

```bash
brew upgrade --cask pastememo
```

### Download

Grab the latest `.dmg` from [Releases](https://github.com/lifedever/PasteMemo/releases):

| File | Architecture |
|------|-------------|
| `PasteMemo-x.x.x-arm64.dmg` | Apple Silicon (M1/M2/M3/M4) |
| `PasteMemo-x.x.x-x86_64.dmg` | Intel Mac |

> On first launch: **Right-click PasteMemo.app -> Open -> Open**
>
> Or run: `xattr -cr /Applications/PasteMemo.app`

### Build from Source

```bash
git clone https://github.com/lifedever/PasteMemo.git
cd PasteMemo
swift build
```

## Contributing

Contributions are welcome! Please open an issue first to discuss what you'd like to change.

## Sponsor

If PasteMemo is useful to you, consider [buying me a coffee](https://www.lifedever.com).

## Feedback

Found a bug or have a suggestion? [Open an issue](https://github.com/lifedever/PasteMemo/issues).

## License

This project is licensed under the [GPL-3.0 License](LICENSE).

Copyright (c) 2026 lifedever.
