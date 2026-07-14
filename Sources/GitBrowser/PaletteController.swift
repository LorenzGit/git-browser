import AppKit
import GitBrowserCore

/// Spotlight-style sheet used by Go to File (⌘P), Search Code (⇧⌘F), and
/// File History: a text field over a result list, arrow keys + return to
/// choose, escape to dismiss.
final class PaletteController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct Row {
        let title: String
        let subtitle: String?
        let payload: String
    }

    enum Source {
        /// All rows known up front; typing filters them fuzzily by `payload`.
        case local(loadAll: () async throws -> [Row])
        /// Rows come from a remote query as the user types (debounced).
        case remote(search: (String) async throws -> [Row])
    }

    private let source: Source
    private let placeholder: String
    private let onChoose: (Row) -> Void

    private var allRows: [Row] = []
    private var visibleRows: [Row] = []
    private var searchTask: Task<Void, Never>?

    private let field = NSTextField()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")

    init(placeholder: String, source: Source, onChoose: @escaping (Row) -> Void) {
        self.placeholder = placeholder
        self.source = source
        self.onChoose = onChoose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))

        field.placeholderString = placeholder
        field.delegate = self
        field.font = .systemFont(ofSize: 15)
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(chooseClicked)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(field)
        container.addSubview(scroll)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
        if case .local(let loadAll) = source {
            statusLabel.stringValue = "Loading…"
            Task { @MainActor in
                do {
                    allRows = try await loadAll()
                    statusLabel.stringValue = "\(allRows.count) items"
                    applyLocalFilter()
                } catch {
                    statusLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Presentation

    /// Presents the palette as a sheet on the given window.
    static func present(
        on window: NSWindow, placeholder: String, source: Source,
        onChoose: @escaping (Row) -> Void
    ) {
        let sheet = NSWindow(contentViewController: PaletteController(
            placeholder: placeholder, source: source, onChoose: onChoose
        ))
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        window.beginSheet(sheet)
    }

    private func dismiss(choosing row: Row?) {
        searchTask?.cancel()
        guard let window = view.window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
        if let row {
            onChoose(row)
        }
    }

    // MARK: - Input

    func controlTextDidChange(_ obj: Notification) {
        let query = field.stringValue
        switch source {
        case .local:
            applyLocalFilter()
        case .remote(let search):
            searchTask?.cancel()
            guard query.trimmingCharacters(in: .whitespaces).count >= 3 else {
                visibleRows = []
                tableView.reloadData()
                statusLabel.stringValue = "Type at least 3 characters"
                return
            }
            statusLabel.stringValue = "Searching…"
            searchTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000) // debounce
                guard let self, !Task.isCancelled else { return }
                do {
                    let rows = try await search(query)
                    guard !Task.isCancelled else { return }
                    self.visibleRows = rows
                    self.tableView.reloadData()
                    self.selectFirstRow()
                    self.statusLabel.stringValue = rows.isEmpty ? "No results" : "\(rows.count) results"
                } catch {
                    self.statusLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    private func applyLocalFilter() {
        let query = field.stringValue
        let ranked = FuzzyMatcher.rank(candidates: allRows.map(\.payload), query: query, limit: 60)
        let byPayload = Dictionary(grouping: allRows, by: \.payload)
        visibleRows = ranked.compactMap { byPayload[$0]?.first }
        tableView.reloadData()
        selectFirstRow()
    }

    private func selectFirstRow() {
        if !visibleRows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            chooseSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(choosing: nil)
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !visibleRows.isEmpty else { return }
        let next = max(0, min(visibleRows.count - 1, tableView.selectedRow + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func chooseSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < visibleRows.count else { return }
        dismiss(choosing: visibleRows[row])
    }

    @objc private func chooseClicked() {
        chooseSelected()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        let title: NSTextField
        let subtitle: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           reused.subviews.count >= 2,
           let t = reused.subviews[0] as? NSTextField,
           let s = reused.subviews[1] as? NSTextField {
            cell = reused
            title = t
            subtitle = s
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            title = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 13)
            title.lineBreakMode = .byTruncatingTail
            subtitle = NSTextField(labelWithString: "")
            subtitle.font = .systemFont(ofSize: 11)
            subtitle.textColor = .secondaryLabelColor
            subtitle.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(title)
            cell.addSubview(subtitle)
            title.translatesAutoresizingMaskIntoConstraints = false
            subtitle.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
                subtitle.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                subtitle.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            ])
        }
        let data = visibleRows[row]
        title.stringValue = data.title
        subtitle.stringValue = data.subtitle ?? ""
        return cell
    }
}
