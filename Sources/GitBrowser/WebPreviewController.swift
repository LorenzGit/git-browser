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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        buildFindBar(in: container)
        view = container
    }

    // MARK: - Find in page (⌘F)

    private let findBar = NSVisualEffectView()
    private let findField = NSSearchField()
    private let findStatus = NSTextField(labelWithString: "")

    private func buildFindBar(in container: NSView) {
        findBar.material = .headerView
        findBar.blendingMode = .withinWindow
        findBar.wantsLayer = true
        findBar.layer?.cornerRadius = 8
        findBar.layer?.borderWidth = 1
        findBar.layer?.borderColor = NSColor.separatorColor.cgColor
        findBar.isHidden = true
        findBar.translatesAutoresizingMaskIntoConstraints = false

        findField.placeholderString = "Find in page"
        findField.target = self
        findField.action = #selector(findFieldChanged(_:))
        findField.sendsSearchStringImmediately = true
        findField.translatesAutoresizingMaskIntoConstraints = false

        findStatus.textColor = .secondaryLabelColor
        findStatus.font = .systemFont(ofSize: 11)
        findStatus.translatesAutoresizingMaskIntoConstraints = false

        let previous = NSButton(
            image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous match")!,
            target: self, action: #selector(findPrevious(_:))
        )
        let next = NSButton(
            image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next match")!,
            target: self, action: #selector(findNext(_:))
        )
        let done = NSButton(title: "Done", target: self, action: #selector(hideFindBar(_:)))
        for button in [previous, next, done] {
            button.bezelStyle = .accessoryBarAction
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        for subview in [findField, findStatus, previous, next, done] {
            findBar.addSubview(subview)
        }
        container.addSubview(findBar)

        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            findBar.heightAnchor.constraint(equalToConstant: 36),

            findField.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 8),
            findField.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findField.widthAnchor.constraint(equalToConstant: 200),

            findStatus.leadingAnchor.constraint(equalTo: findField.trailingAnchor, constant: 8),
            findStatus.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),

            previous.leadingAnchor.constraint(equalTo: findStatus.trailingAnchor, constant: 8),
            previous.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            next.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 4),
            next.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            done.leadingAnchor.constraint(equalTo: next.trailingAnchor, constant: 8),
            done.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -8),
            done.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
        ])
    }

    func showFindBar() {
        findBar.isHidden = false
        view.window?.makeFirstResponder(findField)
        findField.selectText(nil)
    }

    @objc private func hideFindBar(_ sender: Any?) {
        findBar.isHidden = true
        findStatus.stringValue = ""
        view.window?.makeFirstResponder(webView)
    }

    @objc private func findFieldChanged(_ sender: Any?) {
        performFind(forward: true)
    }

    @objc func findNext(_ sender: Any?) { performFind(forward: true) }
    @objc func findPrevious(_ sender: Any?) { performFind(forward: false) }

    private func performFind(forward: Bool) {
        let query = findField.stringValue
        guard !query.isEmpty else {
            findStatus.stringValue = ""
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(query, configuration: configuration) { [weak self] result in
            self?.findStatus.stringValue = result.matchFound ? "" : "Not found"
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if !findBar.isHidden { hideFindBar(sender) }
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
