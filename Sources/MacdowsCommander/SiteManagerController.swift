import AppKit
import MacdowsCore

/// Saved servers: add, edit, delete and connect. Shown as a sheet on a main window.
final class SiteManagerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    enum Result {
        case cancelled
        case saved
        case connect(Site, password: String)
        case localDisk
    }

    private let store: SiteStore
    private var sites: [Site]
    private var passwords: [UUID: String] = [:]
    private var deleted: [UUID] = []
    private var selected: Int
    private var confirmDelete = false
    private var showing = -1
    var onFinish: ((Result) -> Void)?

    private let list = NSTableView()
    private let nameField = NSTextField()
    private let protoPopup = NSPopUpButton()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let pathField = NSTextField()
    private let keyField = NSTextField()
    private let jumpPopup = NSPopUpButton()
    private var keyRow: NSGridRow?
    private var jumpRow: NSGridRow?
    private let modePopup = NSPopUpButton()
    private let encodingPopup = NSPopUpButton()
    private let parallelPopup = NSPopUpButton()
    private let verifyCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let helpLabel = NSTextField(wrappingLabelWithString: "")
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let deleteButton = NSButton()
    private var modeRow: NSGridRow?
    private var encodingRow: NSGridRow?
    private var verifyRow: NSGridRow?

    init(store: SiteStore, currentSiteID: UUID?) {
        self.store = store
        self.sites = store.load()
        self.selected = max(0, sites.firstIndex { $0.id == currentSiteID } ?? 0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        Theme.apply(to: window)
        build()
        if sites.isEmpty { addSite() } else { list.reloadData(); showSelected() }
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    private func label(_ key: String) -> NSTextField {
        let field = NSTextField(labelWithString: L10n.t(key))
        field.alignment = .right
        return field
    }

    private func button(_ key: String, _ action: Selector) -> NSButton {
        NSButton(title: L10n.t(key), target: self, action: action)
    }

    private func build() {
        guard let content = window?.contentView else { return }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("site"))
        column.width = 190
        column.isEditable = false
        list.addTableColumn(column)
        list.headerView = nil
        list.rowHeight = 22
        list.allowsEmptySelection = false
        let listScroll = NSScrollView()
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.widthAnchor.constraint(equalToConstant: 210).isActive = true

        let newButton = button("sites.new", #selector(addSiteAction))
        deleteButton.title = L10n.t("sites.delete")
        deleteButton.target = self
        deleteButton.action = #selector(deleteAction)
        deleteButton.bezelStyle = .rounded
        let listButtons = NSStackView(views: [newButton, deleteButton])

        let left = NSStackView(views: [listScroll, listButtons])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8

        protoPopup.addItems(withTitles: SiteProtocol.allCases.map(\.title))
        protoPopup.target = self
        protoPopup.action = #selector(protocolChanged)
        modePopup.addItems(withTitles: ConnectionMode.allCases.map { L10n.t("mode.\($0.rawValue)") })
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        encodingPopup.addItems(withTitles: [L10n.t("encoding.auto"), "UTF-8", "ISO-8859-9"])
        parallelPopup.addItems(withTitles: ["1", "2", "3", "4", "6", "8"])
        verifyCheck.title = L10n.t("sites.verifyTLS")
        portField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        passwordField.placeholderString = L10n.t("sites.passwordHint")
        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        nameField.delegate = self

        let hostRow = NSStackView(views: [hostField, label("sites.port"), portField])
        hostRow.spacing = 6
        hostField.setContentHuggingPriority(.init(1), for: .horizontal)
        hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        keyField.placeholderString = L10n.t("sites.keyHint")
        keyField.setContentHuggingPriority(.init(1), for: .horizontal)
        let keyStack = NSStackView(views: [keyField, button("sites.keyChoose", #selector(chooseKeyAction))])
        keyStack.spacing = 6

        let grid = NSGridView(views: [
            [label("sites.name"), nameField],
            [label("sites.protocol"), protoPopup],
            [label("sites.host"), hostRow],
            [label("sites.username"), userField],
            [label("sites.password"), passwordField],
            [label("sites.keyFile"), keyStack],
            [label("sites.jump"), jumpPopup],
            [label("sites.folder"), pathField],
            [label("sites.mode"), modePopup],
            [label("sites.encoding"), encodingPopup],
            [label("sites.parallel"), parallelPopup],
            [NSGridCell.emptyContentView, verifyCheck],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 400
        keyRow = grid.row(at: 5)
        jumpRow = grid.row(at: 6)
        modeRow = grid.row(at: 8)
        encodingRow = grid.row(at: 9)
        verifyRow = grid.row(at: 11)
        for index in [1, 6, 8, 9, 10] { grid.cell(atColumnIndex: 1, rowIndex: index).xPlacement = .leading }

        helpLabel.font = .systemFont(ofSize: 11)
        helpLabel.textColor = .secondaryLabelColor
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .systemOrange
        warningLabel.stringValue = L10n.t("sites.plainWarning")

        let right = NSStackView(views: [grid, helpLabel, warningLabel])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        helpLabel.preferredMaxLayoutWidth = 480
        warningLabel.preferredMaxLayoutWidth = 480

        let body = NSStackView(views: [left, right])
        body.alignment = .top
        body.spacing = 16
        listScroll.heightAnchor.constraint(equalToConstant: 340).isActive = true

        let local = button("sites.localDisk", #selector(localAction))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let cancel = button("common.cancel", #selector(cancelAction))
        cancel.keyEquivalent = "\u{1b}"
        let save = button("sites.save", #selector(saveAction))
        let connect = button("sites.connect", #selector(connectAction))
        connect.keyEquivalent = "\r"
        let buttons = NSStackView(views: [local, spacer, cancel, save, connect])

        let root = NSStackView(views: [body, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        ])
        // Last, because the list reports its first selection as soon as it has a data source,
        // and showing that site needs the form to exist.
        list.dataSource = self
        list.delegate = self
    }

    // MARK: Form

    private func showSelected() {
        guard sites.indices.contains(selected) else { return }
        showing = selected
        let site = sites[selected]
        list.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        nameField.stringValue = site.name
        protoPopup.selectItem(at: SiteProtocol.allCases.firstIndex(of: site.proto) ?? 0)
        hostField.stringValue = site.host
        portField.stringValue = String(site.port)
        userField.stringValue = site.user
        passwordField.stringValue = passwords[site.id] ?? store.password(for: site.id)
        pathField.stringValue = site.path
        keyField.stringValue = site.keyFile ?? ""
        reloadJumpChoices(for: site)
        modePopup.selectItem(at: ConnectionMode.allCases.firstIndex(of: site.mode) ?? 0)
        encodingPopup.selectItem(at: NameEncoding.allCases.firstIndex(of: site.encoding) ?? 0)
        parallelPopup.selectItem(withTitle: String(site.parallel))
        if parallelPopup.selectedItem == nil { parallelPopup.selectItem(withTitle: "2") }
        verifyCheck.state = site.verifyTLS ? .on : .off
        confirmDelete = false
        deleteButton.title = L10n.t("sites.delete")
        updateProtocolRows()
    }

    private func readForm() {
        guard sites.indices.contains(showing) else { return }
        var site = sites[showing]
        site.name = nameField.stringValue.isEmpty ? L10n.t("sites.untitled") : nameField.stringValue
        site.proto = SiteProtocol.allCases[protoPopup.indexOfSelectedItem]
        site.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        site.port = Int(portField.stringValue) ?? site.proto.defaultPort
        site.user = userField.stringValue
        site.path = pathField.stringValue.isEmpty ? "/" : pathField.stringValue
        let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
        site.keyFile = site.proto == .ssh && !key.isEmpty ? key : nil
        site.jumpSiteID = site.proto == .ssh ? jumpPopup.selectedItem?.representedObject as? UUID : nil
        site.mode = ConnectionMode.allCases[modePopup.indexOfSelectedItem]
        site.encoding = NameEncoding.allCases[encodingPopup.indexOfSelectedItem]
        site.parallel = Int(parallelPopup.titleOfSelectedItem ?? "2") ?? 2
        site.verifyTLS = verifyCheck.state == .on
        sites[showing] = site
        passwords[site.id] = passwordField.stringValue
    }

    /// Every other saved SSH server can be the way in.
    private func reloadJumpChoices(for site: Site) {
        jumpPopup.removeAllItems()
        jumpPopup.addItem(withTitle: L10n.t("sites.jumpNone"))
        for other in sites where other.proto == .ssh && other.id != site.id {
            jumpPopup.addItem(withTitle: other.name)
            jumpPopup.lastItem?.representedObject = other.id
            if other.id == site.jumpSiteID { jumpPopup.select(jumpPopup.lastItem) }
        }
    }

    @objc private func chooseKeyAction() {
        guard let sheet = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.beginSheetModal(for: sheet) { [weak self] response in
            if response == .OK, let url = panel.url { self?.keyField.stringValue = url.path }
        }
    }

    private func updateProtocolRows() {
        let proto = SiteProtocol.allCases[protoPopup.indexOfSelectedItem]
        keyRow?.isHidden = proto != .ssh
        jumpRow?.isHidden = proto != .ssh
        modeRow?.isHidden = proto == .ssh
        encodingRow?.isHidden = proto == .ssh
        verifyRow?.isHidden = proto == .ftp || proto == .ssh
        warningLabel.isHidden = proto != .ftp
        if proto == .ssh {
            helpLabel.stringValue = L10n.t("help.ssh")
        } else {
            helpLabel.stringValue = L10n.t("help.\(ConnectionMode.allCases[modePopup.indexOfSelectedItem].rawValue)")
        }
    }

    @objc private func protocolChanged() {
        let proto = SiteProtocol.allCases[protoPopup.indexOfSelectedItem]
        portField.stringValue = String(proto.defaultPort)
        updateProtocolRows()
    }

    @objc private func modeChanged() { updateProtocolRows() }

    func controlTextDidChange(_ notification: Notification) {
        guard sites.indices.contains(showing) else { return }
        sites[showing].name = nameField.stringValue
        list.reloadData(forRowIndexes: IndexSet(integer: showing), columnIndexes: IndexSet(integer: 0))
    }

    // MARK: List

    func numberOfRows(in tableView: NSTableView) -> Int { sites.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        sites[row].name
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = list.selectedRow
        guard row >= 0, row != showing else { return }
        readForm()
        selected = row
        showSelected()
    }

    private func addSite() {
        readForm()
        sites.append(Site(name: L10n.t("sites.untitled"), proto: .ftp))
        selected = sites.count - 1
        list.reloadData()
        showSelected()
        window?.makeFirstResponder(nameField)
    }

    @objc private func addSiteAction() { addSite() }

    @objc private func deleteAction() {
        guard sites.indices.contains(selected) else { return }
        // A saved server is not removed by one stray click.
        if !confirmDelete {
            confirmDelete = true
            deleteButton.title = L10n.t("sites.confirmDelete")
            return
        }
        deleted.append(sites[selected].id)
        sites.remove(at: selected)
        showing = -1
        if sites.isEmpty {
            selected = 0
            list.reloadData()
            addSite()
            return
        }
        selected = min(selected, sites.count - 1)
        list.reloadData()
        showSelected()
    }

    // MARK: Finish

    private func commit() {
        readForm()
        store.save(sites)
        for (id, password) in passwords { store.setPassword(password, for: id) }
        for id in deleted { store.setPassword("", for: id) }
    }

    private func finish(_ result: Result) {
        guard let sheet = window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
        onFinish?(result)
    }

    @objc private func cancelAction() { finish(.cancelled) }

    @objc private func saveAction() {
        commit()
        finish(.saved)
    }

    @objc private func localAction() { finish(.localDisk) }

    @objc private func connectAction() {
        commit()
        guard sites.indices.contains(showing) else { return }
        let site = sites[showing]
        guard !site.host.isEmpty else {
            NSSound.beep()
            window?.makeFirstResponder(hostField)
            return
        }
        finish(.connect(site, password: passwordField.stringValue))
    }
}
