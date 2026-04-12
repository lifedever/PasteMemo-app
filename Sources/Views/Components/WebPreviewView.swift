import SwiftUI
import WebKit

@MainActor
final class WebPreviewPool {
    static let shared = WebPreviewPool()

    private let webView: WKWebView
    private let coordinator = Coordinator()
    private weak var activeContainer: NSView?
    var readinessHandler: ((Bool) -> Void)?
    private var readyToken = 0

    private init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let viewportScript = WKUserScript(
            source: """
            var meta = document.querySelector('meta[name="viewport"]');
            if (!meta) {
                meta = document.createElement('meta');
                meta.name = 'viewport';
                document.head.appendChild(meta);
            }
            meta.content = 'width=device-width, initial-scale=1.0, shrink-to-fit=yes';
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        let muteScript = WKUserScript(
            source: """
            document.querySelectorAll('video, audio').forEach(function(el) {
                el.pause();
                el.muted = true;
                el.autoplay = false;
                el.removeAttribute('autoplay');
            });
            var obs = new MutationObserver(function() {
                document.querySelectorAll('video, audio').forEach(function(el) {
                    el.pause();
                    el.muted = true;
                    el.autoplay = false;
                    el.removeAttribute('autoplay');
                });
            });
            obs.observe(document.body || document.documentElement, { childList: true, subtree: true });
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(viewportScript)
        config.userContentController.addUserScript(muteScript)

        webView = WKWebView(frame: .zero, configuration: config)
        // Anti-bot guards on sites like baidu.com serve a blank body to the
        // default WKWebView UA (it contains AppleWebKit without Version/…,
        // matching no real Safari release). Pretend to be a stock macOS
        // Safari so we receive the real page markup.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = coordinator
        coordinator.pool = self
    }

    func attach(to container: NSView) {
        if webView.superview !== container {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
            coordinator.loadedURL = nil

            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
            activeContainer = container
        }
    }

    func load(_ url: URL) {
        if coordinator.loadedURL == url { return }
        webView.stopLoading()
        coordinator.loadedURL = url
        notifyReady(false)
        webView.load(URLRequest(url: url, timeoutInterval: 15))
    }

    func detach(from container: NSView? = nil) {
        if let container, activeContainer !== container {
            return
        }
        coordinator.loadedURL = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        activeContainer = nil
    }

    fileprivate func markReadyAfterFirstPaint() {
        readyToken &+= 1
        let token = readyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
            guard let self, self.readyToken == token else { return }
            self.notifyReady(true)
        }
    }

    fileprivate func markReadyImmediately() {
        readyToken &+= 1
        notifyReady(true)
    }

    private func notifyReady(_ ready: Bool) {
        readinessHandler?(ready)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        weak var pool: WebPreviewPool?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            // Ready stays false; caller keeps the static fallback visible.
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            // Ready stays false; caller keeps the static fallback visible.
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Do not flip the ready state on commit — some sites (e.g.
            // baidu.com) commit a navigation but then render blank or stall,
            // leaving the viewer staring at an empty webview. Wait for
            // didFinish which only fires after the document is fully loaded.
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pool?.markReadyImmediately()
        }
    }
}

private final class WebPreviewContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

struct WebPreviewView: NSViewRepresentable {
    let url: URL
    var onReadyStateChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = WebPreviewContainerView(frame: .zero)
        WebPreviewPool.shared.readinessHandler = onReadyStateChange
        WebPreviewPool.shared.attach(to: view)
        WebPreviewPool.shared.load(url)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        WebPreviewPool.shared.readinessHandler = onReadyStateChange
        WebPreviewPool.shared.attach(to: nsView)
        WebPreviewPool.shared.load(url)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        WebPreviewPool.shared.detach(from: nsView)
    }
}
