import SwiftUI
import WebKit

@MainActor
final class WebPreviewPool {
    static let shared = WebPreviewPool()

    private let webView: WKWebView
    private let coordinator = Coordinator()
    private weak var activeContainer: NSView?

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
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = coordinator
    }

    func attach(to container: NSView) {
        if webView.superview !== container {
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
        coordinator.removeErrorOverlay(from: webView)
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        private weak var errorOverlay: NSView?

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
            showErrorOverlay(on: webView, message: error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            showErrorOverlay(on: webView, message: error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            removeErrorOverlay(from: webView)
        }

        func removeErrorOverlay(from webView: WKWebView) {
            errorOverlay?.removeFromSuperview()
            errorOverlay = nil
        }

        private func showErrorOverlay(on webView: WKWebView, message: String) {
            removeErrorOverlay(from: webView)

            let overlay = NSView(frame: webView.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.wantsLayer = true

            let label = NSTextField(wrappingLabelWithString: L10n.tr("detail.preview_failed"))
            label.font = .systemFont(ofSize: 13)
            label.textColor = .tertiaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false

            overlay.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, constant: -32),
            ])

            webView.addSubview(overlay)
            errorOverlay = overlay
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

    func makeNSView(context: Context) -> NSView {
        let view = WebPreviewContainerView(frame: .zero)
        WebPreviewPool.shared.attach(to: view)
        WebPreviewPool.shared.load(url)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        WebPreviewPool.shared.attach(to: nsView)
        WebPreviewPool.shared.load(url)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        WebPreviewPool.shared.detach(from: nsView)
    }
}
