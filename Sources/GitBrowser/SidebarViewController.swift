import AppKit
import GitBrowserCore

/// Repository tree sidebar. Strictly lazy: only the root listing is fetched
/// when a repository opens, and each directory's children are fetched the
/// first time the user expands it. Results stay in memory for the session
/// (inside RepoSession) and are discarded when it closes.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    final class TreeNode {
        let entry: DirEntry
        var children: [TreeNode]?
        var isLoading = false
        /// Set for rows in the PR-changes list (added/modified/removed/…).
        var prStatus: String?

        init(entry: DirEntry, prStatus: String? = nil) {
            self.entry = entry
            self.prStatus = prStatus
        }
    }

    private enum Mode {
        case tree
        case prChanges
    }

    /// Fetches the immediate children of a directory path ("" = root).
    var onNeedsChildren: ((String) async throws -> [DirEntry])?
    var onSelectFile: ((String) -> Void)?
    /// Right-click → "Open in New Tab" on a file or directory.
    var onOpenInNewTab: ((String) -> Void)?
    /// Right-click context actions that need repo/session context.
    /// The Bool is true for directories.
    var onCopyLink: ((String, Bool) -> Void)?
    var onOpenOnGitHub: ((String, Bool) -> Void)?
    var onShowHistory: ((String) -> Void)?
    /// A directory row was clicked (children may load lazily afterwards).
    var onSelectDirectory: ((String) -> Void)?

    private var rootNodes: [TreeNode] = []
    private var prNodes: [TreeNode] = []
    private var mode: Mode = .tree
    private var sessionID: String?
    /// True while reveal() adjusts the selection to mirror the preview, so
    /// the resulting selection change doesn't re-open the file.
    private var suppressSelectionCallback = false

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let modeSwitcher = NSSegmentedControl(
        labels: ["Files", "PR Changes"], trackingMode: .selectOne, target: nil, action: nil
    )

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Files"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)

        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        modeSwitcher.target = self
        modeSwitcher.action = #selector(modeSwitched(_:))
        modeSwitcher.segmentStyle = .capsule
        modeSwitcher.selectedSegment = 0
        modeSwitcher.isHidden = true
        modeSwitcher.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Stack view detaches hidden views, so the switcher takes no space
        // until a PR session makes it visible.
        let stack = NSStackView(views: [modeSwitcher, scrollView])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        view = stack
    }

    func configure(sessionID: String) {
        self.sessionID = sessionID
        rootNodes = []
        prNodes = []
        mode = .tree
        modeSwitcher.isHidden = true
        modeSwitcher.selectedSegment = 0
        outlineView.reloadData()
    }

    /// Enables PR mode: a flat changed-files list alongside the normal tree.
    func showPRChanges(_ files: [PullRequestFile]) {
        prNodes = files.map { file in
            TreeNode(
                entry: DirEntry(name: file.path, path: file.path, type: .file, size: 0),
                prStatus: file.status
            )
        }
        modeSwitcher.isHidden = false
        modeSwitcher.selectedSegment = 1
        mode = .prChanges
        outlineView.reloadData()
    }

    @objc private func modeSwitched(_ sender: NSSegmentedControl) {
        mode = sender.selectedSegment == 1 ? .prChanges : .tree
        outlineView.reloadData()
    }

    @MainActor
    func reloadRoot() async {
        guard let onNeedsChildren else { return }
        do {
            let entries = try await onNeedsChildren("")
            rootNodes = Self.nodes(from: entries)
            outlineView.reloadData()
        } catch {
            rootNodes = []
            outlineView.reloadData()
        }
    }

    private static func nodes(from entries: [DirEntry]) -> [TreeNode] {
        // Directories first, then files, both alphabetically (like GitHub).
        let sorted = entries.sorted { a, b in
            if (a.type == .dir) != (b.type == .dir) { return a.type == .dir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return sorted.map { TreeNode(entry: $0) }
    }

    /// Expands directories down to `path` and selects the final row.
    @MainActor
    func reveal(path: String) async {
        guard mode == .tree else { return }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }
        var currentLevel = rootNodes
        var walked: [String] = []

        for (index, component) in components.enumerated() {
            walked.append(component)
            guard let node = currentLevel.first(where: { $0.entry.name == component }) else { return }
            let isLast = index == components.count - 1
            if isLast {
                let row = outlineView.row(forItem: node)
                if row >= 0 {
                    suppressSelectionCallback = true
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    suppressSelectionCallback = false
                    outlineView.scrollRowToVisible(row)
                }
                return
            }
            guard node.entry.type == .dir else { return }
            if node.children == nil {
                await loadChildren(of: node)
            }
            outlineView.animator().expandItem(node)
            currentLevel = node.children ?? []
        }
    }

    @MainActor
    private func loadChildren(of node: TreeNode) async {
        guard node.children == nil, !node.isLoading, let onNeedsChildren else { return }
        node.isLoading = true
        do {
            let entries = try await onNeedsChildren(node.entry.path)
            node.children = Self.nodes(from: entries)
        } catch {
            node.children = []
        }
        node.isLoading = false
        outlineView.reloadItem(node, reloadChildren: true)
    }

    // MARK: - Data source (lazy)

    private var topLevelNodes: [TreeNode] {
        mode == .tree ? rootNodes : prNodes
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TreeNode else { return topLevelNodes.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TreeNode else { return topLevelNodes[index] }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TreeNode)?.entry.type == .dir
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? TreeNode,
              node.children == nil
        else { return }
        Task { await loadChildren(of: node) }
    }

    // MARK: - Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(image)
            cell.addSubview(text)
            cell.imageView = image
            cell.textField = text
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = node.entry.name
        cell.imageView?.image = icon(for: node)
        return cell
    }

    private func icon(for node: TreeNode) -> NSImage? {
        // PR-changes rows show their change status instead of the file type.
        if let status = node.prStatus {
            let (name, color): (String, NSColor) = {
                switch status {
                case "added": return ("plus.circle.fill", .systemGreen)
                case "removed": return ("minus.circle.fill", .systemRed)
                case "renamed", "copied": return ("arrow.right.circle.fill", .systemBlue)
                default: return ("pencil.circle.fill", .systemOrange)
                }
            }()
            return NSImage(systemSymbolName: name, accessibilityDescription: status)?
                .withSymbolConfiguration(.init(paletteColors: [color]))
        }
        let entry = node.entry
        let name: String
        let color: NSColor
        switch entry.type {
        case .dir: (name, color) = ("folder.fill", .systemBlue)
        case .submodule: (name, color) = ("shippingbox.fill", .systemBrown)
        case .symlink: (name, color) = ("link", .systemGray)
        default:
            switch PreviewRouter.kind(forPath: entry.path) {
            case .html: (name, color) = ("chevron.left.forwardslash.chevron.right", .systemOrange)
            case .markdown: (name, color) = ("m.square.fill", .systemIndigo)
            case .image: (name, color) = ("photo.fill", .systemPurple)
            case .media: (name, color) = ("play.rectangle.fill", .systemPink)
            case .pdf: (name, color) = ("doc.richtext.fill", .systemRed)
            case .code: (name, color) = ("curlybraces", .systemTeal)
            }
        }
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        return NSImage(systemSymbolName: name, accessibilityDescription: entry.type.rawValue)?
            .withSymbolConfiguration(configuration)
    }

    // MARK: - Selection

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TreeNode else { return }
        if node.entry.type == .dir {
            if outlineView.isItemExpanded(node) {
                outlineView.animator().collapseItem(node)
            } else {
                outlineView.animator().expandItem(node)
                onSelectDirectory?(node.entry.path)
            }
        } else if node.entry.type == .file {
            onSelectFile?(node.entry.path)
        }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? TreeNode,
              node.entry.type == .file || node.entry.type == .dir
        else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }

        add("Open in New Tab", #selector(openInNewTabAction(_:)))
        if node.entry.type == .file {
            add("History…", #selector(showHistoryAction(_:)))
        }
        menu.addItem(.separator())
        add("Copy GitHub Link", #selector(copyLinkAction(_:)))
        add("Copy Path", #selector(copyPathAction(_:)))
        add("Open on GitHub", #selector(openOnGitHubAction(_:)))
    }

    private func contextNode(_ sender: NSMenuItem) -> TreeNode? {
        sender.representedObject as? TreeNode
    }

    @objc private func openInNewTabAction(_ sender: NSMenuItem) {
        contextNode(sender).map { onOpenInNewTab?($0.entry.path) }
    }

    @objc private func showHistoryAction(_ sender: NSMenuItem) {
        contextNode(sender).map { onShowHistory?($0.entry.path) }
    }

    @objc private func copyLinkAction(_ sender: NSMenuItem) {
        contextNode(sender).map { onCopyLink?($0.entry.path, $0.entry.type == .dir) }
    }

    @objc private func copyPathAction(_ sender: NSMenuItem) {
        guard let node = contextNode(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.entry.path, forType: .string)
    }

    @objc private func openOnGitHubAction(_ sender: NSMenuItem) {
        contextNode(sender).map { onOpenOnGitHub?($0.entry.path, $0.entry.type == .dir) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TreeNode,
              node.entry.type == .file
        else { return }
        onSelectFile?(node.entry.path)
    }
}
