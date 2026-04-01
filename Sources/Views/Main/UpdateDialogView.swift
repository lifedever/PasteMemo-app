import SwiftUI
import WebKit

struct UpdateDialogView: View {
    @ObservedObject var updater: UpdateChecker
    private func dismiss() { WindowManager.shared.close(id: "update") }

    var body: some View {
        Group {
            if updater.isDownloading || updater.downloadComplete {
                downloadView
            } else {
                availableView
            }
        }
    }

    // MARK: - Update Available

    private var availableView: some View {
        VStack(spacing: 0) {
            headerSection(
                title: L10n.tr("update.available.title"),
                subtitle: L10n.tr("update.available.message", updater.latestVersion ?? "", updater.currentVersion)
            )

            if let notes = updater.releaseNotes, !notes.isEmpty {
                MarkdownWebView(markdown: notes)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
                    .padding(.horizontal, 20)
            }

            Divider().padding(.top, 16)

            HStack {
                Button(L10n.tr("update.skip")) {
                    if let version = updater.latestVersion {
                        updater.skipVersion(version)
                    }
                    dismiss()
                }
                .pointerCursor()

                Spacer()

                Button(L10n.tr("update.remind_later")) {
                    dismiss()
                }
                .pointerCursor()

                Button(L10n.tr("update.install")) {
                    updater.downloadUpdate()
                }
                .buttonStyle(.borderedProminent)
                .pointerCursor()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
    }

    // MARK: - Download Progress

    private var downloadView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                appIcon

                VStack(alignment: .leading, spacing: 6) {
                    Text(updater.downloadComplete ? L10n.tr("update.ready") : L10n.tr("update.downloading"))
                        .font(.headline)

                    ProgressView(value: updater.downloadProgress)
                        .progressViewStyle(.linear)

                    if !updater.downloadComplete && updater.totalBytes > 0 {
                        Text("\(formatBytes(updater.downloadedBytes)) / \(formatBytes(updater.totalBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            HStack {
                Spacer()
                if updater.downloadComplete {
                    Button(L10n.tr("update.install_restart")) {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            updater.installAndRestart()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
                } else {
                    Button(L10n.tr("update.cancel")) {
                        updater.cancelDownload()
                        dismiss()
                    }
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 420)
    }

    // MARK: - Shared

    private func headerSection(title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            appIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 56, height: 56)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Markdown WebView

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(buildHTML(from: markdown), baseURL: nil)
    }

    private func buildHTML(from md: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            font-size: 13px; line-height: 1.6; color: #e4e4ec;
            padding: 16px; -webkit-font-smoothing: antialiased;
        }
        @media (prefers-color-scheme: light) {
            body { color: #1a1a2e; }
            code { background: rgba(0,0,0,.06); }
            pre { background: rgba(0,0,0,.04); }
            blockquote { border-color: rgba(0,0,0,.15); color: #555; }
        }
        h1 { font-size: 1.5em; margin: 0.6em 0 0.4em; }
        h2 { font-size: 1.3em; margin: 0.6em 0 0.4em; }
        h3 { font-size: 1.1em; margin: 0.5em 0 0.3em; }
        p { margin: 0.4em 0; }
        ul, ol { margin: 0.4em 0; padding-left: 1.5em; }
        li { margin: 0.2em 0; }
        code {
            font-family: 'SF Mono', Menlo, monospace; font-size: 0.9em;
            background: rgba(255,255,255,.08); padding: 1px 5px; border-radius: 3px;
        }
        pre {
            background: rgba(255,255,255,.05); padding: 10px;
            border-radius: 6px; overflow-x: auto; margin: 0.5em 0;
        }
        pre code { background: none; padding: 0; }
        blockquote {
            border-left: 3px solid rgba(255,255,255,.2);
            padding-left: 12px; margin: 0.5em 0; color: #8888a0;
        }
        strong { font-weight: 600; }
        hr { border: none; border-top: 1px solid rgba(255,255,255,.1); margin: 0.8em 0; }
        a { color: #F97316; }
        </style></head><body>\(markdownToHTML(md))</body></html>
        """
    }

    private func markdownToHTML(_ md: String) -> String {
        var html = md
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        html = html.replacingOccurrences(of: "(?m)^&gt; (.*)$", with: "<blockquote>$1</blockquote>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?s)```\\w*\\n(.*?)```", with: "<pre><code>$1</code></pre>", options: .regularExpression)
        html = html.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^### (.+)$", with: "<h3>$1</h3>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^## (.+)$", with: "<h2>$1</h2>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^# (.+)$", with: "<h1>$1</h1>", options: .regularExpression)
        html = html.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        html = html.replacingOccurrences(of: "\\*(.+?)\\*", with: "<em>$1</em>", options: .regularExpression)
        html = html.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^---+$", with: "<hr>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^- (.+)$", with: "<li>$1</li>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(<li>.*</li>\n?)+", with: "<ul>$0</ul>", options: .regularExpression)
        html = html.replacingOccurrences(of: "(?m)^(?!<[hupbolt]|</?[hupbolt])(.+)$", with: "<p>$1</p>", options: .regularExpression)
        return html
    }
}
