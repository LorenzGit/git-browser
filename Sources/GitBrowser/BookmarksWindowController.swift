import AppKit
import GitBrowserCore

/// "Edit Bookmarks…" manager: rename, retarget (branch/file), and remove
/// bookmarks. Name, Branch, and File cells edit in place; Location is fixed.
final class BookmarksWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = BookmarksWindowController()

    private let tableView = NSTableView()
    private var bookmarks: [Bookmark] = []

    private enum ColumnID {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let location = NSUserInterfaceItemIdentifier("location")
        static let branch = NSUserInterfaceItemIdentifier("branch")
        static let file = NSUserInterfaceItemIdentifier("file")
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Bookmarks"
        window.center()
        self.init(window: window)

        func makeColumn(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat) -> NSTableColumn {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = width
            return column
        }
        tableView.addTableColumn(makeColumn(ColumnID.name, "Name", width: 180))
        tableView.addTableColumn(makeColumn(ColumnID.location, "Location", width: 170))
        tableView.addTableColumn(makeColumn(ColumnID.branch, "Branch (empty = default)", width: 130))
        tableView.addTableColumn(makeColumn(ColumnID.file, "File (empty = root)", width: 160))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = true

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = NSButton(
            image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
            target: self, action: #selector(removeSelected(_:))
        )
        removeButton.bezelStyle = .smallSquare
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Double-click a cell to edit. ⌘D in the main window adds the current view.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(removeButton)
        content.addSubview(hint)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: removeButton.topAnchor, constant: -8),
            removeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            removeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            removeButton.widthAnchor.constraint(equalToConstant: 28),
            hint.centerYAnchor.constraint(equalTo: removeButton.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 10),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),
        ])
        window.contentView = content

        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged(_:)),
            name: BookmarkStore.changedNotification, object: nil
        )
    }

    func show() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func storeChanged(_ note: Notification) {
        reload()
    }

    private func reload() {
        bookmarks = BookmarkStore.shared.all()
        tableView.reloadData()
    }

    @objc private func removeSelected(_ sender: Any?) {
        let ids = tableView.selectedRowIndexes.compactMap { row in
            row < bookmarks.count ? bookmarks[row].id : nil
        }
        for id in ids {
            BookmarkStore.shared.remove(id: id)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { bookmarks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < bookmarks.count else { return nil }
        let bookmark = bookmarks[row]
        let editable = column.identifier != ColumnID.location

        let cell: NSTableCellView
        let field: NSTextField
        let reuseID = NSUserInterfaceItemIdentifier("cell-\(column.identifier.rawValue)")
        if let reused = tableView.makeView(withIdentifier: reuseID, owner: self) as? NSTableCellView,
           let f = reused.textField {
            cell = reused
            field = f
        } else {
            cell = NSTableCellView()
            cell.identifier = reuseID
            field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingMiddle
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        field.isEditable = editable
        field.isSelectable = true
        field.target = self
        field.action = #selector(cellEdited(_:))

        switch column.identifier {
        case ColumnID.name:
            field.stringValue = bookmark.name
        case ColumnID.location:
            field.stringValue = bookmark.locationDescription
            field.textColor = .secondaryLabelColor
        case ColumnID.branch:
            field.stringValue = bookmark.ref ?? ""
            field.placeholderString = "default"
        case ColumnID.file:
            field.stringValue = bookmark.path ?? ""
            field.placeholderString = "repository root"
        default:
            break
        }
        return cell
    }

    @objc private func cellEdited(_ sender: NSTextField) {
        let row = tableView.row(for: sender)
        let column = tableView.column(for: sender)
        guard row >= 0, row < bookmarks.count, column >= 0 else { return }
        var bookmark = bookmarks[row]
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tableView.tableColumns[column].identifier {
        case ColumnID.name:
            bookmark.name = value.isEmpty ? bookmark.name : value
        case ColumnID.branch:
            bookmark.ref = value.isEmpty ? nil : value
        case ColumnID.file:
            bookmark.path = value.isEmpty ? nil : RepoPath.normalize(value) ?? bookmark.path
        default:
            return
        }
        BookmarkStore.shared.update(bookmark)
    }
}
