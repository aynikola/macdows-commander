import AppKit
import MacdowsCore

/// File search over one folder tree, by name and by content. Stays open beside the main window.
final class SearchWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onOpen: ((SearchHit) -> Void)?
    var onClose: (() -> Void)?

    private let source: FileSource
    private let root: String
    private let nameField = NSTextField()
    private let contentField = NSTextField()
    private let caseBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let hiddenBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let startButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = SearchResultsTable()
    private var hits: [SearchHit] = []

    // Shared with the background search.
    private let lock = NSLock()
    private var pending: [SearchHit] = []
    private var currentFolder = ""
    private var cancelled = false
    private var running = false
    private var timer: Timer?

    private static let maximumShown = 20_000

    init(source: FileSource, root: String, rootTitle: String) {
        self.source = source
        self.root = root
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = L10n.t("search.title", rootTitle)
        window.minSize = NSSize(width: 520, height: 320)
        Theme.apply(to: window)
        super.init(window: window)
        window.delegate = self
        window.center()
        buildViews(in: window)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    private func buildViews(in window: NSWindow) {
        guard let content = window.contentView else { return }
        nameField.placeholderString = L10n.t("search.namePlaceholder")
        contentField.placeholderString = L10n.t("search.contentPlaceholder")
        [nameField, contentField].forEach {
            $0.target = self
            $0.action = #selector(fieldReturn)
        }
        let saved = UserDefaults.standard
        nameField.stringValue = saved.string(forKey: "search.name") ?? ""
        contentField.stringValue = saved.string(forKey: "search.content") ?? ""
        caseBox.title = L10n.t("search.caseSensitive")
        caseBox.state = saved.bool(forKey: "search.case") ? .on : .off
        hiddenBox.title = L10n.t("search.hidden")
        hiddenBox.state = (saved.object(forKey: "search.hidden") as? Bool ?? true) ? .on : .off
        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(startOrStop)
        startButton.keyEquivalent = "\r"
        startButton.title = L10n.t("search.start")

        let nameLabel = NSTextField(labelWithString: L10n.t("search.name"))
        let contentLabel = NSTextField(labelWithString: L10n.t("search.content"))
        let grid = NSGridView(views: [[nameLabel, nameField], [contentLabel, contentField]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        let options = NSStackView(views: [caseBox, hiddenBox, NSView(), startButton])
        options.spacing = 14

        statusLabel.font = AppFont.interface(12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.stringValue = L10n.t("search.help")

        let columns: [(String, String, CGFloat)] = [
            ("name", "search.columnName", 200),
            ("folder", "search.columnFolder", 260),
            ("line", "search.columnLine", 56),
            ("text", "search.columnText", 280),
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = L10n.t(title)
            column.width = width
            column.isEditable = false
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onReturn = { [weak self] in self?.openSelected() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        [grid, options, statusLabel, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            options.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
            options.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            options.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        window.initialFirstResponder = nameField
    }

    @objc private func fieldReturn() { if !running { startOrStop() } }

    // Esc stops a running search, then closes the window.
    override func cancelOperation(_ sender: Any?) {
        if running { stop() } else { window?.performClose(nil) }
    }

    @objc private func startOrStop() {
        if running { stop() } else { start() }
    }

    private func stop() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private func start() {
        let options = SearchOptions(namePattern: nameField.stringValue, content: contentField.stringValue, caseSensitive: caseBox.state == .on, includeHidden: hiddenBox.state == .on)
        let saved = UserDefaults.standard
        saved.set(options.namePattern, forKey: "search.name")
        saved.set(options.content, forKey: "search.content")
        saved.set(options.caseSensitive, forKey: "search.case")
        saved.set(options.includeHidden, forKey: "search.hidden")

        hits = []
        table.reloadData()
        running = true
        cancelled = false
        startButton.title = L10n.t("search.stop")
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.flush() }

        let source = source
        let root = root
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let summary = FileSearcher.run(source: source, root: root, options: options, isCancelled: { [weak self] in
                guard let self else { return true }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.cancelled
            }, onFolder: { [weak self] folder in
                guard let self else { return }
                self.lock.lock(); self.currentFolder = folder; self.lock.unlock()
            }, onHit: { [weak self] hit in
                guard let self else { return }
                self.lock.lock(); self.pending.append(hit); self.lock.unlock()
            })
            DispatchQueue.main.async { self?.finished(summary) }
        }
    }

    private func flush() {
        lock.lock()
        let fresh = pending
        pending = []
        let folder = currentFolder
        lock.unlock()
        if !fresh.isEmpty && hits.count < Self.maximumShown {
            let hadSelection = table.selectedRow >= 0
            hits.append(contentsOf: fresh.prefix(Self.maximumShown - hits.count))
            table.reloadData()
            if !hadSelection { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        }
        if running { statusLabel.stringValue = L10n.t("search.progress", String(hits.count), folder) }
    }

    private func finished(_ summary: SearchSummary) {
        flush()
        timer?.invalidate()
        timer = nil
        running = false
        startButton.title = L10n.t("search.start")
        var parts = [L10n.t(summary.cancelled ? "search.stopped" : "search.done", String(summary.hits), String(summary.folders))]
        if summary.hits > Self.maximumShown { parts.append(L10n.t("search.limited", String(Self.maximumShown))) }
        if summary.skippedBinary > 0 { parts.append(L10n.t("search.skippedBinary", String(summary.skippedBinary))) }
        if summary.skippedLarge > 0 { parts.append(L10n.t("search.skippedLarge", String(summary.skippedLarge))) }
        if summary.unreadable > 0 { parts.append(L10n.t("search.unreadable", String(summary.unreadable))) }
        statusLabel.stringValue = parts.joined(separator: " · ")
        if !hits.isEmpty { window?.makeFirstResponder(table) }
    }

    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < hits.count else { return }
        onOpen?(hits[row])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < hits.count else { return nil }
        let field = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let made = NSTextField(labelWithString: "")
            made.identifier = id
            made.lineBreakMode = .byTruncatingMiddle
            made.font = AppFont.interface(13)
            return made
        }()
        let hit = hits[row]
        switch id.rawValue {
        case "name": field.stringValue = hit.entry.name
        case "folder": field.stringValue = hit.directory
        case "line": field.stringValue = hit.line.map(String.init) ?? ""
        default: field.stringValue = hit.snippet ?? ""
        }
        return field
    }

    func windowWillClose(_ notification: Notification) {
        stop()
        timer?.invalidate()
        timer = nil
        onClose?()
    }
}

private final class SearchResultsTable: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}
