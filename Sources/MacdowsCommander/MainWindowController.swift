import AppKit
import UniformTypeIdentifiers
import MacdowsCore

final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    var onClose: (() -> Void)?

    let left: PanelController
    let right: PanelController
    private let engine = TransferEngine()
    private let store = SiteStore()
    private let favorites = FavoritesStore()
    private let favoriteToggle = NSButton()
    private var favoriteChips: [NSButton] = []
    private var topBar: NSStackView!
    private var queueTimer: Timer?
    private var siteManager: SiteManagerController?
    private var viewers: [NSWindowController] = []
    let terminalPane = TerminalPane()
    private var terminalHeight: NSLayoutConstraint!
    private var terminalGap: NSLayoutConstraint!
    private var keyMonitor: Any?

    private let queueStack = NSStackView()
    private let queueSummary = NSTextField(labelWithString: "")
    private let editorButton = NSButton()
    private let clearButton = NSButton()
    private let cancelButton = NSButton()
    private var functionButtons: [(key: String, labelKey: String, button: NSButton)] = []
    private let hiddenButton = NSButton()
    private let attributesButton = NSButton()
    private let newWindowButton = NSButton()
    private let searchButton = NSButton()
    private let packButton = NSButton()
    private let helpButton = NSButton()
    private let sshButton = NSButton()
    private var searchWindows: [SearchWindowController] = []
    private var packFolders: [URL] = []
    private let toast = NSTextField(labelWithString: "")
    private var toastTimer: Timer?

    // Files downloaded for preview or opening, reused while nothing about them changes.
    private let temporaryRoot: URL
    private let downloadQueue = DispatchQueue(label: "macdows.downloads", qos: .userInitiated)
    private var downloadCache: [String: URL] = [:]
    private var editWatches: [EditWatch] = []
    private var editTimer: Timer?

    private final class EditWatch {
        let url: URL
        let remotePath: String
        let source: FileSource
        let panel: PanelController
        var lastChange: Date?
        init(url: URL, remotePath: String, source: FileSource, panel: PanelController) {
            self.url = url
            self.remotePath = remotePath
            self.source = source
            self.panel = panel
            self.lastChange = MainWindowController.modificationDate(url)
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaults = UserDefaults.standard
        let showHidden = defaults.object(forKey: "showHidden") as? Bool ?? true
        left = PanelController(path: home, showAttributes: false)
        right = PanelController(path: home, showAttributes: true)
        left.showHidden = showHidden
        right.showHidden = showHidden
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacdowsCommander-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = AppVersion.windowTitle
        window.minSize = NSSize(width: 720, height: 480)
        Theme.apply(to: window)
        super.init(window: window)
        window.delegate = self
        // Each new window sits a little lower so stacked ones stay visible.
        window.center()
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x + CGFloat(NSApp.windows.count - 1) * 28, y: window.frame.origin.y - CGFloat(NSApp.windows.count - 1) * 28))

        buildViews(in: window)
        installKeyMonitor()
        wire(left)
        wire(right)
        relabel()
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: .languageChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyInterfaceFonts), name: .appFontChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(favoritesChanged), name: Self.favoritesChangedName, object: nil)
        engine.onBatchFinished = { [weak self] snapshot in self?.batchFinished(snapshot) }

        // open -n "Macdows Commander.app" --args --left <folder> --right <folder>
        let arguments = ProcessInfo.processInfo.arguments
        let startPath = { (flag: String) -> String in
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return home }
            return arguments[index + 1]
        }
        left.load(path: startPath("--left"), select: nil)
        right.load(path: startPath("--right"), select: nil)
        window.makeFirstResponder(left.table)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Layout

    private func topButton(_ button: NSButton, _ action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.refusesFirstResponder = true
        button.target = self
        button.action = action
    }

    private func buildViews(in window: NSWindow) {
        guard let content = window.contentView else { return }

        topButton(hiddenButton, #selector(toggleHiddenFiles(_:)))
        topButton(attributesButton, #selector(toggleAttributes(_:)))
        topButton(newWindowButton, #selector(newWindowClicked))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        topButton(favoriteToggle, #selector(toggleFavoriteClicked))
        topButton(searchButton, #selector(showSearch(_:)))
        topButton(packButton, #selector(packClicked))
        topButton(helpButton, #selector(helpClicked))
        topButton(sshButton, #selector(showSSHMenu(_:)))
        let top = NSStackView(views: [favoriteToggle, spacer, sshButton, helpButton, searchButton, packButton, hiddenButton, attributesButton, newWindowButton])
        top.translatesAutoresizingMaskIntoConstraints = false
        top.spacing = 6
        topBar = top

        let split = NSStackView(views: [left.view, right.view])
        split.distribution = .fillEqually
        split.spacing = 6
        split.translatesAutoresizingMaskIntoConstraints = false

        queueSummary.font = AppFont.interface(12)
        queueSummary.textColor = .secondaryLabelColor
        queueSummary.lineBreakMode = .byTruncatingTail
        queueSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topButton(editorButton, #selector(chooseEditorClicked))
        topButton(clearButton, #selector(clearFinished))
        topButton(cancelButton, #selector(cancelTransfers))
        let queueHeader = NSStackView(views: [queueSummary, NSView(), editorButton, cancelButton, clearButton])
        queueHeader.spacing = 8
        queueStack.orientation = .vertical
        queueStack.alignment = .leading
        queueStack.spacing = 3
        let queue = NSStackView(views: [queueHeader, queueStack])
        queue.orientation = .vertical
        queue.alignment = .leading
        queue.spacing = 3
        queue.translatesAutoresizingMaskIntoConstraints = false

        let definitions: [(String, String, Selector)] = [
            ("F1", "key.favorites", #selector(favoritesClicked)),
            ("Ins", "key.mark", #selector(markClicked)),
            ("Tab", "key.panel", #selector(switchPanelClicked)),
            ("F2", "key.size", #selector(sizeClicked)),
            ("F3", "key.view", #selector(viewClicked)),
            ("F4", "key.edit", #selector(editClicked)),
            ("F5", "key.copy", #selector(copyClicked)),
            ("F6", "key.move", #selector(moveClicked)),
            ("F7", "key.mkdir", #selector(mkdirClicked)),
            ("F8", "key.delete", #selector(deleteClicked)),
            ("F9", "key.terminal", #selector(terminalClicked)),
            ("F10", "key.write", #selector(writerClicked)),
        ]
        var buttons: [NSButton] = []
        for (key, labelKey, action) in definitions {
            let button = NSButton()
            button.bezelStyle = .rounded
            button.refusesFirstResponder = true
            button.target = self
            button.action = action
            functionButtons.append((key, labelKey, button))
            buttons.append(button)
        }
        let bar = NSStackView(views: buttons)
        bar.distribution = .fillEqually
        bar.spacing = 4
        bar.translatesAutoresizingMaskIntoConstraints = false

        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.isHidden = true
        toast.drawsBackground = true
        toast.backgroundColor = Theme.toastBackground
        toast.textColor = Theme.toastText
        toast.alignment = .center
        toast.wantsLayer = true
        toast.layer?.cornerRadius = 6
        toast.layer?.masksToBounds = true
        toast.lineBreakMode = .byTruncatingMiddle

        terminalPane.translatesAutoresizingMaskIntoConstraints = false
        terminalPane.isHidden = true
        terminalPane.onClose = { [weak self] in self?.hideTerminal() }
        terminalPane.onResize = { [weak self] delta in self?.resizeTerminal(by: delta) }
        terminalHeight = terminalPane.heightAnchor.constraint(equalToConstant: 0)
        terminalGap = terminalPane.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 0)

        [top, split, terminalPane, queue, bar, toast].forEach { content.addSubview($0) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            split.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            terminalGap,
            terminalHeight,
            terminalPane.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            terminalPane.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            queue.topAnchor.constraint(equalTo: terminalPane.bottomAnchor, constant: 6),
            queue.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            queue.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            queueHeader.widthAnchor.constraint(equalTo: queue.widthAnchor),
            queueStack.widthAnchor.constraint(equalTo: queue.widthAnchor),
            bar.topAnchor.constraint(equalTo: queue.bottomAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            toast.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: queue.topAnchor, constant: -12),
            toast.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -80),
        ])
    }

    private func wire(_ panel: PanelController) {
        panel.table.onKey = { [weak self, weak panel] event in
            guard let self, let panel else { return false }
            return self.handleKey(event, panel: panel)
        }
        panel.onActivate = { [weak self] in self?.refreshActive() }
        panel.onOpen = { [weak self, weak panel] entry in
            guard let self, let panel else { return }
            if let kind = ArchiveKind.detect(entry.name) {
                self.openArchive(entry, kind: kind, in: panel)
            } else {
                self.askToOpen(entry, in: panel)
            }
        }
        panel.onError = { [weak self] message in self?.showError(message) }
        panel.onPathChange = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.panelPathChanged(panel)
        }
        panel.siteButton.target = self
        panel.siteButton.action = panel === left ? #selector(leftSiteClicked) : #selector(rightSiteClicked)
    }

    @objc private func languageChanged() { relabel() }

    @objc private func applyInterfaceFonts() {
        for button in [hiddenButton, attributesButton, newWindowButton, favoriteToggle, searchButton, packButton, helpButton, sshButton, editorButton, clearButton, cancelButton] {
            button.font = AppFont.interface(11)
        }
        functionButtons.forEach { $0.button.font = AppFont.interface(12) }
        queueSummary.font = AppFont.interface(12)
    }

    private func relabel() {
        hiddenButton.title = L10n.t(left.showHidden ? "top.hiddenOn" : "top.hiddenOff")
        attributesButton.title = L10n.t(active.showAttributes ? "top.attributesOn" : "top.attributesOff")
        newWindowButton.title = L10n.t("top.newWindow")
        searchButton.title = L10n.t("top.search")
        packButton.title = L10n.t("top.pack")
        helpButton.title = L10n.t("top.help")
        sshButton.title = L10n.t("top.ssh")
        clearButton.title = L10n.t("queue.clear")
        cancelButton.title = L10n.t("queue.cancel")
        for item in functionButtons {
            item.button.title = "\(item.key)  \(L10n.t(item.labelKey))"
        }
        applyInterfaceFonts()
        left.relabel()
        right.relabel()
        terminalPane.relabel()
        reloadFavorites()
        updateEditorButton()
        updateQueue()
    }

    private func updateEditorButton() {
        editorButton.title = L10n.t("queue.editorIs", usesBuiltInEditor ? L10n.t("editor.builtIn") : editorURL.map(displayName) ?? L10n.t("editor.builtIn"))
    }

    private func refreshActive() {
        if window?.firstResponder === left.table { lastActive = left }
        if window?.firstResponder === right.table { lastActive = right }
        left.refreshChrome()
        right.refreshChrome()
        left.table.setNeedsDisplay(left.table.visibleRect)
        right.table.setNeedsDisplay(right.table.visibleRect)
        attributesButton.title = L10n.t(active.showAttributes ? "top.attributesOn" : "top.attributesOff")
        updateFavoriteToggle()
        // Tab between panels also switches the terminal, when the other panel has a shell to show.
        if !terminalPane.isHidden, !terminalIsPinned, window?.firstResponder === active.table { presentTerminal(for: active) }
    }

    private var lastActive: PanelController?
    private var active: PanelController { lastActive ?? left }
    private var other: PanelController { active === left ? right : left }

    private func activate(_ panel: PanelController) {
        window?.makeFirstResponder(panel.table)
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent, panel: PanelController) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .option {
            switch event.keyCode {
            case 122: HelpWindowController.show() // Option+F1
            case 96: startPack() // Option+F5
            case 101: showSSHMenu(nil) // Option+F9
            case 98: showSearch(nil) // Option+F7
            default: return false
            }
            return true
        }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return false }
        let shift = flags.contains(.shift)
        switch event.keyCode {
        case 114: // Insert on PC keyboards reaches macOS as Help
            panel.toggleMark(at: panel.table.selectedRow, advance: true)
        case 49: // Space, for keyboards without Insert
            panel.toggleMark(at: panel.table.selectedRow, advance: true)
        case 48: // Tab
            activate(panel === left ? right : left)
        case 123: activate(left)
        case 124: activate(right)
        case 36, 76:
            // Shift+Enter skips looking inside an archive and offers the associated app.
            if shift, let entry = panel.cursorEntry, !entry.isDirectory {
                askToOpen(entry, in: panel)
            } else {
                panel.activateCursor()
            }
        case 51: panel.goUp()
        case 115: panel.moveCursor(to: 0)
        case 119: panel.moveCursor(to: panel.rows.count - 1)
        case 116: panel.moveCursor(to: panel.table.selectedRow - pageSize(panel))
        case 121: panel.moveCursor(to: panel.table.selectedRow + pageSize(panel))
        case 122: showFavoritesMenu() // F1
        case 120: showInfo() // F2
        case 99: showPreview() // F3
        case 118: edit(forceChoice: shift) // F4
        case 96: startTransfer(move: false) // F5
        case 97: // F6
            if shift { renameCursor() } else { startTransfer(move: true) }
        case 98: makeFolder() // F7
        case 100, 117: deleteSelection() // F8, forward delete
        case 101: // F9
            if shift { openTerminal() } else { showTerminal() }
        case 109: openWriter() // F10
        default:
            return panel.jumpToName(typed: event.characters ?? "")
        }
        return true
    }

    private func pageSize(_ panel: PanelController) -> Int {
        max(1, Int(panel.table.visibleRect.height / panel.table.rowHeight) - 1)
    }

    // MARK: Button and menu actions

    @objc private func favoritesClicked() { showFavoritesMenu() }
    @objc private func markClicked() { active.toggleMark(at: active.table.selectedRow, advance: true) }
    @objc private func switchPanelClicked() { activate(other) }
    @objc private func sizeClicked() { showInfo() }
    @objc private func viewClicked() { showPreview() }
    @objc private func editClicked() { edit(forceChoice: false) }
    @objc private func copyClicked() {
        if NSEvent.modifierFlags.contains(.option) { startPack() } else { startTransfer(move: false) }
    }
    @objc private func packClicked() { startPack() }
    @objc private func writerClicked() { openWriter() }
    @objc private func helpClicked() { HelpWindowController.show() }
    @objc private func moveClicked() { startTransfer(move: true) }
    @objc private func mkdirClicked() { makeFolder() }
    @objc private func deleteClicked() { deleteSelection() }
    @objc private func terminalClicked() {
        if NSEvent.modifierFlags.contains(.shift) { openTerminal() } else { showTerminal() }
    }
    @objc private func chooseEditorClicked() { edit(forceChoice: true) }
    @objc private func leftSiteClicked() { openSiteManager(for: left) }
    @objc private func rightSiteClicked() { openSiteManager(for: right) }

    @objc private func newWindowClicked() {
        (NSApp.delegate as? AppDelegate)?.newWindow(nil)
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        let value = !left.showHidden
        UserDefaults.standard.set(value, forKey: "showHidden")
        left.showHidden = value
        right.showHidden = value
        hiddenButton.title = L10n.t(value ? "top.hiddenOn" : "top.hiddenOff")
    }

    @objc func toggleAttributes(_ sender: Any?) {
        active.showAttributes.toggle()
        attributesButton.title = L10n.t(active.showAttributes ? "top.attributesOn" : "top.attributesOff")
    }

    @objc func refreshPanels(_ sender: Any?) {
        left.reload()
        right.reload()
    }

    @objc func showSiteManager(_ sender: Any?) { openSiteManager(for: active) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        window?.attachedSheet == nil
    }

    // MARK: Messages

    func showToast(_ message: String) {
        toast.stringValue = "  \(message)  "
        toast.isHidden = false
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
            self?.toast.isHidden = true
        }
    }

    private func showError(_ message: String, title: String? = nil) {
        guard let window else { return }
        guard window.attachedSheet == nil else {
            showToast(message)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title ?? L10n.t("error.title")
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.beginSheetModal(for: window)
    }

    private func present(_ alert: NSAlert, handler: @escaping (Int) -> Void) {
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            handler(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        }
    }

    /// macOS only binds Esc to a button titled exactly "Cancel", so translated titles need it set by hand.
    private func addCancel(to alert: NSAlert) {
        alert.addButton(withTitle: L10n.t("common.cancel")).keyEquivalent = "\u{1b}"
    }

    private func panelPath(_ panel: PanelController, _ entry: FileEntry) -> String {
        PathUtil.join(panel.path, entry.name)
    }

    // MARK: Copy and move (F5, F6)

    private func startTransfer(move: Bool) {
        let from = active
        let to = other
        if blockedByArchive(to) || (move && blockedByArchive(from)) { return }
        let selection = from.selection
        guard !selection.isEmpty else { return }

        let alert = NSAlert()
        let count = String(selection.count)
        let direction = to.source.isRemote ? "Server" : "Disk"
        alert.messageText = L10n.t("\(move ? "move" : "copy").title\(direction)", count)
        var names = selection.prefix(5).map(\.name).joined(separator: "\n")
        if selection.count > 5 { names += "\n" + L10n.t("copy.more", String(selection.count - 5)) }
        alert.informativeText = names + "\n\n" + L10n.t("copy.target") + ": " + to.path

        let policyLabel = NSTextField(labelWithString: L10n.t("copy.ifExists"))
        let policy = NSPopUpButton()
        let policies = OverwritePolicy.allCases
        policy.addItems(withTitles: policies.map { L10n.t("policy.\($0.rawValue)") })
        let stack = NSStackView(views: [policyLabel, policy])
        stack.frame = NSRect(x: 0, y: 0, width: 400, height: 28)
        alert.accessoryView = stack

        alert.addButton(withTitle: L10n.t(move ? "copy.ctaMove" : "copy.ctaCopy"))
        addCancel(to: alert)
        present(alert) { [weak self] button in
            guard let self, button == 0 else { return }
            self.plan(selection: selection, from: from, to: to, move: move, policy: policies[policy.indexOfSelectedItem])
        }
    }

    private func plan(selection: [FileEntry], from: PanelController, to: PanelController, move: Bool, policy: OverwritePolicy) {
        let source = from.source
        let destination = to.source
        let sourcePath = from.path
        let destinationPath = to.path
        showToast(L10n.t("copy.scanning"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                var plan = try TransferPlanner.plan(selection: selection, from: source, sourceDirectory: sourcePath, to: destination, destinationDirectory: destinationPath)
                plan.applyPolicy(policy)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.toast.isHidden = true
                    if policy == .ask && !plan.conflicts.isEmpty {
                        self.resolve(plan: plan, index: 0, from: from, to: to, move: move)
                    } else {
                        self.launch(plan: plan, from: from, to: to, move: move)
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.showError(error.localizedDescription) }
            }
        }
    }

    /// One question per file that would be replaced. Return does nothing here, so a stray key cannot overwrite.
    private func resolve(plan: TransferPlan, index: Int, from: PanelController, to: PanelController, move: Bool) {
        guard index < plan.conflicts.count else {
            launch(plan: plan, from: from, to: to, move: move)
            return
        }
        let conflict = plan.conflicts[index]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("conflict.title")
        var verdict = ""
        if let a = conflict.source.date, let b = conflict.destination.date {
            verdict = L10n.t(a > b ? "conflict.newer" : (a < b ? "conflict.older" : "conflict.same"))
        }
        let line = { (key: String, entry: FileEntry) in
            "\(L10n.t(key)): \(entry.isDirectory ? "<DIR>" : Format.size(entry.size))  \(Format.date(entry.date))"
        }
        alert.informativeText = [
            L10n.t("conflict.count", String(index + 1), String(plan.conflicts.count)),
            "", conflict.relative, "",
            line("conflict.source", conflict.source),
            line("conflict.target", conflict.destination),
            "", verdict,
        ].joined(separator: "\n")

        let choices = [("conflict.overwrite", "o"), ("conflict.overwriteAll", "a"), ("conflict.skip", "s"), ("conflict.skipAll", "k"), ("conflict.cancel", "\u{1b}")]
        for (key, shortcut) in choices {
            alert.addButton(withTitle: L10n.t(key)).keyEquivalent = shortcut
        }
        present(alert) { [weak self] choice in
            guard let self else { return }
            var next = plan
            switch choice {
            case 0:
                self.resolve(plan: next, index: index + 1, from: from, to: to, move: move)
            case 1:
                self.launch(plan: next, from: from, to: to, move: move)
            case 2:
                next.skipped.insert(conflict.relative)
                self.resolve(plan: next, index: index + 1, from: from, to: to, move: move)
            case 3:
                next.conflicts[index...].forEach { next.skipped.insert($0.relative) }
                self.launch(plan: next, from: from, to: to, move: move)
            default:
                break // Nothing was transferred, the marks stay.
            }
        }
    }

    private func launch(plan: TransferPlan, from: PanelController, to: PanelController, move: Bool) {
        let files = plan.files.filter { !plan.skipped.contains($0.relative) }
        from.clearMarks()
        if files.isEmpty && plan.directoriesToCreate.isEmpty {
            showToast(L10n.t("copy.nothing"))
            return
        }
        let parallel = [from.site, to.site].compactMap { $0?.parallel }.min() ?? 4
        let title = L10n.t(to.source.isRemote ? "queue.toServer" : "queue.toDisk", String(files.count))
        engine.start(plan: plan, title: title, source: from.source, destination: to.source, move: move, parallel: parallel)
        startQueueTimer()
    }

    // MARK: Queue

    private func startQueueTimer() {
        updateQueue()
        guard queueTimer == nil else { return }
        queueTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.updateQueue() }
    }

    private func updateQueue() {
        let batches = engine.snapshots()
        let running = batches.filter { !$0.isFinished }
        cancelButton.isHidden = running.isEmpty
        clearButton.isHidden = batches.allSatisfy { !$0.isFinished }
        if batches.isEmpty {
            queueSummary.stringValue = L10n.t("queue.empty")
        } else if running.isEmpty {
            queueSummary.stringValue = L10n.t("queue.done")
        } else {
            queueSummary.stringValue = L10n.t("queue.running", String(running.count))
        }
        queueStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for batch in batches.suffix(4) {
            let name = NSTextField(labelWithString: batch.title + (batch.currentFile.isEmpty ? "" : " — " + batch.currentFile))
            name.font = AppFont.interface(12)
            name.lineBreakMode = .byTruncatingMiddle
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let bar = NSProgressIndicator()
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.doubleValue = batch.isFinished ? 1 : Double(batch.doneBytes) / Double(max(1, batch.totalBytes))
            bar.controlSize = .small
            bar.style = .bar
            let state: String
            if batch.isCancelled {
                state = L10n.t("queue.cancelled")
            } else if batch.isFinished {
                state = batch.failures.isEmpty ? L10n.t("queue.finished") : L10n.t("queue.failed", String(batch.failures.count))
            } else {
                state = "\(batch.finishedFiles)/\(batch.fileCount)  \(Format.size(batch.doneBytes))"
            }
            let stateLabel = NSTextField(labelWithString: state)
            stateLabel.font = AppFont.interface(11)
            stateLabel.alignment = .right
            let row = NSStackView(views: [name, bar, stateLabel])
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            queueStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: queueStack.widthAnchor).isActive = true
            name.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.42).isActive = true
            stateLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true
        }
        if running.isEmpty {
            queueTimer?.invalidate()
            queueTimer = nil
        }
    }

    private func batchFinished(_ snapshot: BatchSnapshot) {
        updateQueue()
        removeFinishedPackFolders()
        left.reload()
        right.reload()
        if !snapshot.failures.isEmpty && !snapshot.isCancelled {
            let shown = snapshot.failures.prefix(10).joined(separator: "\n")
            showError(shown, title: L10n.t("queue.failedTitle", String(snapshot.failures.count)))
        }
    }

    @objc private func clearFinished() {
        engine.clearFinished()
        updateQueue()
    }

    @objc private func cancelTransfers() { engine.cancelAll() }

    // MARK: Local copies of server files

    private func localCopy(of entry: FileEntry, in panel: PanelController, reuse: Bool = true, completion: @escaping (URL?) -> Void) {
        let full = panelPath(panel, entry)
        guard panel.source.isRemote else {
            completion(URL(fileURLWithPath: full))
            return
        }
        let key = "\(ObjectIdentifier(panel.source))|\(full)|\(entry.size)|\(entry.date?.timeIntervalSince1970 ?? 0)"
        if reuse, let cached = downloadCache[key] {
            completion(cached)
            return
        }
        let folder = temporaryRoot.appendingPathComponent(UUID().uuidString)
        let target = folder.appendingPathComponent(entry.name)
        let source = panel.source
        downloadQueue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try source.download(full, to: target) { _ in true }
                DispatchQueue.main.async {
                    self?.downloadCache[key] = target
                    completion(target)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showError(error.localizedDescription)
                    completion(nil)
                }
            }
        }
    }

    // MARK: Enter: open with the associated app, after asking

    private func applications(for entry: FileEntry, in panel: PanelController) -> (preferred: URL?, all: [URL]) {
        let workspace = NSWorkspace.shared
        if !panel.source.isRemote {
            let url = URL(fileURLWithPath: panelPath(panel, entry))
            return (workspace.urlForApplication(toOpen: url), workspace.urlsForApplications(toOpen: url))
        }
        let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        return (workspace.urlForApplication(toOpen: type), workspace.urlsForApplications(toOpen: type))
    }

    private func displayName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func askToOpen(_ entry: FileEntry, in panel: PanelController) {
        let found = applications(for: entry, in: panel)
        let others = found.all.filter { $0 != found.preferred }.prefix(3)
        let alert = NSAlert()
        var choices: [URL] = []
        if let preferred = found.preferred {
            alert.messageText = L10n.t("open.ask", entry.name, displayName(preferred))
            alert.addButton(withTitle: L10n.t("open.with", displayName(preferred)))
            choices.append(preferred)
        } else {
            alert.messageText = L10n.t("open.none", entry.name)
        }
        if panel.source.isRemote { alert.informativeText = L10n.t("open.remote") }
        for app in others {
            alert.addButton(withTitle: displayName(app))
            choices.append(app)
        }
        alert.addButton(withTitle: L10n.t("open.other"))
        addCancel(to: alert)

        present(alert) { [weak self] button in
            guard let self else { return }
            if button < choices.count {
                self.open(entry, in: panel, with: choices[button])
            } else if button == choices.count {
                self.chooseApplication { app in
                    if let app { self.open(entry, in: panel, with: app) }
                }
            }
        }
    }

    private func chooseApplication(completion: @escaping (URL?) -> Void) {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowedContentTypes = [.application]
        picker.beginSheetModal(for: window) { response in
            completion(response == .OK ? picker.url : nil)
        }
    }

    private func open(_ entry: FileEntry, in panel: PanelController, with app: URL) {
        if panel.source.isRemote { showToast(L10n.t("status.downloading", entry.name)) }
        localCopy(of: entry, in: panel) { [weak self] url in
            guard let self, let url else { return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.main.async {
                    if let error { self.showError(error.localizedDescription) }
                    else { self.showToast(L10n.t("open.done", entry.name, self.displayName(app))) }
                }
            }
        }
    }

    // MARK: F4: chosen editor

    private var editorURL: URL? {
        get { UserDefaults.standard.string(forKey: "editorPath").map { URL(fileURLWithPath: $0) } }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: "editorPath")
            updateEditorButton()
        }
    }

    /// The built-in editor unless Shift+F4 chose another program.
    private var usesBuiltInEditor: Bool {
        get { UserDefaults.standard.object(forKey: "editorBuiltIn") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "editorBuiltIn")
            updateEditorButton()
        }
    }

    private func edit(forceChoice: Bool) {
        if !forceChoice && blockedByArchive(active) { return }
        let target = active.cursorEntry.flatMap { $0.isDirectory ? nil : $0 }
        if forceChoice {
            pickEditor { [weak self] in
                if let target, let self, let panel = Optional(self.active) { self.launchEditor(target, in: panel) }
            }
        } else if let target {
            launchEditor(target, in: active)
        }
    }

    private func pickEditor(then next: @escaping () -> Void) {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: UTType.plainText)
        let alert = NSAlert()
        alert.messageText = L10n.t("editor.title")
        alert.informativeText = L10n.t("editor.help")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        popup.addItems(withTitles: [L10n.t("editor.builtIn")] + apps.map(displayName))
        if !usesBuiltInEditor, let current = editorURL, let index = apps.firstIndex(of: current) { popup.selectItem(at: index + 1) }
        alert.accessoryView = popup
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: L10n.t("open.other"))
        addCancel(to: alert)
        present(alert) { [weak self] button in
            guard let self else { return }
            if button == 0, popup.indexOfSelectedItem == 0 {
                self.usesBuiltInEditor = true
                next()
            } else if button == 0, popup.indexOfSelectedItem > 0 {
                self.editorURL = apps[popup.indexOfSelectedItem - 1]
                self.usesBuiltInEditor = false
                next()
            } else if button == 1 {
                self.chooseApplication { app in
                    if let app {
                        self.editorURL = app
                        self.usesBuiltInEditor = false
                        next()
                    }
                }
            }
        }
    }

    private func launchEditor(_ entry: FileEntry, in panel: PanelController) {
        if usesBuiltInEditor {
            openBuiltInEditor(entry, in: panel)
        } else if let editor = editorURL {
            launch(entry, in: panel, with: editor)
        }
    }

    /// Opens the built-in editor, or the file's own app when the file isn't text.
    private func openBuiltInEditor(_ entry: FileEntry, in panel: PanelController) {
        let path = panelPath(panel, entry)
        let remoteSource = panel.source.isRemote ? panel.source : nil
        if let open = EditorWindowController.existing(path: path, source: remoteSource) {
            open.showWindow(nil)
            return
        }
        if isImage(entry.name) {
            launchWithAssociatedApp(entry, in: panel)
            return
        }
        if entry.size > EditorWindowController.sizeLimit {
            showToast(L10n.t("edit.tooBig", entry.name))
            return
        }
        if remoteSource != nil { showToast(L10n.t("status.downloading", entry.name)) }
        let target = EditorWindowController.Target(name: entry.name, path: path, source: remoteSource, queue: downloadQueue)
        localCopy(of: entry, in: panel, reuse: false) { [weak self, weak panel] url in
            guard let self, let panel, let url else { return }
            self.downloadQueue.async { [weak self, weak panel] in
                let read = Result { try Data(contentsOf: url) }
                let document = (try? read.get()).flatMap(EditorDocument.decode)
                let stamp = EditorWindowController.currentStamp(of: target)
                DispatchQueue.main.async {
                    guard let self, let panel else { return }
                    if case .failure(let error) = read {
                        self.showError(error.localizedDescription)
                    } else if let document {
                        let editor = EditorWindowController(target: target, document: document, stamp: stamp)
                        editor.onSaved = { [weak panel] in panel?.reload() }
                        editor.onMessage = { [weak self] in self?.showToast($0) }
                        editor.showWindow(nil)
                    } else {
                        self.launchWithAssociatedApp(entry, in: panel)
                    }
                }
            }
        }
    }

    private func launchWithAssociatedApp(_ entry: FileEntry, in panel: PanelController) {
        let probe = URL(fileURLWithPath: "/tmp").appendingPathComponent(entry.name)
        let type = UTType(filenameExtension: probe.pathExtension)
        if let type, let app = NSWorkspace.shared.urlForApplication(toOpen: type) {
            launch(entry, in: panel, with: app)
        } else {
            showToast(L10n.t("edit.notText", entry.name))
        }
    }

    private func launch(_ entry: FileEntry, in panel: PanelController, with editor: URL) {
        let remote = panel.source.isRemote
        if remote { showToast(L10n.t("status.downloading", entry.name)) }
        let remotePath = panelPath(panel, entry)
        let source = panel.source
        // Always a fresh copy, so edits start from what is on the server now.
        localCopy(of: entry, in: panel, reuse: false) { [weak self] url in
            guard let self, let url else { return }
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.showError(error.localizedDescription)
                        return
                    }
                    self.showToast(L10n.t(remote ? "editor.openedRemote" : "editor.opened", entry.name, self.displayName(editor)))
                    if remote { self.watch(url: url, remotePath: remotePath, source: source, panel: panel) }
                }
            }
        }
    }

    /// Saving in the editor uploads the file back to the server while this window stays open.
    private func watch(url: URL, remotePath: String, source: FileSource, panel: PanelController) {
        editWatches.append(EditWatch(url: url, remotePath: remotePath, source: source, panel: panel))
        guard editTimer == nil else { return }
        editTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkEdits() }
    }

    private func checkEdits() {
        for watch in editWatches {
            guard let date = MainWindowController.modificationDate(watch.url), date != watch.lastChange else { continue }
            watch.lastChange = date
            let name = watch.url.lastPathComponent
            downloadQueue.async { [weak self] in
                do {
                    try watch.source.upload(watch.url, to: watch.remotePath) { _ in true }
                    DispatchQueue.main.async {
                        self?.showToast(L10n.t("editor.uploaded", name))
                        watch.panel.reload()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.showError(L10n.t("editor.uploadFailed", name, error.localizedDescription))
                    }
                }
            }
        }
    }

    // MARK: F10: writing editor

    /// Opens the HTML file under the cursor, or a new document in the active folder.
    func openWriter() {
        let panel = active
        if blockedByArchive(panel) { return }
        let source = panel.source.isRemote ? panel.source : nil
        let queue = downloadQueue
        guard let entry = panel.cursorEntry, !entry.isDirectory, ["html", "htm"].contains((entry.name as NSString).pathExtension.lowercased()) else {
            RichEditorController(target: nil, file: nil, stamp: nil, folder: panel.path, source: source, queue: queue).configured(by: self, panel: panel).showWindow(nil)
            return
        }
        let path = panelPath(panel, entry)
        if let open = RichEditorController.existing(path: path, source: source) {
            open.showWindow(nil)
            return
        }
        if entry.size > EditorWindowController.sizeLimit {
            showToast(L10n.t("edit.tooBig", entry.name))
            return
        }
        if source != nil { showToast(L10n.t("status.downloading", entry.name)) }
        let target = EditorWindowController.Target(name: entry.name, path: path, source: source, queue: queue)
        localCopy(of: entry, in: panel, reuse: false) { [weak self, weak panel] url in
            guard let self, let panel, let url else { return }
            queue.async { [weak self, weak panel] in
                let file = (try? Data(contentsOf: url)).flatMap(EditorDocument.decode)
                let stamp = EditorWindowController.currentStamp(of: target)
                DispatchQueue.main.async {
                    guard let self, let panel else { return }
                    guard let file else {
                        self.showToast(L10n.t("edit.notText", entry.name))
                        return
                    }
                    if RichDocument.containsServerCode(file.text) {
                        self.showToast(L10n.t("rich.hasCode", entry.name))
                        return
                    }
                    self.toast.isHidden = true
                    RichEditorController(target: target, file: file, stamp: stamp, folder: PathUtil.parent(path), source: source, queue: queue).configured(by: self, panel: panel).showWindow(nil)
                }
            }
        }
    }

    // MARK: F3: preview

    private func isImage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "svg" { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
    }

    private func showPreview() {
        let panel = active
        guard let entry = panel.cursorEntry, !entry.isDirectory else { return }
        if isImage(entry.name) {
            showImages(start: entry, in: panel)
        } else {
            showText(entry, in: panel)
        }
    }

    private func showImages(start entry: FileEntry, in panel: PanelController) {
        let images = panel.rows.filter { !$0.isDirectory && isImage($0.name) }
        guard let index = images.firstIndex(where: { $0.name == entry.name }) else { return }
        let items = images.map { image in
            ViewerItem(name: image.name, size: image.size) { [weak self, weak panel] done in
                guard let self, let panel else { done(nil); return }
                self.localCopy(of: image, in: panel, completion: done)
            }
        }
        let viewer = ImageViewerController(items: items, start: index)
        viewer.onIndexChange = { [weak panel] name in panel?.select(name: name) }
        viewer.onEdit = { [weak self, weak panel] position in
            guard let self, let panel else { return }
            let target = images[position]
            self.launchEditor(target, in: panel)
        }
        track(viewer) { viewer.onClosed = $0 }
    }

    private func showText(_ entry: FileEntry, in panel: PanelController) {
        if panel.source.isRemote { showToast(L10n.t("status.downloading", entry.name)) }
        localCopy(of: entry, in: panel) { [weak self, weak panel] url in
            guard let self, let panel, let url else { return }
            guard let text = TextViewerController.readText(url) else {
                self.showToast(L10n.t("preview.none", entry.name))
                return
            }
            let detail = Format.size(entry.size) + (panel.source.isRemote ? " · " + L10n.t("preview.fromServer") : "")
            let viewer = TextViewerController(name: entry.name, detail: detail, text: text)
            viewer.onEdit = { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.launchEditor(entry, in: panel)
            }
            self.track(viewer) { viewer.onClosed = $0 }
        }
    }

    private func track(_ viewer: NSWindowController, setClosed: (@escaping () -> Void) -> Void) {
        viewers.append(viewer)
        setClosed { [weak self, weak viewer] in
            self?.viewers.removeAll { $0 === viewer }
        }
        viewer.showWindow(nil)
    }

    // MARK: F2: size

    private func showInfo() {
        let panel = active
        guard let window, let cursor = panel.cursorEntry else { return }
        let source = panel.source
        var directory = panel.path
        var entries = panel.selection
        var title = entries.count == 1 ? entries[0].name : L10n.t("info.items", String(entries.count))
        var whole = false
        if entries.isEmpty, cursor.name == ".." {
            // On ".." the answer is about the folder you are in.
            whole = true
            title = PathUtil.lastComponent(panel.path)
            directory = panel.path
            entries = panel.rows.filter { $0.name != ".." }
        }
        let location = whole ? PathUtil.parent(panel.path) : panel.path
        let single = !whole && entries.count == 1 ? entries[0] : nil

        let alert = NSAlert()
        alert.messageText = title
        let body = { [weak panel] (totals: SizeTotals?) -> String in
            let wait = L10n.t("info.calculating")
            var lines = [L10n.t("info.location") + ": " + location]
            if let totals {
                lines.append(L10n.t("info.size") + ": " + Format.size(totals.bytes) + " (" + Format.exact(totals.bytes) + " " + L10n.t("info.bytes") + ")")
                lines.append(L10n.t("info.onDisk") + ": " + (panel?.source.isRemote == false ? Format.size(totals.bytesOnDisk) : L10n.t("info.notAvailable")))
                lines.append(L10n.t("info.contains") + ": " + L10n.t("info.containsValue", String(totals.files), String(totals.folders - (single?.isDirectory == true ? 1 : 0))))
            } else {
                lines += [L10n.t("info.size") + ": " + wait, L10n.t("info.onDisk") + ": " + wait, L10n.t("info.contains") + ": " + wait]
            }
            if let single {
                lines.append(L10n.t("info.permissions") + ": " + (single.permissions ?? "—"))
                lines.append(L10n.t("info.owner") + ": " + (single.owner ?? "—"))
            }
            return lines.joined(separator: "\n")
        }
        alert.informativeText = body(nil)
        alert.addButton(withTitle: L10n.t("common.close")).keyEquivalent = "\u{1b}"
        let canFinder = !source.isRemote && entries.count == 1 || whole && !source.isRemote
        if canFinder { alert.addButton(withTitle: L10n.t("info.finder")) }

        final class Flag { var cancelled = false }
        let flag = Flag()
        let finderPath = whole ? panel.path : PathUtil.join(panel.path, entries.first?.name ?? "")
        alert.beginSheetModal(for: window) { [weak self] response in
            flag.cancelled = true
            if response == .alertSecondButtonReturn { self?.openFinderInfo(finderPath) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let totals = try SizeCalculator.total(of: entries, in: directory, source: source) { flag.cancelled }
                DispatchQueue.main.async { [weak panel] in
                    guard !flag.cancelled else { return }
                    alert.informativeText = body(totals)
                    alert.layout()
                    if let only = single, only.isDirectory { panel?.setComputedSize(totals.bytes, for: only.name) }
                }
                // Marked folders each get their own figure in the list.
                if single == nil && !whole {
                    for entry in entries where entry.isDirectory {
                        let inner = try SizeCalculator.total(of: [entry], in: directory, source: source) { flag.cancelled }
                        DispatchQueue.main.async { [weak panel] in panel?.setComputedSize(inner.bytes, for: entry.name) }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard !flag.cancelled else { return }
                    alert.informativeText = error.localizedDescription
                    alert.layout()
                }
            }
        }
    }

    private func openFinderInfo(_ path: String) {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(escaped)" as alias)
        end tell
        """
        var failure: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&failure)
        if let message = failure?[NSAppleScript.errorMessage] as? String { showError(message) }
    }

    // MARK: F7, F8, Shift+F6

    private func askForName(title: String, value: String, confirm: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        addCancel(to: alert)
        alert.window.initialFirstResponder = field
        present(alert) { button in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if button == 0, !name.isEmpty, !name.contains("/") { completion(name) }
        }
    }

    private func run(_ panel: PanelController, select: String? = nil, work: @escaping () throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try work()
                DispatchQueue.main.async { panel.load(path: panel.path, select: select) }
            } catch {
                DispatchQueue.main.async {
                    self?.showError(error.localizedDescription)
                    panel.reload()
                }
            }
        }
    }

    private func makeFolder() {
        let panel = active
        if blockedByArchive(panel) { return }
        askForName(title: L10n.t("mkdir.title"), value: "", confirm: L10n.t("mkdir.confirm")) { [weak self] name in
            let path = PathUtil.join(panel.path, name)
            let source = panel.source
            self?.run(panel, select: name) { try source.makeDirectory(path) }
        }
    }

    private func renameCursor() {
        let panel = active
        if blockedByArchive(panel) { return }
        guard let entry = panel.cursorEntry, entry.name != ".." else { return }
        askForName(title: L10n.t("rename.title"), value: entry.name, confirm: L10n.t("rename.confirm")) { [weak self] name in
            let source = panel.source
            let from = PathUtil.join(panel.path, entry.name)
            let to = PathUtil.join(panel.path, name)
            self?.run(panel, select: name) { try source.rename(from: from, to: to) }
        }
    }

    private func deleteSelection() {
        let panel = active
        if blockedByArchive(panel) { return }
        let selection = panel.selection
        guard !selection.isEmpty else { return }
        let remote = panel.source.isRemote
        let alert = NSAlert()
        alert.alertStyle = remote ? .critical : .warning
        alert.messageText = L10n.t(remote ? "delete.titleRemote" : "delete.titleLocal", String(selection.count))
        var names = selection.prefix(8).map(\.name).joined(separator: "\n")
        if selection.count > 8 { names += "\n" + L10n.t("copy.more", String(selection.count - 8)) }
        alert.informativeText = names + (remote ? "\n\n" + L10n.t("delete.permanent") : "")
        let confirm = alert.addButton(withTitle: L10n.t(remote ? "delete.confirmRemote" : "delete.confirmLocal"))
        addCancel(to: alert)
        // Deleting on a server cannot be undone, so Return must not do it.
        if remote { confirm.keyEquivalent = "" }
        present(alert) { [weak self] button in
            guard button == 0 else { return }
            let source = panel.source
            let directory = panel.path
            self?.run(panel) {
                for entry in selection {
                    let path = PathUtil.join(directory, entry.name)
                    if let local = source as? LocalSource {
                        try local.trash(path)
                    } else {
                        try source.removeTree(path, isDirectory: entry.isDirectory && !entry.isSymlink)
                    }
                }
            }
        }
    }

    // MARK: F9: Terminal

    // MARK: Bottom terminal

    private static let defaultTerminalHeight: CGFloat = 260
    private static let minimumTerminalHeight: CGFloat = 110

    var terminalIsFocused: Bool {
        guard let view = terminalPane.current?.view, !terminalPane.isHidden else { return false }
        return window?.firstResponder === view
    }

    /// Target for a panel. FTP has none, because it has no shell.
    private func terminalTarget(for panel: PanelController) -> TerminalTarget? {
        if panel.isInArchive { return nil }
        guard let site = panel.site else { return .local }
        return site.proto == .ssh ? .site(site.id) : nil
    }

    /// Shows the panel's session, starting one if needed. Returns nil for FTP panels.
    @discardableResult
    private func presentTerminal(for panel: PanelController, restart: Bool = false) -> TerminalSession? {
        guard let target = terminalTarget(for: panel) else { return nil }
        let title = panel.site?.name ?? L10n.t("panel.local")
        return terminalPane.show(target: target, title: title, directory: panel.path, restart: restart) { session in
            if let client = panel.source as? SSHClient {
                session.startSSH(client.shellInvocation(directory: panel.path))
            } else {
                session.startLocal()
            }
        }
    }

    private func openTerminalPane() {
        guard terminalPane.isHidden else { return }
        let saved = CGFloat(UserDefaults.standard.double(forKey: "terminalHeight"))
        terminalHeight.constant = clampedTerminalHeight(saved > 0 ? saved : Self.defaultTerminalHeight)
        terminalGap.constant = 6
        terminalPane.isHidden = false
    }

    private func hideTerminal() {
        let hadFocus = terminalIsFocused
        terminalPane.isHidden = true
        terminalHeight.constant = 0
        terminalGap.constant = 0
        // The session keeps running, and F9 brings it back.
        if hadFocus || window?.firstResponder === window { activate(active) }
    }

    /// F9: open the terminal for the active panel, in that panel's folder, and move the keyboard into it.
    private func showTerminal() {
        guard terminalTarget(for: active) != nil else {
            if terminalPane.current == nil || terminalPane.isHidden {
                showToast(L10n.t("terminal.noShell"))
            } else if let view = terminalPane.current?.view {
                window?.makeFirstResponder(view)
            }
            return
        }
        openTerminalPane()
        terminalIsPinned = false
        guard let session = presentTerminal(for: active, restart: true) else { return }
        session.changeDirectory(active.path)
        window?.makeFirstResponder(session.view)
    }

    // MARK: Option+F9: saved SSH connections

    private var terminalClients: [UUID: SSHClient] = [:]
    /// A connection picked from the list stays on screen while you work in the panels, until F9.
    private var terminalIsPinned = false

    /// Saved SSH servers, the local shell, and a way to the server list.
    func sshMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let sites = store.load().filter { $0.proto == .ssh && !$0.host.isEmpty }
        for (index, site) in sites.enumerated() {
            let running = terminalPane.runningSession(for: .site(site.id)) != nil
            var details = [site.user.isEmpty ? site.host : "\(site.user)@\(site.host)"]
            if let key = site.keyFile, !key.isEmpty { details.append("🔑 " + (key as NSString).lastPathComponent) }
            if let hop = sites.first(where: { $0.id == site.jumpSiteID }) { details.append("→ " + hop.name) }
            let item = NSMenuItem(title: "\(site.name)    \(details.joined(separator: "  "))", action: #selector(sshMenuChosen(_:)), keyEquivalent: index < 9 ? String(index + 1) : "")
            item.keyEquivalentModifierMask = []
            item.target = self
            item.representedObject = site.id
            item.state = running ? .on : .off
            menu.addItem(item)
        }
        if sites.isEmpty {
            let empty = NSMenuItem(title: L10n.t("ssh.empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        let local = NSMenuItem(title: L10n.t("ssh.local"), action: #selector(sshLocalChosen), keyEquivalent: "")
        local.target = self
        local.state = terminalPane.runningSession(for: .local) != nil ? .on : .off
        menu.addItem(local)
        let manage = NSMenuItem(title: L10n.t("ssh.manage"), action: #selector(showSiteManager(_:)), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        return menu
    }

    @objc func showSSHMenu(_ sender: Any?) {
        guard window?.attachedSheet == nil else { return }
        let view = active.view
        sshMenu().popUp(positioning: nil, at: NSPoint(x: 24, y: view.bounds.height - 40), in: view)
    }

    @objc private func sshMenuChosen(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID, let site = store.load().first(where: { $0.id == id }) else { return }
        openSSHTerminal(site)
    }

    func openSSHTerminal(_ site: Site) {
        openTerminalPane()
        terminalIsPinned = true
        let session = terminalPane.show(target: .site(site.id), title: site.name, directory: site.path, restart: true) { session in
            // Built anew for each start, so changes in the server list apply. Kept because the shell uses its password helper.
            let client = SSHClient(site: site, password: self.store.password(for: site.id), hops: self.store.hops(for: site))
            self.terminalClients[site.id] = client
            session.startSSH(client.shellInvocation(directory: site.path == "/" ? nil : site.path))
        }
        window?.makeFirstResponder(session.view)
    }

    @objc private func sshLocalChosen() {
        openTerminalPane()
        terminalIsPinned = true
        let directory = active.source.isRemote ? FileManager.default.homeDirectoryForCurrentUser.path : active.path
        let session = terminalPane.show(target: .local, title: L10n.t("panel.local"), directory: directory, restart: true) { $0.startLocal() }
        window?.makeFirstResponder(session.view)
    }

    /// Ctrl+Tab: moves the keyboard between the panels and the terminal.
    func switchTerminalFocus() {
        if terminalIsFocused {
            activate(active)
        } else if let view = terminalPane.current?.view, !terminalPane.isHidden {
            window?.makeFirstResponder(view)
        } else {
            showTerminal()
        }
    }

    /// Follows the panel only where it is safe: an idle local shell. A remote one gets its cd on F9,
    /// because nothing here can tell whether it is at a prompt or inside a program.
    private func panelPathChanged(_ panel: PanelController) {
        updateFavoriteToggle()
        guard !terminalPane.isHidden, !terminalIsPinned, panel === active, let target = terminalTarget(for: panel) else { return }
        guard let session = terminalPane.runningSession(for: target) else {
            if window?.firstResponder === panel.table { presentTerminal(for: panel) }
            return
        }
        if session.isLocalShellIdle { session.changeDirectory(panel.path) }
    }

    private func clampedTerminalHeight(_ height: CGFloat) -> CGFloat {
        let available = (window?.contentView?.bounds.height ?? 800) - 260
        return min(max(height, Self.minimumTerminalHeight), max(available, Self.minimumTerminalHeight))
    }

    private func resizeTerminal(by delta: CGFloat) {
        terminalHeight.constant = clampedTerminalHeight(terminalHeight.constant - delta)
        UserDefaults.standard.set(Double(terminalHeight.constant), forKey: "terminalHeight")
    }

    @objc func toggleTerminalPane(_ sender: Any?) {
        if terminalPane.isHidden { showTerminal() } else { hideTerminal() }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.attachedSheet == nil else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            guard event.keyCode == 48, flags == .control else { return event }
            self.switchTerminalFocus()
            return nil
        }
    }

    /// Shift+F9: the separate Terminal app.
    private func openTerminal() {
        let panel = active
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        let finish: (NSRunningApplication?, Error?) -> Void = { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.showError(error.localizedDescription) } }
        }
        guard let site = panel.site else {
            NSWorkspace.shared.open([URL(fileURLWithPath: panel.path, isDirectory: true)], withApplicationAt: terminal, configuration: configuration, completionHandler: finish)
            return
        }
        guard site.proto == .ssh else {
            showToast(L10n.t("terminal.noShell"))
            return
        }
        guard let client = panel.source as? SSHClient else { return }
        // Terminal runs .command files, which opens the session without any extra permission.
        // The saved password stays out of this file, so ssh asks for it there.
        let arguments = client.shellInvocation(directory: panel.path).arguments
        let script = "#!/bin/sh\nrm -f \"$0\"\nexec /usr/bin/ssh \(arguments.map(SSHClient.shellQuote).joined(separator: " "))\n"
        let file = temporaryRoot.appendingPathComponent("ssh-\(UUID().uuidString).command")
        do {
            try Data(script.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration, completionHandler: finish)
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: Archives

    private func blockedByArchive(_ panel: PanelController) -> Bool {
        guard panel.isInArchive else { return false }
        showToast(L10n.t("archive.readOnly"))
        return true
    }

    /// Enter on an archive lists what is inside. An archive on a server is fetched first.
    private func openArchive(_ entry: FileEntry, kind: ArchiveKind, in panel: PanelController) {
        if panel.source.isRemote { showToast(L10n.t("status.downloading", entry.name)) }
        localCopy(of: entry, in: panel) { [weak self, weak panel] url in
            guard let self, let panel, let url else { return }
            panel.enterArchive(ArchiveSource(file: url, kind: kind), name: entry.name) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.showError(error.localizedDescription, title: L10n.t("archive.cannotOpen", entry.name))
                } else {
                    self.toast.isHidden = true
                }
            }
        }
    }

    /// Option+F5: asks for the format and name, compresses, then sends one archive to the other panel.
    private func startPack() {
        let from = active
        let to = other
        let selection = from.selection
        if selection.isEmpty || blockedByArchive(to) { return }

        let formats = ArchiveFormat.allCases
        let popup = NSPopUpButton()
        popup.autoenablesItems = false
        popup.addItems(withTitles: formats.map(\.title))
        for (index, format) in formats.enumerated() {
            popup.item(at: index)?.isEnabled = format.supports(selection)
        }
        let saved = ArchiveFormat(rawValue: UserDefaults.standard.string(forKey: "pack.format") ?? "") ?? .zip
        popup.selectItem(at: formats.firstIndex(of: saved.supports(selection) ? saved : .zip) ?? 0)

        let base: String
        if selection.count == 1 {
            base = selection[0].name
        } else {
            let folder = from.isInArchive ? "" : PathUtil.lastComponent(from.path)
            base = folder.isEmpty || folder == "/" ? "archive" : folder
        }
        let nameField = NSTextField(frame: .zero)
        let nameFor = { (format: ArchiveFormat) in "\(base).\(format.fileExtension)" }
        nameField.stringValue = nameFor(formats[popup.indexOfSelectedItem])
        let helper = PackDialogHelper { [weak popup, weak nameField] in
            guard let popup, let nameField else { return }
            nameField.stringValue = nameFor(formats[popup.indexOfSelectedItem])
        }
        popup.target = helper
        popup.action = #selector(PackDialogHelper.changed)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L10n.t("pack.format")), popup],
            [NSTextField(labelWithString: L10n.t("pack.name")), nameField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 420, height: 62)
        nameField.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let alert = NSAlert()
        alert.messageText = L10n.t("pack.title", String(selection.count))
        var names = selection.prefix(5).map(\.name).joined(separator: "\n")
        if selection.count > 5 { names += "\n" + L10n.t("copy.more", String(selection.count - 5)) }
        alert.informativeText = names + "\n\n" + L10n.t("copy.target") + ": " + to.path
        alert.accessoryView = grid
        alert.addButton(withTitle: L10n.t("pack.confirm"))
        addCancel(to: alert)
        alert.window.initialFirstResponder = nameField
        present(alert) { [weak self] button in
            withExtendedLifetime(helper) {}
            guard let self, button == 0 else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("/") else { return }
            let format = formats[popup.indexOfSelectedItem]
            UserDefaults.standard.set(format.rawValue, forKey: "pack.format")
            self.pack(selection: selection, from: from, to: to, format: format, name: name)
        }
    }

    private func pack(selection: [FileEntry], from: PanelController, to: PanelController, format: ArchiveFormat, name: String) {
        guard let window else { return }
        let source = from.source
        let directory = from.path
        let destination = to.source
        let destinationPath = to.path
        let work = temporaryRoot.appendingPathComponent("pack-\(UUID().uuidString)")
        let sheet = BusySheet(message: L10n.t("pack.working", name), cancelTitle: L10n.t("common.cancel"))
        window.beginSheet(sheet.window)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let output = try ArchiveCreator.pack(selection: selection, from: source, directory: directory, format: format, name: name, workFolder: work, isCancelled: sheet.isCancelled)
                let size = (try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let entry = FileEntry(name: name, isDirectory: false, size: Int64(size), date: Date())
                let plan = try TransferPlanner.plan(selection: [entry], from: LocalSource(), sourceDirectory: output.deletingLastPathComponent().path, to: destination, destinationDirectory: destinationPath)
                DispatchQueue.main.async {
                    guard let self else { return }
                    window.endSheet(sheet.window)
                    from.clearMarks()
                    self.packFolders.append(work)
                    self.sendPacked(plan: plan, name: name, from: from, to: to, destination: destination, size: Int64(size))
                }
            } catch {
                try? FileManager.default.removeItem(at: work)
                DispatchQueue.main.async {
                    window.endSheet(sheet.window)
                    if (error as? MCError)?.isCancelled != true { self?.showError(error.localizedDescription) }
                }
            }
        }
    }

    /// A file with the same name is never replaced without asking. Return does nothing in this dialog.
    private func sendPacked(plan: TransferPlan, name: String, from: PanelController, to: PanelController, destination: FileSource, size: Int64) {
        let send = { [weak self] in
            guard let self else { return }
            let parallel = [from.site, to.site].compactMap { $0?.parallel }.min() ?? 4
            let title = L10n.t(destination.isRemote ? "queue.toServer" : "queue.toDisk", "1") + " · " + name + " · " + Format.size(size)
            self.engine.start(plan: plan, title: title, source: LocalSource(), destination: destination, move: false, parallel: parallel)
            self.startQueueTimer()
        }
        guard let conflict = plan.conflicts.first else { return send() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("conflict.title")
        alert.informativeText = conflict.relative + "\n\n" + L10n.t("conflict.target") + ": " + Format.size(conflict.destination.size) + "  " + Format.date(conflict.destination.date)
        alert.addButton(withTitle: L10n.t("conflict.overwrite")).keyEquivalent = "o"
        addCancel(to: alert)
        present(alert) { [weak self] button in
            if button == 0 { send() } else { self?.removeFinishedPackFolders() }
        }
    }

    private func removeFinishedPackFolders() {
        guard engine.snapshots().allSatisfy(\.isFinished) else { return }
        packFolders.forEach { try? FileManager.default.removeItem(at: $0) }
        packFolders = []
    }

    // MARK: Search

    /// Option+F7 or Cmd+F: searches below the active panel's folder.
    @objc func showSearch(_ sender: Any?) {
        let panel = active
        let source = panel.source
        let title = panel.path
        let search = SearchWindowController(source: source, root: panel.path, rootTitle: title)
        search.onOpen = { [weak self, weak panel] hit in
            guard let self, let panel else { return }
            // The panel may have moved to another server since the search began.
            guard panel.source === source else { return self.showToast(L10n.t("search.panelMoved")) }
            panel.load(path: hit.directory, select: hit.entry.name)
            self.window?.makeKeyAndOrderFront(nil)
            self.activate(panel)
        }
        search.onClose = { [weak self, weak search] in
            self?.searchWindows.removeAll { $0 === search }
        }
        searchWindows.append(search)
        search.showWindow(nil)
    }

    // MARK: Favorites

    private static let favoritesChangedName = Notification.Name("macdows.favoritesChanged")

    @objc private func favoritesChanged() { reloadFavorites() }

    private func favoritesDidChange() {
        NotificationCenter.default.post(name: Self.favoritesChangedName, object: nil)
    }

    private func favoriteLocation(_ favorite: FavoriteFolder, sites: [Site]) -> String {
        guard let id = favorite.siteID else { return (favorite.path as NSString).abbreviatingWithTildeInPath }
        let name = sites.first { $0.id == id }?.name ?? "?"
        return "\(name): \(favorite.path)"
    }

    /// The row at the top. Chips that don't fit drop off the end; F1 always lists everything.
    func reloadFavorites() {
        favoriteChips.forEach { $0.removeFromSuperview() }
        let sites = store.load()
        favoriteChips = favorites.load().enumerated().map { index, favorite in
            let chip = NSButton()
            topButton(chip, #selector(favoriteChipClicked(_:)))
            chip.title = favorite.name
            chip.tag = index
            chip.toolTip = favoriteLocation(favorite, sites: sites)
            topBar.insertArrangedSubview(chip, at: index + 1)
            topBar.setVisibilityPriority(.init(rawValue: NSStackView.VisibilityPriority.detachOnlyIfNecessary.rawValue - Float(index)), for: chip)
            return chip
        }
        updateFavoriteToggle()
    }

    private func updateFavoriteToggle() {
        let isFavorite = !active.isInArchive && favorites.find(path: active.path, siteID: active.site?.id) != nil
        favoriteToggle.title = isFavorite ? "★" : "☆"
        favoriteToggle.toolTip = L10n.t(isFavorite ? "favorites.removeCurrent" : "favorites.addCurrent")
    }

    @objc private func toggleFavoriteClicked() {
        if blockedByArchive(active) { return }
        if let existing = favorites.find(path: active.path, siteID: active.site?.id) {
            favorites.remove(id: existing.id)
        } else {
            favorites.add(path: active.path, siteID: active.site?.id)
        }
        favoritesDidChange()
    }

    @objc private func favoriteChipClicked(_ sender: NSButton) {
        let list = favorites.load()
        guard sender.tag < list.count else { return reloadFavorites() }
        go(to: list[sender.tag], in: active)
    }

    @objc private func favoriteMenuChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let favorite = favorites.load().first(where: { $0.id == id }) else { return }
        go(to: favorite, in: active)
    }

    @objc private func removeFavoriteChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        favorites.remove(id: id)
        favoritesDidChange()
    }

    func favoritesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let list = favorites.load()
        let sites = store.load()
        let currentID = favorites.find(path: active.path, siteID: active.site?.id)?.id
        for (index, favorite) in list.enumerated() {
            let item = NSMenuItem(title: "\(favorite.name)    \(favoriteLocation(favorite, sites: sites))", action: #selector(favoriteMenuChosen(_:)), keyEquivalent: index < 9 ? String(index + 1) : "")
            item.keyEquivalentModifierMask = []
            item.target = self
            item.representedObject = favorite.id
            item.state = favorite.id == currentID ? .on : .off
            menu.addItem(item)
        }
        if list.isEmpty {
            let empty = NSMenuItem(title: L10n.t("favorites.empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: L10n.t(currentID == nil ? "favorites.addCurrent" : "favorites.removeCurrent"), action: #selector(toggleFavoriteClicked), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        if !list.isEmpty {
            let removal = NSMenu()
            removal.autoenablesItems = false
            for favorite in list {
                let item = NSMenuItem(title: "\(favorite.name)    \(favoriteLocation(favorite, sites: sites))", action: #selector(removeFavoriteChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = favorite.id
                removal.addItem(item)
            }
            let holder = NSMenuItem(title: L10n.t("favorites.remove"), action: nil, keyEquivalent: "")
            holder.submenu = removal
            menu.addItem(holder)
        }
        return menu
    }

    /// F1: the list opens over the active panel, and the favorite goes to that panel.
    private func showFavoritesMenu() {
        guard window?.attachedSheet == nil else { return }
        reloadFavorites()
        let view = active.view
        favoritesMenu().popUp(positioning: nil, at: NSPoint(x: 24, y: view.bounds.height - 40), in: view)
    }

    /// Opens a favorite, changing to local disk or connecting to its server when the panel is elsewhere.
    func go(to favorite: FavoriteFolder, in panel: PanelController) {
        let failed: (Error?) -> Void = { [weak self, weak panel] error in
            guard let self, let panel else { return }
            if let error {
                self.showError(error.localizedDescription)
            } else {
                self.toast.isHidden = true
                self.activate(panel)
            }
        }
        if favorite.siteID == panel.site?.id && !panel.isInArchive {
            panel.load(path: favorite.path, select: nil, completion: failed)
        } else if let id = favorite.siteID {
            guard let site = store.load().first(where: { $0.id == id }) else {
                showToast(L10n.t("favorites.siteGone"))
                return
            }
            showToast(L10n.t("sites.connecting", site.name))
            let source = SourceFactory.make(site: site, password: store.password(for: id))
            panel.connect(site: site, source: source, path: favorite.path, completion: failed)
        } else {
            panel.connect(site: nil, source: LocalSource(), path: favorite.path, completion: failed)
        }
    }

    // MARK: Servers

    private func openSiteManager(for panel: PanelController) {
        guard let window, window.attachedSheet == nil else { return }
        let manager = SiteManagerController(store: store, currentSiteID: panel.site?.id)
        siteManager = manager
        manager.onFinish = { [weak self, weak panel] result in
            guard let self, let panel else { return }
            self.siteManager = nil
            switch result {
            case .cancelled, .saved:
                break
            case .localDisk:
                panel.connect(site: nil, source: LocalSource(), path: FileManager.default.homeDirectoryForCurrentUser.path)
            case .connect(let site, let password):
                self.showToast(L10n.t("sites.connecting", site.name))
                let source = SourceFactory.make(site: site, password: password)
                panel.connect(site: site, source: source, path: site.path) { error in
                    if let error {
                        self.showError(error.localizedDescription, title: L10n.t("sites.connectFailed", site.name))
                    } else {
                        self.toast.isHidden = true
                        self.activate(panel)
                    }
                }
            }
        }
        if let sheet = manager.window { window.beginSheet(sheet) }
    }

    // MARK: Window

    func windowDidBecomeKey(_ notification: Notification) { refreshActive() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard engine.snapshots().contains(where: { !$0.isFinished }) else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.t("close.title")
        alert.informativeText = L10n.t("close.text")
        addCancel(to: alert)
        let confirm = alert.addButton(withTitle: L10n.t("close.confirm"))
        confirm.keyEquivalent = ""
        present(alert) { [weak self] button in
            guard button == 1, let self else { return }
            self.engine.cancelAll()
            self.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        terminalPane.stopAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        queueTimer?.invalidate()
        editTimer?.invalidate()
        toastTimer?.invalidate()
        viewers.forEach { $0.close() }
        searchWindows.forEach { $0.close() }
        try? FileManager.default.removeItem(at: temporaryRoot)
        onClose?()
    }
}

/// Lets the format popup change the name field while the dialog is open.
private final class PackDialogHelper: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func changed() { action() }
}

/// Small sheet with a spinner, for work that can be cancelled.
private final class BusySheet: NSObject {
    let window: NSWindow
    private let lock = NSLock()
    private var cancelled = false

    init(message: String, cancelTitle: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 92), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: message)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spinner, label])
        let button = NSButton(title: cancelTitle, target: self, action: #selector(cancel))
        button.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [row, button])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            ])
        }
    }

    @objc private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    /// Safe to pass to background work, and keeps the sheet alive until that work ends.
    var isCancelled: () -> Bool {
        { [self] in
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
    }
}

extension RichEditorController {
    /// Saving refreshes the panel it was opened from.
    fileprivate func configured(by controller: MainWindowController, panel: PanelController) -> RichEditorController {
        onSaved = { [weak panel] in panel?.reload() }
        onMessage = { [weak controller] in controller?.showToast($0) }
        return self
    }
}
