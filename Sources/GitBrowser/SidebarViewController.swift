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

        init(entry: DirEntry) {
            self.entry = entry
        }
    }

    /// Fetches the immediate children of a directory path ("" = root).
    var onNeedsChildren: ((String) async throws -> [DirEntry])?
    var onSelectFile: ((String) -> Void)?
    /// Right-click → "Open in New Tab" on a file or directory.
    var onOpenInNewTab: ((String) -> Void)?

    private var rootNodes: [TreeNode] = []
    private var sessionID: String?
    /// True while reveal() adjusts the selection to mirror the preview, so
    /// the resulting selection change doesn't re-open the file.
    private var suppressSelectionCallback = false

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

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
        view = scrollView
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
    }

    func configure(sessionID: String) {
        self.sessionID = sessionID
        rootNodes = []
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
        return sorted.map(TreeNode.init(entry:))
    }

    /// Expands directories down to `path` and selects the final row.
    @MainActor
    func reveal(path: String) async {
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

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TreeNode else { return rootNodes.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TreeNode else { return rootNodes[index] }
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
        cell.imageView?.image = icon(for: node.entry)
        return cell
    }

    private func icon(for entry: DirEntry) -> NSImage? {
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
        let item = NSMenuItem(
            title: "Open in New Tab",
            action: #selector(openInNewTabAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = node.entry.path
        menu.addItem(item)
    }

    @objc private func openInNewTabAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onOpenInNewTab?(path)
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
