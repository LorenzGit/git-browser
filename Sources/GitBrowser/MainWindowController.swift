import AppKit
import GitBrowserCore

/// Main window: URL bar + navigation toolbar, lazy repository tree sidebar,
/// and the preview area. Owns the repository session lifecycle.
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation {
    private let registry = RepoSessionRegistry()
    private lazy var schemeHandler = RepoSchemeHandler(registry: registry)
    /// Cached gh-backed client (feature detection runs once).
    private var ghClient: GHCLIClient?
    /// Client behind the current session: gh-backed or local-folder.
    private var activeClient: (any GitHubClient)?
    private var session: RepoSession?
    /// Set when the current session browses a local folder.
    private var localRootURL: URL?
    /// Pinned ref for a local session (nil = live working tree).
    private var localRef: String?

    private let sidebar = SidebarViewController()
    private lazy var preview = PreviewContainerViewController(schemeHandler: schemeHandler)

    private let urlField = NSTextField()
    private var navSegment: NSSegmentedControl?
    private var urlFieldWidth: NSLayoutConstraint?
    private var branchPopup: NSPopUpButton?

    /// Path list for ⌘P, fetched once per session (metadata only).
    private var cachedFullTree: FullTree?
    /// Open pull request, when this tab is a PR preview session.
    private var currentPR: PullRequestInfo?
    /// The repo path most recently shown in the preview (any kind).
    private var lastViewedPath: String?

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
        sidebar.onShowHistory = { [weak self] path in
            self?.showHistory(forPath: path)
        }
        sidebar.onCopyLink = { [weak self] path, isDirectory in
            guard let link = self?.githubWebURL(path: path, isDirectory: isDirectory) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
        sidebar.onOpenOnGitHub = { [weak self] path, isDirectory in
            guard let self else { return }
            if let localRoot = self.localRootURL {
                // Local sessions: reveal the file in Finder instead.
                NSWorkspace.shared.activateFileViewerSelecting(
                    [localRoot.appendingPathComponent(path)]
                )
                return
            }
            guard let link = self.githubWebURL(path: path, isDirectory: isDirectory),
                  let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }
        sidebar.onSelectDirectory = { [weak self] path in
            self?.openFolderReadmeIfPresent(directory: path)
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
        let branchWidth = branchPopup.map { min(max($0.frame.width, 80), 180) } ?? 100
        var chrome = navWidth + branchWidth + 44 + 44 + 44 + 120
        if sidebarCollapsed { chrome += 130 }
        urlFieldWidth.constant = max(240, window.frame.width - sidebarWidth - chrome)
    }

    // MARK: - Toolbar

    private enum ItemID {
        static let nav = NSToolbarItem.Identifier("nav")
        static let url = NSToolbarItem.Identifier("url")
        static let open = NSToolbarItem.Identifier("open")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let branch = NSToolbarItem.Identifier("branch")
        static let folder = NSToolbarItem.Identifier("folder")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, .sidebarTrackingSeparator,
            ItemID.nav, ItemID.refresh, ItemID.branch, ItemID.url,
            ItemID.open, ItemID.folder,
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

        case ItemID.branch:
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.autoenablesItems = false
            popup.isEnabled = false
            popup.addItem(withTitle: "Branch")
            (popup.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
            branchPopup = popup
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = popup
            item.label = "Branch"
            item.toolTip = "Switch branch or tag"
            return item

        case ItemID.folder:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open Folder")
            item.label = "Open Folder"
            item.toolTip = "Browse a local folder"
            item.target = self
            item.action = #selector(openFolderPanel(_:))
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

    /// Opens a path from the current repository in a new tab as an
    /// independent session. `ref` overrides the current ref (used by file
    /// history to open a file at an older commit).
    func openInNewTab(path: String, ref: String? = nil) {
        guard let session else { return }
        if let localRoot = localRootURL {
            makeTabbedController()?.openLocalFolder(
                rootURL: localRoot, ref: ref ?? localRef, initialPath: path
            )
            return
        }
        let coords = session.coordinates
        let effectiveRef = ref
            ?? currentPR?.headSHA
            ?? session.requestedRef
            ?? session.metadata.defaultBranch
        let marker = path.contains(".") ? "blob" : "tree"
        let urlString = "https://\(coords.host)/\(coords.owner)/\(coords.repo)/\(marker)/\(effectiveRef)/\(path)"
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
        if let folderURL = localFolderURL(fromInput: input) {
            openLocalFolder(rootURL: folderURL)
            return
        }
        guard let parsed = GitHubRepoURLParser.parse(input) else {
            presentError(title: "Unrecognized repository URL",
                         message: "Enter a GitHub URL (owner/repo) or a local folder path.")
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
            if ghClient == nil {
                ghClient = try GHCLIClient()
            }
            guard let client = ghClient else { return }

            // A pull-request URL pins the session to the PR's head commit.
            var ref = parsed.ref
            var pr: PullRequestInfo?
            if let number = parsed.pullRequest {
                pr = try await client.pullRequest(for: parsed.coordinates, number: number)
                ref = pr?.headSHA
            }

            // Close the previous session; its in-memory data is discarded.
            if let old = session {
                registry.close(id: old.id)
                session = nil
            }
            cachedFullTree = nil
            currentPR = pr
            lastViewedPath = nil
            localRootURL = nil
            localRef = nil
            activeClient = client

            let newSession = try await RepoSession.open(
                client: client, coordinates: parsed.coordinates, ref: ref
            )
            registry.register(newSession)
            session = newSession

            let sha = await newSession.commitSHA
            updateTitle(session: newSession, sha: sha)
            sidebar.configure(sessionID: newSession.id, isLocal: false)
            await sidebar.reloadRoot()
            RecentRepos.add(urlField.stringValue)
            let refTitle = currentPR.map { "PR #\($0.number)" }
                ?? newSession.requestedRef ?? newSession.metadata.defaultBranch
            populateBranchMenu(currentTitle: refTitle)
            NSLog("GitBrowser: opened %@ at %@ as %@",
                  newSession.coordinates.displayName, String(sha.prefix(12)), newSession.id)

            if let pr {
                let files = try await client.pullRequestFiles(for: parsed.coordinates, number: pr.number)
                sidebar.showPRChanges(files)
                preview.showWelcome(
                    repoName: "PR #\(pr.number): \(pr.title) (\(files.count) changed files)"
                )
                return
            }

            preview.showWelcome(repoName: newSession.coordinates.displayName)
            if let initialPath = parsed.initialPath {
                if initialPath.contains(".") {
                    openPreview(path: initialPath, kind: PreviewRouter.kind(forPath: initialPath))
                }
                await sidebar.reveal(path: initialPath)
            } else {
                // Land on the repository README, GitHub-style.
                let root = (try? await newSession.directory(at: "")) ?? []
                if let readme = Self.findReadme(in: root) {
                    openPreview(path: readme, kind: PreviewRouter.kind(forPath: readme))
                }
            }
        } catch {
            presentError(title: "Could not open repository", message: error.localizedDescription)
        }
    }

    // MARK: - Local folders

    /// Folder-picker toolbar button and File → Open Folder… (⇧⌘O).
    @objc func openFolderPanel(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to browse (git repositories get branches and history)"
        panel.prompt = "Browse"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openLocalFolder(rootURL: url)
        }
    }

    /// Opens a local folder session. `ref` pins to a git branch/tag/commit
    /// (nil = live working tree).
    func openLocalFolder(rootURL: URL, ref: String? = nil, initialPath: String? = nil) {
        Task { await openLocal(rootURL: rootURL, ref: ref, initialPath: initialPath) }
    }

    private func openLocal(rootURL: URL, ref: String?, initialPath: String?) async {
        do {
            let localClient = LocalFolderClient(rootURL: rootURL)

            if let old = session {
                registry.close(id: old.id)
                session = nil
            }
            cachedFullTree = nil
            currentPR = nil
            lastViewedPath = nil
            localRootURL = localClient.rootURL
            localRef = ref
            activeClient = localClient

            // Working-tree sessions skip the byte cache so edits on disk show
            // up on reload; ref-pinned sessions are immutable and cache.
            let pinned = ref != nil && ref != LocalFolderClient.workingTreeRef
            let coordinates = LocalFolderClient.coordinates(for: localClient.rootURL)
            let newSession = try await RepoSession.open(
                client: localClient, coordinates: coordinates, ref: ref, cachesData: pinned
            )
            registry.register(newSession)
            session = newSession

            let refTitle = ref ?? "Working Tree"
            let folderName = localClient.rootURL.lastPathComponent
            window?.title = "\(folderName) — \(refTitle)"
            let displayPath = (localClient.rootURL.path as NSString).abbreviatingWithTildeInPath
            urlField.stringValue = displayPath
            urlField.toolTip = "\(localClient.rootURL.path) (\(refTitle))"
                + (localClient.isGitRepository ? "" : " — not a git repository")

            sidebar.configure(sessionID: newSession.id, isLocal: true)
            await sidebar.reloadRoot()
            RecentRepos.add(displayPath)
            populateBranchMenu(currentTitle: refTitle)
            NSLog("GitBrowser: opened local folder %@ (%@) as %@",
                  localClient.rootURL.path, refTitle, newSession.id)

            preview.showWelcome(repoName: folderName)
            if let initialPath {
                if initialPath.contains(".") {
                    openPreview(path: initialPath, kind: PreviewRouter.kind(forPath: initialPath))
                }
                await sidebar.reveal(path: initialPath)
            } else {
                let root = (try? await newSession.directory(at: "")) ?? []
                if let readme = Self.findReadme(in: root) {
                    openPreview(path: readme, kind: PreviewRouter.kind(forPath: readme))
                }
            }
        } catch {
            presentError(title: "Could not open folder", message: error.localizedDescription)
        }
    }

    /// Treats absolute, tilde, and file:// inputs in the URL field as local
    /// folder paths.
    private func localFolderURL(fromInput input: String) -> URL? {
        var candidate: String?
        if input.hasPrefix("file://"), let url = URL(string: input) {
            candidate = url.path
        } else if input.hasPrefix("/") || input.hasPrefix("~") {
            candidate = (input as NSString).expandingTildeInPath
        }
        guard let candidate else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: candidate)
    }

    /// Best README candidate among a directory's entries.
    static func findReadme(in entries: [DirEntry]) -> String? {
        let files = entries.filter { $0.type == .file && $0.name.lowercased().hasPrefix("readme") }
        let ranked = files.sorted { a, b in
            func rank(_ name: String) -> Int {
                let lower = name.lowercased()
                if lower == "readme.md" { return 0 }
                if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") { return 1 }
                if lower == "readme" { return 2 }
                return 3
            }
            return rank(a.name) < rank(b.name)
        }
        return ranked.first?.path
    }

    private func openFolderReadmeIfPresent(directory: String) {
        guard let session else { return }
        Task { [weak self] in
            guard let entries = try? await session.directory(at: directory) else { return }
            if let readme = Self.findReadme(in: entries) {
                await MainActor.run {
                    self?.openPreview(path: readme, kind: PreviewRouter.kind(forPath: readme))
                }
            }
        }
    }

    // MARK: - Branch switching

    private func populateBranchMenu(currentTitle: String) {
        guard let popup = branchPopup, let activeClient, let session else { return }
        popup.removeAllItems()
        popup.addItem(withTitle: currentTitle)
        popup.isEnabled = true
        updateURLFieldWidth()

        let coordinates = session.coordinates
        let isLocal = localRootURL != nil
        Task { [weak self] in
            var branches = (try? await activeClient.listBranches(for: coordinates)) ?? []
            let tags = (try? await activeClient.listTags(for: coordinates)) ?? []
            if isLocal, !branches.isEmpty || !tags.isEmpty {
                branches.insert("Working Tree", at: 0)
            }
            await MainActor.run {
                self?.fillBranchMenu(currentTitle: currentTitle, branches: branches, tags: tags)
            }
        }
    }

    private func fillBranchMenu(currentTitle: String, branches: [String], tags: [String]) {
        guard let popup = branchPopup else { return }
        popup.removeAllItems()
        popup.addItem(withTitle: currentTitle)
        popup.menu?.addItem(.separator())

        func addSection(_ header: String, names: [String]) {
            guard !names.isEmpty else { return }
            let headerItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            popup.menu?.addItem(headerItem)
            for name in names {
                let item = NSMenuItem(title: name, action: #selector(branchChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.indentationLevel = 1
                item.state = name == currentTitle ? .on : .off
                popup.menu?.addItem(item)
            }
        }
        addSection("Branches", names: branches)
        addSection("Tags", names: tags)
        popup.selectItem(at: 0)
        updateURLFieldWidth()
    }

    @objc private func branchChosen(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let session else { return }
        branchPopup?.selectItem(at: 0)

        if let localRoot = localRootURL {
            let newRef = name == "Working Tree" ? nil : name
            guard newRef != localRef else { return }
            openLocalFolder(rootURL: localRoot, ref: newRef, initialPath: lastViewedPath)
            return
        }

        guard name != (session.requestedRef ?? session.metadata.defaultBranch) || currentPR != nil else {
            return
        }
        let parsed = ParsedRepoURL(
            coordinates: session.coordinates, ref: name, initialPath: lastViewedPath
        )
        urlField.stringValue = "https://\(session.coordinates.host)/\(session.coordinates.owner)/"
            + "\(session.coordinates.repo)/tree/\(name)"
        Task { await openRepo(parsed) }
    }

    // MARK: - Palettes (Go to File, Search Code, History)

    @objc func goToFile(_ sender: Any?) {
        guard let window, let session, let client = activeClient else { return }
        let coordinates = session.coordinates
        PaletteController.present(
            on: window,
            placeholder: "Go to file in \(coordinates.displayName)…",
            source: .local(loadAll: { [weak self] in
                if self?.cachedFullTree == nil {
                    let commit = await session.commitSHA
                    self?.cachedFullTree = try await client.fullTree(for: coordinates, commit: commit)
                }
                let tree = self?.cachedFullTree ?? FullTree(entries: [], truncated: false)
                return tree.entries
                    .filter { $0.type == .file }
                    .map { entry in
                        PaletteController.Row(
                            title: RepoPath.fileName(of: entry.path),
                            subtitle: entry.path,
                            payload: entry.path
                        )
                    }
            })
        ) { [weak self] row in
            self?.openPreview(path: row.payload, kind: PreviewRouter.kind(forPath: row.payload))
            Task { await self?.sidebar.reveal(path: row.payload) }
        }
    }

    @objc func searchCodeAction(_ sender: Any?) {
        guard let window, let session, let client = activeClient else { return }
        let coordinates = session.coordinates
        PaletteController.present(
            on: window,
            placeholder: "Search code in \(coordinates.displayName) (default branch)…",
            source: .remote(search: { query in
                try await client.searchCode(for: coordinates, query: query).map { result in
                    PaletteController.Row(
                        title: result.path,
                        subtitle: result.fragments.first?
                            .replacingOccurrences(of: "\n", with: " ⏎ ")
                            .trimmingCharacters(in: .whitespaces),
                        payload: result.path
                    )
                }
            })
        ) { [weak self] row in
            self?.openPreview(path: row.payload, kind: PreviewRouter.kind(forPath: row.payload))
            Task { await self?.sidebar.reveal(path: row.payload) }
        }
    }

    @objc func showHistoryForCurrentFile(_ sender: Any?) {
        guard let path = lastViewedPath else {
            NSSound.beep()
            return
        }
        showHistory(forPath: path)
    }

    /// Commit history for one path; choosing a commit opens the file at that
    /// commit in a new tab (a fresh session pinned to that SHA).
    func showHistory(forPath path: String) {
        guard let window, let session, let client = activeClient else { return }
        let coordinates = session.coordinates
        let requestedRef = session.requestedRef
        PaletteController.present(
            on: window,
            placeholder: "History of \(path)…",
            source: .local(loadAll: {
                let ref: String
                if let requestedRef {
                    ref = requestedRef
                } else {
                    ref = await session.commitSHA
                }
                return try await client.fileHistory(for: coordinates, ref: ref, path: path)
                    .map { commit in
                        PaletteController.Row(
                            title: commit.summary,
                            subtitle: "\(String(commit.sha.prefix(9))) · \(commit.authorName) · \(commit.date)",
                            payload: commit.sha
                        )
                    }
            })
        ) { [weak self] row in
            self?.openInNewTab(path: path, ref: row.payload)
        }
    }

    // MARK: - Bookmarks

    /// ⌘D: bookmark whatever is open — repo/folder, current ref, current file.
    @objc func addBookmark(_ sender: Any?) {
        guard let window, let session else {
            NSSound.beep()
            return
        }
        let location: Bookmark.Location
        let ref: String?
        let baseName: String
        if let localRoot = localRootURL {
            location = .local(path: localRoot.path)
            ref = localRef
            baseName = localRoot.lastPathComponent
        } else {
            location = .remote(session.coordinates)
            // PR sessions are transient; bookmark the repo itself.
            ref = currentPR == nil ? session.requestedRef : nil
            baseName = session.coordinates.displayName
        }
        let path = lastViewedPath
        let defaultName = path.map { "\(baseName) — \(RepoPath.fileName(of: $0))" } ?? baseName

        let alert = NSAlert()
        alert.messageText = "Add Bookmark"
        var details = [locationLabel(location)]
        if let ref { details.append("branch: \(ref)") }
        if let path { details.append("file: \(path)") }
        alert.informativeText = details.joined(separator: "\n")
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            BookmarkStore.shared.add(Bookmark(
                name: trimmed.isEmpty ? defaultName : trimmed,
                location: location, ref: ref, path: path
            ))
        }
    }

    private func locationLabel(_ location: Bookmark.Location) -> String {
        switch location {
        case .remote(let coords): return "\(coords.host)/\(coords.owner)/\(coords.repo)"
        case .local(let path): return path
        }
    }

    /// Opens a bookmark, falling back to the default branch (or working tree
    /// for local folders) when its branch or file no longer exists.
    func open(bookmark: Bookmark) {
        Task { await openBookmarkResolved(bookmark) }
    }

    private func openBookmarkResolved(_ bookmark: Bookmark) async {
        do {
            switch bookmark.location {
            case .local(let folderPath):
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    presentError(title: "Bookmark unavailable",
                                 message: "The folder \(folderPath) no longer exists.")
                    return
                }
                let rootURL = URL(fileURLWithPath: folderPath)
                let localClient = LocalFolderClient(rootURL: rootURL)
                let resolution = await BookmarkResolver.resolve(
                    bookmark: bookmark, client: localClient,
                    coordinates: LocalFolderClient.coordinates(for: rootURL)
                )
                await openLocal(rootURL: rootURL, ref: resolution.ref, initialPath: resolution.path)
                reportBookmarkFallback(bookmark, resolution, fallbackName: "the working tree")

            case .remote(let coordinates):
                if ghClient == nil {
                    ghClient = try GHCLIClient()
                }
                guard let client = ghClient else { return }
                let resolution = await BookmarkResolver.resolve(
                    bookmark: bookmark, client: client, coordinates: coordinates
                )
                var display = "https://\(coordinates.host)/\(coordinates.owner)/\(coordinates.repo)"
                if let ref = resolution.ref { display += "/tree/\(ref)" }
                urlField.stringValue = display
                await openRepo(ParsedRepoURL(
                    coordinates: coordinates, ref: resolution.ref, initialPath: resolution.path
                ))
                reportBookmarkFallback(bookmark, resolution, fallbackName: "the default branch")
            }
        } catch {
            presentError(title: "Could not open bookmark", message: error.localizedDescription)
        }
    }

    private func reportBookmarkFallback(
        _ bookmark: Bookmark, _ resolution: BookmarkResolution, fallbackName: String
    ) {
        var notes: [String] = []
        if resolution.branchFellBack, let branch = bookmark.ref {
            notes.append("The bookmarked branch “\(branch)” is gone or no longer has the file, so \(fallbackName) was opened instead.")
        }
        if resolution.fileMissing, let path = bookmark.path {
            notes.append("The bookmarked file “\(path)” no longer exists, so the repository was opened at its root.")
        }
        guard !notes.isEmpty else { return }
        presentError(title: "Bookmark adjusted", message: notes.joined(separator: "\n\n"))
    }

    // MARK: - Find in page

    @objc func showFind(_ sender: Any?) {
        preview.web.showFindBar()
    }

    @objc func findNextInPage(_ sender: Any?) { preview.web.findNext(sender) }
    @objc func findPreviousInPage(_ sender: Any?) { preview.web.findPrevious(sender) }

    /// Canonical github.com (or GHE) web URL for a repo path at the current
    /// ref; a file:// URL for local sessions.
    private func githubWebURL(path: String, isDirectory: Bool) -> String? {
        if let localRoot = localRootURL {
            return localRoot.appendingPathComponent(path).absoluteString
        }
        guard let session else { return nil }
        let coords = session.coordinates
        let ref = currentPR?.headSHA ?? session.requestedRef ?? session.metadata.defaultBranch
        let marker = isDirectory ? "tree" : "blob"
        let encodedPath = path.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return "https://\(coords.host)/\(coords.owner)/\(coords.repo)/\(marker)/\(ref)/\(encodedPath)"
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
        lastViewedPath = path
        updateURLField(forPath: path)
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
        lastViewedPath = path
        updateURLField(forPath: path)
        Task { await sidebar.reveal(path: path) }
    }

    /// Shows the canonical location of the file currently in the preview.
    /// Remote sessions use a GitHub blob URL; local sessions use the full
    /// filesystem path so the toolbar remains useful as a location field.
    private func updateURLField(forPath path: String) {
        if let localRoot = localRootURL {
            urlField.stringValue = localRoot.appendingPathComponent(path).path
        } else if let url = githubWebURL(path: path, isDirectory: false) {
            urlField.stringValue = url
        }
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
