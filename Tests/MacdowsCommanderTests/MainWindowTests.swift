import AppKit
import XCTest
import MacdowsCore
@testable import MacdowsCommander

/// Drives the real window controller without ever showing the window.
final class MainWindowTests: XCTestCase {
    private var root: URL!
    private var controller: MainWindowController!

    private func spin(_ what: String, timeout: TimeInterval = 10, until: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if until() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Timed out: \(what)")
    }

    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    override func setUpWithError() throws {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        UserDefaults.standard.removeObject(forKey: "favorites.v1")
        root = URL(fileURLWithPath: "/tmp/mc-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        for folder in ["one", "two"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: root.appendingPathComponent("file.txt"))
        controller = MainWindowController()
        for panel in [controller.left, controller.right] {
            var loaded = false
            panel.load(path: root.path, select: nil) { _ in loaded = true }
            spin("panel loaded") { loaded }
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }

    override func tearDownWithError() throws {
        controller.window?.close()
        UserDefaults.standard.removeObject(forKey: "favorites.v1")
        try? FileManager.default.removeItem(at: root)
    }

    /// The rows of a panel: "..", one, two, file.txt.
    func testRightClickMarksTheFileUnderTheMouse() throws {
        let table = controller.left.table
        table.layoutSubtreeIfNeeded()
        let index = try XCTUnwrap(controller.left.rows.firstIndex { $0.name == "file.txt" })
        let point = table.convert(NSPoint(x: 60, y: table.rect(ofRow: index).midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        table.rightMouseDown(with: event)
        XCTAssertEqual(controller.left.marked, ["file.txt"])
        XCTAssertEqual(table.selectedRow, index)
        table.rightMouseDown(with: event)
        XCTAssertTrue(controller.left.marked.isEmpty)
    }

    func testF9OpensTerminalAndCtrlTabMovesTheKeyboard() throws {
        let window = try XCTUnwrap(controller.window)
        window.makeFirstResponder(controller.left.table)
        controller.left.table.keyDown(with: key(101))
        XCTAssertFalse(controller.terminalPane.isHidden)
        XCTAssertTrue(controller.terminalIsFocused)
        let session = try XCTUnwrap(controller.terminalPane.current)
        spin("shell at prompt") { session.isLocalShellIdle }

        window.layoutIfNeeded()
        let terminal = session.view.getTerminal()
        XCTAssertGreaterThan(terminal.rows, 5, "The pane must give the shell real room")

        controller.switchTerminalFocus()
        XCTAssertFalse(controller.terminalIsFocused)
        XCTAssertTrue(window.firstResponder === controller.left.table)

        // Moving the panel moves an idle local shell too.
        var loaded = false
        controller.left.load(path: root.appendingPathComponent("one").path, select: nil) { _ in loaded = true }
        spin("panel moved") { loaded }
        XCTAssertEqual(session.directory, root.appendingPathComponent("one").path)

        // Hiding keeps the shell, and F9 brings the same one back.
        controller.toggleTerminalPane(nil)
        XCTAssertTrue(controller.terminalPane.isHidden)
        XCTAssertTrue(session.isRunning)
        controller.left.table.keyDown(with: key(101))
        XCTAssertTrue(controller.terminalPane.current === session)
    }

    func testFavoritesToggleChipsAndGo() throws {
        controller.window?.makeFirstResponder(controller.left.table)
        let one = root.appendingPathComponent("one").path
        var loaded = false
        controller.left.load(path: one, select: nil) { _ in loaded = true }
        spin("in folder") { loaded }

        let toggle = try XCTUnwrap(controller.favoritesMenu().items.first { $0.title == "favorites.addCurrent" || $0.action != nil && $0.representedObject == nil })
        NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        let saved = FavoritesStore().load()
        XCTAssertEqual(saved.map(\.path), [one])
        XCTAssertNotNil(controller.favoritesMenu().items.first { $0.representedObject as? UUID == saved[0].id })

        var moved = false
        controller.left.load(path: root.path, select: nil) { _ in moved = true }
        spin("moved away") { moved }
        controller.go(to: saved[0], in: controller.left)
        spin("favorite opened") { self.controller.left.path == one }
    }

    func testEnterOpensArchiveAndGoingUpReturns() throws {
        let archive = root.appendingPathComponent("paket.zip")
        try ArchiveCreator.create(format: .zip, names: ["file.txt", "two"], in: root.path, output: archive, isCancelled: { false })
        let panel = controller.left
        controller.window?.makeFirstResponder(panel.table)
        var loaded = false
        panel.load(path: root.path, select: "paket.zip") { _ in loaded = true }
        spin("listed") { loaded }
        XCTAssertEqual(panel.cursorEntry?.name, "paket.zip")

        panel.table.keyDown(with: key(36))
        spin("inside archive") { panel.isInArchive && panel.path == "/" && panel.rows.contains { $0.name == "file.txt" } }
        XCTAssertEqual(panel.rows.first?.name, "..")
        XCTAssertEqual(panel.path, "/")

        // Nothing can change inside: F8 and F7 stop at a notice instead of opening a dialog.
        panel.moveCursor(to: 1)
        panel.table.keyDown(with: key(100))
        panel.table.keyDown(with: key(98))
        XCTAssertNil(controller.window?.attachedSheet)

        // ".." at the top goes back, with the cursor on the archive.
        panel.table.keyDown(with: key(51))
        spin("back in folder") { !panel.isInArchive && panel.path == self.root.path }
        spin("cursor on archive") { panel.cursorEntry?.name == "paket.zip" }
    }

    func testFavoriteOpensLocalFolderFromInsideArchive() throws {
        let archive = root.appendingPathComponent("p.tar")
        try ArchiveCreator.create(format: .tar, names: ["file.txt"], in: root.path, output: archive, isCancelled: { false })
        let panel = controller.left
        var entered = false
        panel.enterArchive(ArchiveSource(file: archive, kind: .tarLike), name: "p.tar") { _ in entered = true }
        spin("inside") { entered }
        let one = root.appendingPathComponent("one").path
        controller.go(to: FavoriteFolder(name: "one", path: one, siteID: nil), in: panel)
        spin("left archive") { !panel.isInArchive && panel.path == one }
    }

    func testBadArchiveShowsNoEntriesAndStaysPut() throws {
        let bad = root.appendingPathComponent("yok.zip")
        let panel = controller.left
        var failure: Error?
        var finished = false
        panel.enterArchive(ArchiveSource(file: bad, kind: .tarLike), name: "yok.zip") { error in
            failure = error
            finished = true
        }
        spin("failed") { finished }
        XCTAssertNotNil(failure)
        XCTAssertFalse(panel.isInArchive)
        XCTAssertEqual(panel.path, root.path)
    }

    /// Off-screen picture for checking the layout by eye: set MC_SNAPSHOT to a file path.
    func testSnapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["MC_SNAPSHOT"] else { throw XCTSkip("MC_SNAPSHOT is not set") }
        let favorites = FavoritesStore()
        ["htdocs", "ab-code", "images", "backup"].forEach { favorites.add(path: "/tmp/\($0)", siteID: nil) }
        controller.reloadFavorites()
        controller.window?.makeFirstResponder(controller.left.table)
        controller.left.table.keyDown(with: key(101))
        let session = try XCTUnwrap(controller.terminalPane.current)
        spin("prompt") { session.isLocalShellIdle }
        session.view.send(txt: "echo merhaba\r")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let view = try XCTUnwrap(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: image)
        }
        try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func testF11SharesMarkedFilesOrTheOneUnderTheCursor() throws {
        var shared: [URL] = []
        controller.presentShare = { shared = $0 }
        let panel = controller.left
        panel.select(name: "file.txt")
        panel.table.keyDown(with: key(103))
        XCTAssertEqual(shared.map(\.lastPathComponent), ["file.txt"])
        XCTAssertEqual(controller.functionButtonKeys.contains("F11"), true)
        panel.table.keyDown(with: key(114))
        XCTAssertFalse(panel.marked.isEmpty, "Ins marks it")
        let marked = panel.marked
        panel.select(name: "..")
        panel.table.keyDown(with: key(103))
        XCTAssertEqual(Set(shared.map(\.lastPathComponent)), marked, "marked files win over the cursor")
    }

    func testOpenSameShowsTheActivePanelsFolderInTheOther() throws {
        let sub = root.appendingPathComponent("baska")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let before = controller.right.path
        var done = false
        controller.left.load(path: sub.path, select: nil) { _ in done = true }
        spin("left loaded") { done }
        XCTAssertNotEqual(before, sub.path)
        controller.activate(controller.left)
        controller.left.table.keyDown(with: key(120))
        spin("right follows") { controller.right.path == sub.path }
        XCTAssertTrue(controller.right.source === controller.left.source)
    }

    func testShiftF7MakesAFileAndNeverOverwrites() throws {
        var answer = ("yeni", NewFileKind.md)
        controller.askNewFile = { $0(answer.0, answer.1) }
        controller.active.table.keyDown(with: key(98, flags: .shift))
        let path = URL(fileURLWithPath: controller.active.path).appendingPathComponent("yeni.md")
        spin("created") { FileManager.default.fileExists(atPath: path.path) }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "# yeni\n\n")
        spin("opened") { EditorWindowController.existing(path: path.path, source: nil) != nil }
        EditorWindowController.existing(path: path.path, source: nil)?.close()

        try "dolu".write(to: path, atomically: true, encoding: .utf8)
        answer = ("yeni.md", .txt)
        controller.active.table.keyDown(with: key(98, flags: .shift))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        NSApp.windows.compactMap(\.attachedSheet).forEach { $0.sheetParent?.endSheet($0) }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "dolu")
    }

    func testCompareTakesTheSameNameInTheOtherPanel() throws {
        let other = root.appendingPathComponent("karsi")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "x\ny\n".write(to: other.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        var done = false
        controller.right.load(path: other.path, select: nil) { _ in done = true }
        spin("right loaded") { done }
        controller.activate(controller.left)
        controller.left.select(name: "file.txt")
        let pair = try XCTUnwrap(controller.comparePair())
        XCTAssertEqual(pair.first.0.name, "file.txt")
        XCTAssertTrue(pair.second.1 === controller.right)
        var shown: CompareWindowController?
        controller.onCompared = { shown = $0 }
        controller.left.table.keyDown(with: key(99, flags: .option))
        spin("compared") { shown != nil }
        XCTAssertFalse(try XCTUnwrap(shown).changes.isEmpty)
        shown?.moveChange(by: 1)
        XCTAssertEqual(shown?.currentChange, 0, "one change wraps round to itself")
        shown?.close()
    }

    func testShiftClickMarksARangeAndCtrlAMarksAll() throws {
        let panel = controller.left
        for name in ["r1.txt", "r2.txt", "r3.txt"] { try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        var done = false
        panel.load(path: panel.path, select: "r1.txt") { _ in done = true }
        spin("loaded") { done }
        let last = try XCTUnwrap(panel.rows.firstIndex { $0.name == "r3.txt" })
        panel.markRange(to: last)
        XCTAssertEqual(panel.marked, ["r1.txt", "r2.txt", "r3.txt"])
        XCTAssertEqual(panel.cursorEntry?.name, "r3.txt")
        panel.clearMarks()
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, characters: "\u{01}", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        panel.table.keyDown(with: event)
        XCTAssertEqual(panel.marked, Set(panel.rows.map(\.name).filter { $0 != ".." }))
        XCTAssertFalse(panel.marked.contains(".."))
        panel.table.keyDown(with: event)
        XCTAssertTrue(panel.marked.isEmpty, "again clears them")
    }

    func testGitButtonsAreListedAndChangesWaitForEnter() {
        let commands = Dictionary(uniqueKeysWithValues: TerminalPane.gitCommands.map { ($0.title, $0) })
        for title in ["status", "diff", "log", "branch"] { XCTAssertEqual(commands[title]?.run, true, title) }
        for title in ["add .", "commit", "pull", "push", "switch"] { XCTAssertEqual(commands[title]?.run, false, title) }
    }

    func testF4OpensTheBuiltInEditorOnce() {
        UserDefaults.standard.removeObject(forKey: "editorBuiltIn")
        let panel = controller.left
        panel.select(name: "file.txt")
        panel.table.keyDown(with: key(118))
        spin("editor opened") { !EditorWindowController.openEditors.isEmpty }
        let editor = EditorWindowController.openEditors[0]
        defer { editor.close() }
        XCTAssertEqual(editor.textView.string, "x")
        panel.table.keyDown(with: key(118))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(EditorWindowController.openEditors.count, 1, "the same file comes to the front instead")
    }

    func testSameLetterMovesToTheNextMatch() throws {
        for name in ["apple.txt", "avocado.txt", "banana.txt", "Äpfel.txt", "İzmir.txt"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let panel = controller.left
        var loaded = false
        panel.reload { _ in loaded = true }
        spin("reloaded") { loaded }
        func press(_ letter: String) -> String? {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, characters: letter, charactersIgnoringModifiers: letter, isARepeat: false, keyCode: 0)!
            panel.table.keyDown(with: event)
            return panel.cursorEntry?.name
        }
        panel.moveCursor(to: 0)
        XCTAssertEqual(press("a"), "apple.txt")
        XCTAssertEqual(press("a"), "avocado.txt", "the same letter goes on")
        XCTAssertEqual(press("a"), "apple.txt", "and wraps around")
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertEqual(press("a"), "avocado.txt", "a pause still moves on")
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertEqual(press("b"), "banana.txt")
        XCTAssertEqual(press("a"), "banana.txt", "another letter narrows the search")
        XCTAssertEqual(press("n"), "banana.txt")
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertEqual(press("i"), "İzmir.txt", "Turkish letters match")
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertEqual(press("q"), "İzmir.txt", "no match leaves the cursor")
    }

    func testManualHasEveryLanguageAndRenders() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        for language in ["en", "tr"] {
            let text = try String(contentsOf: resources.appendingPathComponent("\(language).lproj/Manual.txt"), encoding: .utf8)
            for key in ["⌥F1", "⌥F5", "⌥F7", "⌘K", "⌃G"] { XCTAssertTrue(text.contains(key), "\(language) lacks \(key)") }
            let rendered = HelpWindowController.render(text).string
            XCTAssertFalse(rendered.contains(" | "))
            XCTAssertFalse(rendered.contains("# "))
        }
    }

    func testDefaultFontsExistAndDatesFit() throws {
        UserDefaults.standard.removeObject(forKey: "font.family")
        XCTAssertEqual(AppFont.list().familyName, "Verdana", "not San Francisco")
        XCTAssertEqual(AppFont.mono.familyName, "Menlo")
        for family in AppFont.families where family != AppFont.systemFamily {
            XCTAssertEqual(NSFont(name: family, size: 14)?.familyName, family)
        }
        let column = try XCTUnwrap(controller.left.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("date")))
        let width = (Format.date(Date()) as NSString).size(withAttributes: [.font: AppFont.digits]).width
        XCTAssertLessThan(width, column.width)
    }

    func testSSHMenuListsSavedServers() {
        let store = SiteStore()
        let saved = store.load()
        defer { store.save(saved) }
        let hop = Site(name: "Gecit", proto: .ssh, host: "gate", user: "a")
        let target = Site(name: "Hacettepe", proto: .ssh, host: "h.example", user: "b", keyFile: "/k/lab.pem", jumpSiteID: hop.id)
        store.save([hop, target, Site(name: "FtpOnly", proto: .ftp, host: "f")])
        let titles = controller.sshMenu().items.map(\.title)
        XCTAssertTrue(titles.contains { $0.contains("Hacettepe") && $0.contains("b@h.example") && $0.contains("lab.pem") && $0.contains("Gecit") }, "\(titles)")
        XCTAssertFalse(titles.contains { $0.contains("FtpOnly") }, "FTP has no shell")
        XCTAssertEqual(controller.sshMenu().items[1].keyEquivalent, "2")
    }
}
