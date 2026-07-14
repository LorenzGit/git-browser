import AppKit
import GitBrowserCore
import WebKit

protocol WebPreviewRoutingDelegate: AnyObject {
    /// Top-level navigation to a repository file that belongs in a different
    /// preview surface (markdown, code, image, media, pdf).
    func webPreview(_ web: WebPreviewController, route path: String, kind: PreviewKind)
    /// External http/https link — opened in the user's default browser.
    func webPreview(_ web: WebPreviewController, openExternal url: URL)
}

/// WKWebView-based preview for HTML (loaded straight from repobrowser:// URLs)
/// and for rendered Markdown/code (same URLs with `?gb-view=rendered`).
///
/// Security: the configuration registers only the repobrowser scheme handler.
/// No WKScriptMessageHandler is installed, so repository JavaScript has no
/// bridge whatsoever to native code — it cannot run gh, reach GitHub
/// credentials, spawn processes, or read local files.
final class WebPreviewController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    weak var routingDelegate: WebPreviewRoutingDelegate?

    /// Fires when a main-frame navigation lands (link clicks, Back, Forward,
    /// Reload) so the sidebar can mirror the file currently in view.
    var onDisplayedURLChanged: ((URL) -> Void)?
    /// Fires whenever canGoBack/canGoForward may have changed.
    var onNavigationStateChanged: ((_ canGoBack: Bool, _ canGoForward: Bool) -> Void)?

    private(set) var webView: WKWebView!

    init(schemeHandler: RepoSchemeHandler) {
        super.init(nibName: nil, bundle: nil)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: RepoSchemeHandler.scheme)
        // Ephemeral store: nothing (cookies, storage) persists to disk.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = webView
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    }

    // MARK: - Loading

    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    func loadHTMLString(_ html: String) {
        webView.loadHTMLString(html, baseURL: nil)
    }

    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() {
        if webView.url != nil { webView.reload() }
    }

    // MARK: - Navigation progress

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        onNavigationStateChanged?(webView.canGoBack, webView.canGoForward)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onNavigationStateChanged?(webView.canGoBack, webView.canGoForward)
        if let url = webView.url {
            onDisplayedURLChanged?(url)
        }
    }

    // MARK: - Navigation policy

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""

        // External links open in the user's default browser.
        if scheme == "http" || scheme == "https" {
            let isTopLevel = navigationAction.targetFrame == nil
                || navigationAction.targetFrame?.isMainFrame == true
            if isTopLevel {
                decisionHandler(.cancel)
                routingDelegate?.webPreview(self, openExternal: url)
            } else {
                // Iframe navigations inside a page are the page's business.
                decisionHandler(.allow)
            }
            return
        }

        guard scheme == RepoSchemeHandler.scheme else {
            // about:blank and friends.
            decisionHandler(.allow)
            return
        }

        // target="_blank" / window.open of repo URLs: load in this preview.
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            route(url: url)
            return
        }

        guard navigationAction.targetFrame?.isMainFrame == true else {
            // Subframes and subresources load through the scheme handler.
            decisionHandler(.allow)
            return
        }

        // Same-document anchor navigation.
        if let current = webView.url, urlsDifferOnlyInFragment(current, url) {
            decisionHandler(.allow)
            return
        }

        // Route top-level navigations by file type.
        if shouldStayInWebView(url: url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            route(url: url)
        }
    }

    /// HTML files, directory URLs (index.html), and rendered previews stay in
    /// the web view; everything else moves to its dedicated preview surface.
    private func shouldStayInWebView(url: URL) -> Bool {
        guard let path = RepoPath.normalizeURLPath(url.path) else { return true }
        if path.isEmpty || url.path.hasSuffix("/") { return true }
        if url.query?.contains("gb-view=rendered") == true { return true }
        switch PreviewRouter.kind(forPath: path) {
        case .html:
            return true
        default:
            return false
        }
    }

    private func route(url: URL) {
        guard let path = RepoPath.normalizeURLPath(url.path), !path.isEmpty else { return }
        routingDelegate?.webPreview(self, route: path, kind: PreviewRouter.kind(forPath: path))
    }

    private func urlsDifferOnlyInFragment(_ a: URL, _ b: URL) -> Bool {
        var ca = URLComponents(url: a, resolvingAgainstBaseURL: false)
        var cb = URLComponents(url: b, resolvingAgainstBaseURL: false)
        ca?.fragment = nil
        cb?.fragment = nil
        return ca == cb && ca != nil
    }

    // MARK: - WKUIDelegate

    /// window.open / target="_blank" with window features. We never create a
    /// second web view: repo URLs load here, external URLs go to the browser.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == RepoSchemeHandler.scheme {
            route(url: url)
        } else if scheme == "http" || scheme == "https" {
            routingDelegate?.webPreview(self, openExternal: url)
        }
        return nil
    }
}
