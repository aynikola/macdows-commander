import AppKit
import UniformTypeIdentifiers
import MacdowsCore

final class PanelTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    var onFocusChange: (() -> Void)?
    var onCommandClick: ((Int) -> Void)?
    var onRightClick: ((Int) -> Void)?
    var onShiftClick: ((Int) -> Void)?
    var onSelectAll: (() -> Void)?

    /// ⌘A from the menu arrives here.
    override func selectAll(_ sender: Any?) { onSelectAll?() }

    /// False keeps the muted color, for the panel without the keyboard.
    var isActivePanel = false

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    /// The selection is painted here because cells, left to themselves, draw a grey one over it.
    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        (isActivePanel ? Theme.accent : Theme.selectionMuted).setFill()
        for row in selectedRowIndexes where rect(ofRow: row).intersects(clipRect) {
            rect(ofRow: row).fill()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?() }
        return accepted
    }

    /// Right click marks like Ins, as in Windows Commander.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked >= 0 { onRightClick?(clicked) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        if event.modifierFlags.contains(.shift) {
            window?.makeFirstResponder(self)
            let clicked = row(at: convert(event.locationInWindow, from: nil))
            if clicked >= 0 { onShiftClick?(clicked) }
            return
        }
        if event.modifierFlags.contains(.command) {
            window?.makeFirstResponder(self)
            let clicked = row(at: convert(event.locationInWindow, from: nil))
            if clicked >= 0 { onCommandClick?(clicked) }
            return
        }
        super.mouseDown(with: event)
    }
}

/// Column titles on the cream surface instead of the system's white.
private final class ThemedHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.surface.setFill()
        cellFrame.fill()
        Theme.border.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 4, width: 1, height: cellFrame.height - 8).fill()
        // One centered line: the system's header drawing would wrap long titles when given the whole cell.
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font ?? .systemFont(ofSize: 11)))
        var line = cellFrame
        line.origin.y += (cellFrame.height - lineHeight) / 2
        line.size.height = lineHeight
        drawInterior(withFrame: line, in: controlView)
    }
}

