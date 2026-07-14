import AppKit
import GitBrowserCore

/// Main window: URL bar + navigation toolbar, lazy repository tree sidebar,
/// and the preview area. Owns the repository session lifecycle.
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation {
    private let registry = RepoSessionRegistry()
    private lazy var schemeHandler = RepoSchemeHandler(registry: registry)
    private var client: GHCLIClient?
    private var session: RepoSession?

    private let sidebar = SidebarViewController()
    private lazy var preview = PreviewContainerViewController(schemeHandler: schemeHandler)

    private let urlField = NSTextField()
    private var navSegment: NSSegmentedControl?
    private var urlFieldWidth: NSLayoutConstraint?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GitBrowser"
        // The toolbar owns the top edge (Safari-style): a visible title +
        // subtitle would consume the leading space and push the sidebar
        // toggle and navigation items out of position.
        window.titleVisibility = .hidden
        // All repo windows share one tabbing identifier so they group as
        // native macOS tabs; each tab is an independent repository session.
        window.tabbingIdentifier = "GitBrowserRepoWindow"
        window.center()
        window.setFrameAutosaveName("GitBrowserMainWindow")
        self.init(window: window)

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 480
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: preview))
        window.contentViewController = split

        sidebar.onSelectFile = { [weak self] path in
            self?.openPreview(path: path, kind: PreviewRouter.kind(forPath: path))
        }
        sidebar.onNeedsChildren = { [weak self] path in
            guard let session = self?.session else { return [] }
            return try await session.directory(at: path)
        }
        sidebar.onOpenInNewTab = { [weak self] path in
            self?.openInNewTab(path: path)
        }

        preview.web.routingDelegate = self
        preview.web.onDisplayedURLChanged = { [weak self] url in
            self?.syncSidebarSelection(with: url)
        }
        preview.web.onNavigationStateChanged = { [weak self] canGoBack, canGoForward in
            self?.navSegment?.setEnabled(canGoBack, forSegment: 0)
            self?.navSegment?.setEnabled(canGoForward, forSegment: 1)
        }

        let toolbar = NSToolbar(identifier: "GitBrowserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        NotificationCenter.default.addObserver(
            self, selector: #selector(toolbarGeometryChanged),
            name: NSWindow.didResizeNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(toolbarGeometryChanged),
            name: NSSplitView.didResizeSubviewsNotification, object: split.splitView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        updateURLFieldWidth()
    }

    @objc private func toolbarGeometryChanged(_ note: Notification) {
        updateURLFieldWidth()
    }

    /// Sizes the URL field to fill the toolbar space left over by the fixed
    /// items, based on the actual window and sidebar geometry.
    private func updateURLFieldWidth() {
        guard let window, let urlFieldWidth else { return }
        var sidebarWidth: CGFloat = 0
        var sidebarCollapsed = true
        if let split = window.contentViewController as? NSSplitViewController,
           let sidebarItem = split.splitViewItems.first {
            sidebarCollapsed = sidebarItem.isCollapsed
            sidebarWidth = sidebarCollapsed ? 0 : sidebarItem.viewController.view.frame.width
        }
        // Fixed neighbors in the content zone: nav segment, refresh, open,
        // inter-item spacing and margins. When the sidebar is collapsed the
        // traffic lights and the sidebar toggle join this zone too.
        let navWidth = navSegment.map { max($0.frame.width, 110) } ?? 120
        var chrome = navWidth + 44 + 44 + 100
        if sidebarCollapsed { chrome += 130 }
        urlFieldWidth.constant = max(240, window.frame.width - sidebarWidth - chrome)
    }

    // MARK: - Toolbar

    private enum ItemID {
        static let nav = NSToolbarItem.Identifier("nav")
        static let url = NSToolbarItem.Identifier("url")
        static let open = NSToolbarItem.Identifier("open")
        static let refresh = NSToolbarItem.Identifier("refresh")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, .sidebarTrackingSeparator,
            ItemID.nav, ItemID.refresh, ItemID.url,
            ItemID.open,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemID.nav:
            let segment = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                    NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!,
                    NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")!,
                ],
                trackingMode: .momentary,
                target: self,
                action: #selector(navSegmentClicked(_:))
            )
            segment.segmentStyle = .separated
            segment.setEnabled(false, forSegment: 0)
            segment.setEnabled(false, forSegment: 1)
            navSegment = segment
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = segment
            item.label = "Navigate"
            return item

        case ItemID.url:
            urlField.placeholderString = "https://github.com/owner/repo, owner/repo, or …/tree/branch/path"
            urlField.target = self
            urlField.action = #selector(openRepository(_:))
            urlField.lineBreakMode = .byTruncatingTail
            urlField.cell?.sendsActionOnEndEditing = false
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = urlField
            item.label = "Repository URL"
            urlField.translatesAutoresizingMaskIntoConstraints = false
            let minWidth = urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
            minWidth.isActive = true
            // An open-ended "grow" constraint inflates the item's fitting
            // size and NSToolbar responds by overflowing the item entirely.
            // Instead the width is recomputed from the real window/sidebar
            // geometry on every resize (updateURLFieldWidth).
            let width = urlField.widthAnchor.constraint(equalToConstant: 500)
            width.priority = .defaultHigh
            width.isActive = true
            urlFieldWidth = width
            DispatchQueue.main.async { [weak self] in self?.updateURLFieldWidth() }
            return item

        case ItemID.open:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: "Open")
            item.label = "Open"
            item.toolTip = "Open repository"
            item.target = self
            item.action = #selector(openRepository(_:))
            item.isBordered = true
            return item

        case ItemID.refresh:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Refresh")
            item.label = "Refresh"
            item.toolTip = "Re-resolve branch and reload"
            item.target = self
            item.action = #selector(refreshRepository(_:))
            item.isBordered = true
            return item

        default:
            return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == ItemID.refresh { return session != nil }
        return true
    }

    // MARK: - Actions

    /// Backs the tab bar's "+" button and File → New Tab (⌘T): opens a
    /// fresh, independent repository session as a native tab of this window.
    override func newWindowForTab(_ sender: Any?) {
        makeTabbedController()?.focusURLField(sender)
    }

    /// Creates a sibling tab hosting its own window controller.
    @discardableResult
    private func makeTabbedController() -> MainWindowController? {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let current = window
        else { return nil }
        let controller = appDelegate.makeWindowController()
        guard let newWindow = controller.window else { return nil }
        current.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
        return controller
    }

    /// Sidebar context menu: opens the same repository (same requested ref)
    /// in a new tab as an independent session, revealing the given path.
    func openInNewTab(path: String) {
        guard let session else { return }
        let coords = session.coordinates
        let ref = session.requestedRef ?? session.metadata.defaultBranch
        let marker = path.contains(".") ? "blob" : "tree"
        let urlString = "https://\(coords.host)/\(coords.owner)/\(coords.repo)/\(marker)/\(ref)/\(path)"
        makeTabbedController()?.openRepository(urlString: urlString)
    }

    @objc func focusURLField(_ sender: Any?) {
        window?.makeFirstResponder(urlField)
    }

    @objc private func navSegmentClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: goBack(sender)
        case 1: goForward(sender)
        default: reloadPage(sender)
        }
    }

    @objc func goBack(_ sender: Any?) { preview.goBack() }
    @objc func goForward(_ sender: Any?) { preview.goForward() }
    @objc func reloadPage(_ sender: Any?) { preview.reload() }

    /// Programmatic open (used for the launch-argument URL).
    func openRepository(urlString: String) {
        urlField.stringValue = urlString
        openRepository(nil)
    }

    @objc func openRepository(_ sender: Any?) {
        let input = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard let parsed = GitHubRepoURLParser.parse(input) else {
            presentError(title: "Unrecognized repository URL",
                         message: "Enter something like https://github.com/owner/repo or owner/repo.")
            return
        }
        Task { await openRepo(parsed) }
    }

    @objc func refreshRepository(_ sender: Any?) {
        guard let session else { return }
        Task {
            do {
                try await session.refresh()
                let sha = await session.commitSHA
                updateTitle(session: session, sha: sha)
                await sidebar.reloadRoot()
                preview.reloadCurrent()
            } catch {
                presentError(title: "Refresh failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Repository lifecycle

    private func openRepo(_ parsed: ParsedRepoURL) async {
        do {
            if client == nil {
                client = try GHCLIClient()
            }
            guard let client else { return }

            // Close the previous session; its in-memory data is discarded.
            if let old = session {
                registry.close(id: old.id)
                session = nil
            }

            let newSession = try await RepoSession.open(
                client: client, coordinates: parsed.coordinates, ref: parsed.ref
            )
            registry.register(newSession)
            session = newSession

            let sha = await newSession.commitSHA
            updateTitle(session: newSession, sha: sha)
            sidebar.configure(sessionID: newSession.id)
            await sidebar.reloadRoot()
            preview.showWelcome(repoName: newSession.coordinates.displayName)
            NSLog("GitBrowser: opened %@ at %@ as %@",
                  newSession.coordinates.displayName, String(sha.prefix(12)), newSession.id)

            if let initialPath = parsed.initialPath {
                if initialPath.contains(".") {
                    openPreview(path: initialPath, kind: PreviewRouter.kind(forPath: initialPath))
                }
                await sidebar.reveal(path: initialPath)
            }
        } catch {
            presentError(title: "Could not open repository", message: error.localizedDescription)
        }
    }

    private func updateTitle(session: RepoSession, sha: String) {
        // Titlebar text is hidden; this still names the window in Mission
        // Control and the Window menu. The URL field tooltip carries the
        // pinned commit.
        window?.title = "\(session.coordinates.displayName) @ \(String(sha.prefix(10)))"
        urlField.toolTip = "\(session.coordinates.displayName) @ \(String(sha.prefix(10)))"
            + (session.metadata.description.map { " — \($0)" } ?? "")
    }

    // MARK: - Preview routing

    func openPreview(path: String, kind: PreviewKind) {
        guard let session else { return }
        preview.show(path: path, kind: kind, session: session)
        switch kind {
        case .image, .pdf, .media:
            // Web-based previews sync via onDisplayedURLChanged when the
            // navigation lands; native previews sync here.
            Task { await sidebar.reveal(path: path) }
        case .html, .markdown, .code:
            break
        }
    }

    /// Mirrors the file currently displayed in the web preview (after link
    /// clicks, Back, Forward, Reload) in the sidebar: expands to it, selects
    /// it, and scrolls it into view.
    private func syncSidebarSelection(with url: URL) {
        guard let session,
              url.host?.lowercased() == session.id,
              let path = RepoPath.normalizeURLPath(url.path),
              !path.isEmpty
        else { return }
        Task { await sidebar.reveal(path: path) }
    }

    private func presentError(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
}

extension MainWindowController: WebPreviewRoutingDelegate {
    func webPreview(_ web: WebPreviewController, route path: String, kind: PreviewKind) {
        openPreview(path: path, kind: kind)
    }

    func webPreview(_ web: WebPreviewController, openExternal url: URL) {
        NSWorkspace.shared.open(url)
    }
}