final class PanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String { case icon, name, size, date, permissions, owner }

    let table = PanelTableView()
    let view = NSView()
    let siteButton = NSButton()
    var onActivate: (() -> Void)?
    var onOpen: ((FileEntry) -> Void)?
    var onError: ((String) -> Void)?
    var onPathChange: (() -> Void)?

    private(set) var source: FileSource = LocalSource()
    private(set) var site: Site?
    private(set) var path: String
    private(set) var rows: [FileEntry] = []
    private(set) var marked = Set<String>()
    private var all: [FileEntry] = []
    private var computedSizes: [String: Int64] = [:]
    private var loadToken = 0
    private let queue = DispatchQueue(label: "macdows.panel", qos: .userInitiated)
    private var sortKey = "name"
    private var ascending = true

    private let header = NSView()
    private let badge = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var isLoading = false
    private var isFitting = false

    var showHidden = true { didSet { rebuild(keeping: cursorEntry?.name) } }
    var showAttributes: Bool { didSet { applyAttributeColumns() } }

    init(path: String, showAttributes: Bool) {
        self.path = path
        self.showAttributes = showAttributes
        super.init()
        buildViews()
    }

    var isActive: Bool { table.window?.firstResponder === table }

    var cursorEntry: FileEntry? {
        let row = table.selectedRow
        return row >= 0 && row < rows.count ? rows[row] : nil
    }

    /// Marked items, or the item under the cursor when nothing is marked.
    var selection: [FileEntry] {
        let picked = rows.filter { marked.contains($0.name) }
        if !picked.isEmpty { return picked }
        if let cursor = cursorEntry, cursor.name != ".." { return [cursor] }
        return []
    }

    var badgeTitle: String {
        if isInArchive { return L10n.t("panel.archive") }
        return site?.proto.badge ?? L10n.t("panel.local")
    }

    /// Where ".." goes from the top of an archive. Archives inside archives chain through `previous`.
    private final class ArchiveReturn {
        let source: FileSource
        let site: Site?
        let path: String
        let name: String
        let previous: ArchiveReturn?
        init(source: FileSource, site: Site?, path: String, name: String, previous: ArchiveReturn?) {
            self.source = source
            self.site = site
            self.path = path
            self.name = name
            self.previous = previous
        }
    }

    private var archiveReturn: ArchiveReturn?
    var isInArchive: Bool { archiveReturn != nil }

    // MARK: Views

    private func buildViews() {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.borderWidth = 2

        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true

        badge.font = AppFont.interface(11, bold: true)
        pathLabel.font = AppFont.interface(AppFont.size - 1)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        siteButton.bezelStyle = .rounded
        siteButton.controlSize = .small
        siteButton.refusesFirstResponder = true
        siteButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerStack = NSStackView(views: [badge, pathLabel, siteButton])
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        header.addSubview(headerStack)

        table.style = .plain
        table.rowHeight = AppFont.rowHeight
        // jumpToName replaces it: the built-in one reads a repeated letter as "aa" instead of moving on.
        table.allowsTypeSelect = false
        table.intercellSpacing = NSSize(width: 6, height: 1)
        table.gridStyleMask = []
        table.focusRingType = .none
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.allowsColumnReordering = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onFocusChange = { [weak self] in self?.onActivate?() }
        table.onCommandClick = { [weak self] row in self?.toggleMark(at: row, advance: false) }
        table.onShiftClick = { [weak self] row in self?.markRange(to: row) }
        table.onSelectAll = { [weak self] in self?.markAll() }
        table.onRightClick = { [weak self] row in
            self?.moveCursor(to: row)
            self?.toggleMark(at: row, advance: false)
        }

        addColumn(.icon, width: 18, resizable: false)
        addColumn(.name, width: 240, resizable: true, sortKey: "name")
        addColumn(.size, width: 78, resizable: true, sortKey: "size", right: true, mono: true)
        addColumn(.date, width: 124, resizable: true, sortKey: "date", mono: true)
        addColumn(.permissions, width: 84, resizable: true, mono: true)
        addColumn(.owner, width: 70, resizable: true)
        fitColumnsToFont()
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        applyAttributeColumns()
        relabelColumns()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(fontChanged), name: .appFontChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .themeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollAreaResized), name: NSView.frameDidChangeNotification, object: scroll.contentView)

        status.font = AppFont.interface(12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(scroll)
        view.addSubview(status)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            header.heightAnchor.constraint(equalToConstant: 32),
            headerStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
        ])
        refreshChrome()
    }

    private func addColumn(_ column: Column, width: CGFloat, resizable: Bool, sortKey: String? = nil, right: Bool = false, mono: Bool = false) {
        let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        let header = ThemedHeaderCell(textCell: "")
        header.font = item.headerCell.font
        header.alignment = right ? .right : .left
        header.textColor = Theme.text
        header.wraps = false
        header.lineBreakMode = .byTruncatingTail
        item.headerCell = header
        item.width = width
        if !resizable {
            item.minWidth = width
            item.maxWidth = width
            item.resizingMask = []
            let cell = NSImageCell()
            cell.imageScaling = .scaleProportionallyDown
            item.dataCell = cell
        } else {
            item.minWidth = 40
            item.resizingMask = column == .name ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            let cell = NSTextFieldCell()
            cell.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
            cell.alignment = right ? .right : .left
            cell.font = mono ? AppFont.digits : AppFont.list()
            item.dataCell = cell
        }
        if let sortKey { item.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: true) }
        // Editable columns would swallow double clicks to start renaming in place.
        item.isEditable = false
        table.addTableColumn(item)
        table.columnAutoresizingStyle = .noColumnAutoresizing
    }

    /// The name column takes whatever width the other columns leave.
    private func fitColumns() {
        guard !isFitting, let width = table.enclosingScrollView?.contentView.bounds.width, width > 0 else { return }
        isFitting = true
        defer { isFitting = false }
        var others: CGFloat = 0
        var nameColumn: NSTableColumn?
        var visible: CGFloat = 0
        for column in table.tableColumns where !column.isHidden {
            visible += 1
            if column.identifier.rawValue == Column.name.rawValue { nameColumn = column } else { others += column.width }
        }
        nameColumn?.width = max(80, width - others - visible * table.intercellSpacing.width - 2)
    }

    func tableViewColumnDidResize(_ notification: Notification) { fitColumns() }

    @objc private func scrollAreaResized() { fitColumns() }

    private func relabelColumns() {
        let titles: [Column: String] = [.icon: "", .name: L10n.t("column.name"), .size: L10n.t("column.size"), .date: L10n.t("column.date"), .permissions: L10n.t("column.permissions"), .owner: L10n.t("column.owner")]
        for column in table.tableColumns {
            if let kind = Column(rawValue: column.identifier.rawValue) { column.title = titles[kind] ?? "" }
        }
    }

    private func applyAttributeColumns() {
        for column in table.tableColumns where column.identifier.rawValue == Column.permissions.rawValue || column.identifier.rawValue == Column.owner.rawValue {
            column.isHidden = !showAttributes
        }
        fitColumns()
    }

    /// Wider fonts must not cut dates and sizes short.
    private func fitColumnsToFont() {
        let samples: [(Column, String)] = [(.size, "999,9 MB"), (.date, "00.00.0000 00:00"), (.permissions, "drwxr-xr-x")]
        for (column, sample) in samples {
            let width = ceil((sample as NSString).size(withAttributes: [.font: AppFont.digits]).width) + 12
            table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))?.width = width
        }
        fitColumns()
    }

    private var jumpPrefix = ""
    private var jumpTime = Date.distantPast

    @objc private func themeChanged() {
        refreshChrome()
        table.needsDisplay = true
        table.headerView?.needsDisplay = true
    }

    @objc private func fontChanged() {
        pathLabel.font = AppFont.interface(AppFont.size - 1)
        badge.font = AppFont.interface(11, bold: true)
        status.font = AppFont.interface(12)
        table.rowHeight = AppFont.rowHeight
        fitColumnsToFont()
        for column in table.tableColumns {
            guard let cell = column.dataCell as? NSTextFieldCell else { continue }
            cell.font = column.identifier.rawValue == Column.name.rawValue ? AppFont.list() : AppFont.digits
        }
        table.reloadData()
    }

    func relabel() {
        relabelColumns()
        refreshChrome()
        updateStatus()
        table.reloadData()
    }

    /// Colors that say which panel keys go to.
    func refreshChrome() {
        let active = isActive
        table.isActivePanel = active
        view.layer?.borderColor = Theme.resolved(active ? Theme.accent : Theme.border).cgColor
        header.layer?.backgroundColor = (active ? Theme.resolved(Theme.accent) : NSColor.clear).cgColor
        badge.textColor = active ? Theme.onAccent : Theme.secondaryText
        pathLabel.textColor = active ? Theme.onAccent : Theme.secondaryText
        badge.stringValue = badgeTitle
        if let archiveReturn {
            pathLabel.stringValue = archiveReturn.name + (path == "/" ? "" : path)
        } else {
            pathLabel.stringValue = path
        }
        if let site {
            var title = site.name
            if let ftp = source as? FTPClient, site.mode == .auto {
                title += ftp.currentMode == .auto ? "" : " · \(L10n.t("mode.\(ftp.currentMode.rawValue)"))"
            } else if site.proto != .ssh {
                title += " · \(L10n.t("mode.\(site.mode.rawValue)"))"
            }
            siteButton.title = title
        } else {
            siteButton.title = L10n.t("panel.connect")
            siteButton.toolTip = "⌘K"
        }
    }

    // MARK: Loading

    func connect(site: Site?, source: FileSource, path: String, completion: ((Error?) -> Void)? = nil) {
        switchSource(site: site, source: source, path: path, archive: nil, select: nil, completion: completion)
    }

    /// Opens an archive like a folder. Going up from its top returns to where it was opened.
    func enterArchive(_ archive: ArchiveSource, name: String, completion: ((Error?) -> Void)? = nil) {
        let back = ArchiveReturn(source: source, site: site, path: path, name: name, previous: archiveReturn)
        switchSource(site: nil, source: archive, path: "/", archive: back, select: nil, completion: completion)
    }

    func leaveArchive() {
        guard let back = archiveReturn else { return }
        switchSource(site: back.site, source: back.source, path: back.path, archive: back.previous, select: back.name, completion: nil)
    }

    private func switchSource(site: Site?, source: FileSource, path: String, archive: ArchiveReturn?, select: String?, completion: ((Error?) -> Void)?) {
        let previous = (self.source, self.site, self.path, self.archiveReturn)
        self.source = source
        self.site = site
        self.archiveReturn = archive
        marked.removeAll()
        load(path: path, select: select) { [weak self] error in
            if let error, let self {
                self.source = previous.0
                self.site = previous.1
                self.path = previous.2
                self.archiveReturn = previous.3
                self.refreshChrome()
                if completion == nil { self.onError?(error.localizedDescription) }
            }
            completion?(error)
        }
    }

    func load(path newPath: String, select: String?, completion: ((Error?) -> Void)? = nil) {
        loadToken += 1
        let token = loadToken
        isLoading = true
        updateStatus()
        let currentSource = source
        queue.async { [weak self] in
            do {
                let entries = try currentSource.list(newPath)
                DispatchQueue.main.async {
                    guard let self, self.loadToken == token else { return }
                    if newPath != self.path {
                        self.marked.removeAll()
                        self.computedSizes.removeAll()
                        // A new folder starts at the top, not at the old row number.
                        self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    }
                    self.path = newPath
                    self.all = entries
                    self.isLoading = false
                    self.rebuild(keeping: select)
                    self.refreshChrome()
                    self.onPathChange?()
                    completion?(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.loadToken == token else { return }
                    self.isLoading = false
                    self.updateStatus()
                    if let completion { completion(error) } else { self.onError?(error.localizedDescription) }
                }
            }
        }
    }

    func reload(completion: ((Error?) -> Void)? = nil) {
        load(path: path, select: cursorEntry?.name, completion: completion)
    }

    private func rebuild(keeping name: String?) {
        let index = max(0, table.selectedRow)
        var visible = showHidden ? all : all.filter { !$0.isHidden }
        let key = sortKey
        let ascending = ascending
        visible.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: Bool
            switch key {
            case "size" where a.size != b.size: order = a.size < b.size
            case "date" where a.date != b.date: order = (a.date ?? .distantPast) < (b.date ?? .distantPast)
            default: order = a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ascending ? order : !order
        }
        if path != "/" || isInArchive { visible.insert(FileEntry(name: "..", isDirectory: true), at: 0) }
        rows = visible
        let names = Set(rows.map(\.name))
        marked = marked.intersection(names)
        table.reloadData()
        let target = name.flatMap { wanted in rows.firstIndex { $0.name == wanted } } ?? min(index, max(0, rows.count - 1))
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            table.scrollRowToVisible(target)
        }
        updateStatus()
    }

    private func updateStatus() {
        if isLoading {
            status.stringValue = L10n.t("status.loading")
            return
        }
        let real = rows.filter { $0.name != ".." }
        let size = { (list: [FileEntry]) in list.reduce(Int64(0)) { $0 + (self.computedSizes[$1.name] ?? $1.size) } }
        let picked = real.filter { marked.contains($0.name) }
        if picked.isEmpty {
            status.textColor = .secondaryLabelColor
            status.stringValue = L10n.t("status.items", String(real.count), Format.size(size(real)))
        } else {
            status.textColor = .systemOrange
            status.stringValue = L10n.t("status.marked", String(picked.count), String(real.count), Format.size(size(picked)))
        }
    }

    // MARK: Actions

    func toggleMark(at row: Int, advance: Bool) {
        guard row >= 0, row < rows.count else { return }
        let name = rows[row].name
        if name != ".." {
            if marked.contains(name) { marked.remove(name) } else { marked.insert(name) }
            table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        if advance { moveCursor(to: row + 1) }
        updateStatus()
    }

    /// Pressing a letter goes to the next name starting with it, and the same letter again to the one after.
    /// Different letters typed quickly narrow the search, as in "in" for index.php.
    func jumpToName(typed: String) -> Bool {
        guard let scalar = typed.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar), scalar.value < 0xF700 || scalar.value > 0xF8FF, !rows.isEmpty else { return false }
        let now = Date()
        let isFresh = now.timeIntervalSince(jumpTime) > 1
        jumpTime = now
        var prefix = isFresh ? typed : jumpPrefix + typed
        if !isFresh, prefix.count > 1, Set(prefix) == [Character(typed)] || TextMatcher.hasPrefix(jumpPrefix, typed), jumpPrefix.count == 1 {
            prefix = jumpPrefix
        }
        let current = table.selectedRow
        func search(_ wanted: String, from start: Int) -> Int? {
            (0..<rows.count).lazy.map { (start + $0) % self.rows.count }.first {
                self.rows[$0].name != ".." && TextMatcher.hasPrefix(self.rows[$0].name, wanted)
            }
        }
        // A single letter always moves on; a longer prefix may already be on the right row.
        var found = search(prefix, from: prefix.count == 1 ? current + 1 : max(0, current))
        if found == nil, prefix.count > 1 {
            prefix = typed
            found = search(prefix, from: current + 1)
        }
        jumpPrefix = prefix
        if let found { moveCursor(to: found) }
        return true
    }

    func moveCursor(to row: Int) {
        guard !rows.isEmpty else { return }
        let target = min(max(0, row), rows.count - 1)
        table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        table.scrollRowToVisible(target)
    }

    func select(name: String) {
        if let index = rows.firstIndex(where: { $0.name == name }) { moveCursor(to: index) }
    }

    func activateCursor() {
        guard let entry = cursorEntry else { return }
        if entry.name == ".." {
            goUp()
        } else if entry.isDirectory {
            load(path: PathUtil.join(path, entry.name), select: nil)
        } else {
            onOpen?(entry)
        }
    }

    func goUp() {
        guard path != "/" else { return leaveArchive() }
        load(path: PathUtil.parent(path), select: PathUtil.lastComponent(path))
    }

    /// Shift+click: marks everything from the cursor to the clicked row, and the cursor moves there.
    func markRange(to row: Int) {
        guard row >= 0, row < rows.count else { return }
        let start = table.selectedRow >= 0 ? table.selectedRow : row
        for index in min(start, row)...max(start, row) where rows[index].name != ".." {
            marked.insert(rows[index].name)
        }
        table.reloadData()
        moveCursor(to: row)
        updateStatus()
    }

    /// Ctrl+A or ⌘A: marks everything. Pressed again it clears the marks.
    func markAll() {
        let names = Set(rows.map(\.name).filter { $0 != ".." })
        marked = marked == names ? [] : names
        table.reloadData()
        updateStatus()
    }

    func clearMarks() {
        marked.removeAll()
        table.reloadData()
        updateStatus()
    }

    func setComputedSize(_ size: Int64, for name: String) {
        computedSizes[name] = size
        table.reloadData()
        updateStatus()
    }

    @objc private func doubleClicked() {
        if table.clickedRow >= 0 { activateCursor() }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    private func icon(for entry: FileEntry) -> NSImage {
        let image: NSImage
        if entry.isDirectory {
            image = NSWorkspace.shared.icon(for: .folder)
        } else {
            let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
            image = NSWorkspace.shared.icon(for: type)
        }
        return image
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let entry = rows[row]
        switch Column(rawValue: tableColumn?.identifier.rawValue ?? "") {
        case .icon: return icon(for: entry)
        case .name: return entry.name
        case .size:
            if entry.name == ".." { return "" }
            if entry.isDirectory {
                if let computed = computedSizes[entry.name] { return Format.size(computed) }
                return "<DIR>"
            }
            return Format.size(entry.size)
        case .date: return Format.date(entry.date)
        case .permissions: return entry.permissions ?? ""
        case .owner: return entry.owner ?? ""
        case .none: return nil
        }
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard let text = cell as? NSTextFieldCell, row < rows.count else { return }
        let entry = rows[row]
        let isMarked = marked.contains(entry.name)
        let highlighted = tableView.selectedRow == row && isActive
        if isMarked {
            text.textColor = highlighted ? Theme.markedOnAccent : Theme.marked
        } else if highlighted {
            text.textColor = Theme.onAccent
        } else {
            text.textColor = entry.isHidden && entry.name != ".." ? Theme.hiddenText : Theme.text
        }
        if tableColumn?.identifier.rawValue == Column.name.rawValue {
            text.font = AppFont.list(bold: isMarked)
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let first = tableView.sortDescriptors.first, let key = first.key else { return }
        sortKey = key
        ascending = first.ascending
        rebuild(keeping: cursorEntry?.name)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.setNeedsDisplay(table.visibleRect)
    }
}
