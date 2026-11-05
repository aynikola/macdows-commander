import AppKit
import XCTest
import MacdowsCore
@testable import MacdowsCommander

final class EditorWindowTests: XCTestCase {
    private var folder: URL!
    private var editors: [EditorWindowController] = []

    override func setUpWithError() throws {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        folder = URL(fileURLWithPath: "/tmp/mced-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        editors.forEach { $0.close() }
        editors = []
        try FileManager.default.removeItem(at: folder)
    }

    private func spin(_ what: String, timeout: TimeInterval = 10, until: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if until() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out: \(what)")
    }

    private func open(_ name: String, _ content: Data, source: FileSource? = nil) throws -> (EditorWindowController, URL) {
        let url = folder.appendingPathComponent(name)
        try content.write(to: url)
        let target = EditorWindowController.Target(name: name, path: url.path, source: source, queue: DispatchQueue(label: "editor.test"))
        let editor = EditorWindowController(target: target, document: try XCTUnwrap(EditorDocument.decode(content)), stamp: EditorWindowController.currentStamp(of: target))
        editors.append(editor)
        return (editor, url)
    }

    private func key(_ editor: EditorWindowController, _ letter: String, _ flags: NSEvent.ModifierFlags, code: UInt16 = 0) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: editor.window!.windowNumber, context: nil, characters: letter, charactersIgnoringModifiers: letter, isARepeat: false, keyCode: code)!
        return editor.handleKey(event)
    }

    private func save(_ editor: EditorWindowController) -> Bool {
        var result: Bool?
        editor.save { result = $0 }
        spin("save") { result != nil }
        return result ?? false
    }

    func testCtrlAndCmdLineCommandsWithUndo() throws {
        let (editor, _) = try open("a.php", Data("one\ntwo\n".utf8))
        XCTAssertTrue(key(editor, "d", .control))
        XCTAssertEqual(editor.textView.string, "one\none\ntwo\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02)) // Each key press is its own undo step.
        XCTAssertTrue(key(editor, "l", .command))
        XCTAssertEqual(editor.textView.string, "one\ntwo\n")
        XCTAssertTrue(editor.isDirty)
        XCTAssertTrue(key(editor, "z", .control))
        XCTAssertEqual(editor.textView.string, "one\none\ntwo\n", "undo brings the line back")
        XCTAssertFalse(key(editor, "c", .command), "other keys are left alone")
    }

    func testFindAndReplaceWithCtrlF() throws {
        let (editor, _) = try open("a.js", Data("foo bar\nFOO foo\n".utf8))
        XCTAssertTrue(key(editor, "f", .control))
        editor.findField.stringValue = "foo"
        editor.refreshMatches(jump: true)
        XCTAssertEqual(editor.matches.count, 3)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 0, length: 3))
        editor.moveMatch(forward: true)
        XCTAssertEqual(editor.textView.selectedRange().location, 8)
        editor.moveMatch(forward: false)
        XCTAssertEqual(editor.textView.selectedRange().location, 0)
        XCTAssertTrue(key(editor, "h", .control))
        editor.replaceField.stringValue = "qq"
        editor.replaceCurrent()
        XCTAssertEqual(editor.textView.string, "qq bar\nFOO foo\n")
        XCTAssertEqual(editor.matches.count, 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        editor.replaceAll()
        XCTAssertEqual(editor.textView.string, "qq bar\nqq qq\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.string, "qq bar\nFOO foo\n", "one undo takes back replace all")
    }

    func testSyntaxErrorAppearsAndClears() throws {
        let (editor, _) = try open("a.js", Data("var a = ;\n".utf8))
        spin("error found") { editor.report.issues.first?.line == 1 }
        editor.textView.insertText("", replacementRange: NSRange(location: 0, length: 0))
        editor.textView.setSelectedRange(NSRange(location: 8, length: 0))
        editor.textView.insertText("1", replacementRange: NSRange(location: 8, length: 0))
        spin("error gone") { editor.report.didCheck && editor.report.issues.isEmpty }
    }

    func testColorsArePainted() throws {
        let (editor, _) = try open("a.php", Data("<?php\n$name = 'x';\n".utf8))
        XCTAssertTrue(editor.tokens.contains { $0.kind == .variable })
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        editor.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        NotificationCenter.default.post(name: .appFontChanged, object: nil)
        let color = editor.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 6, effectiveRange: nil)
        XCTAssertNotNil(color, "the variable is colored on screen")
    }

    func testSaveKeepsEncodingLineEndingsAndPermissions() throws {
        let original = Data("a\r\nb\r\n".utf8)
        let (editor, url) = try open("a.txt", original)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        editor.textView.insertText("z", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(save(editor))
        XCTAssertEqual(try Data(contentsOf: url), Data("za\r\nb\r\n".utf8))
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o640)
    }

    func testNeverOverwritesOutsideChangeWithoutAsking() throws {
        let (editor, url) = try open("a.txt", Data("mine".utf8))
        try Data("theirs, longer".utf8).write(to: url)
        var asked = 0
        editor.confirmOverwrite = { answer in
            asked += 1
            answer(false)
        }
        editor.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertFalse(save(editor))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "theirs, longer")
        XCTAssertTrue(editor.isDirty)
        editor.confirmOverwrite = { $0(true) }
        XCTAssertTrue(save(editor))
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "xmine")
    }

    /// The upload path, through the same FileSource calls a server uses.
    func testSavingThroughASourceUploadsAndNoticesChanges() throws {
        let (editor, url) = try open("a.php", Data("<?php\n".utf8), source: LocalSource())
        editor.textView.insertText("#", replacementRange: NSRange(location: 6, length: 0))
        XCTAssertTrue(save(editor))
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "<?php\n#")
        XCTAssertFalse(editor.isDirty)
        try Data("changed on the server".utf8).write(to: url)
        editor.confirmOverwrite = { $0(false) }
        editor.textView.insertText("#", replacementRange: NSRange(location: 6, length: 0))
        XCTAssertFalse(save(editor))
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "changed on the server")
    }

    func testGoToLine() throws {
        let (editor, _) = try open("a.txt", Data("one\ntwo\nthree\n".utf8))
        editor.goToLine(2)
        XCTAssertEqual(editor.textView.selectedRange().location, 4)
        editor.goToLine(3, column: 3)
        XCTAssertEqual(editor.textView.selectedRange().location, 10)
        editor.goToLine(1, column: 99)
        XCTAssertEqual(editor.textView.selectedRange().location, 3, "stops at the end of the line")
        editor.goToLine(500)
        XCTAssertEqual(editor.textView.selectedRange().location, 14, "stops at the last line")
        editor.goToLine(0)
        XCTAssertEqual(editor.textView.selectedRange().location, 0)
        XCTAssertEqual(EditorWindowController.parseLocation(" 12 ")?.line, 12)
        XCTAssertEqual(EditorWindowController.parseLocation("12:5")?.column, 5)
        XCTAssertNil(EditorWindowController.parseLocation("abc"))
        XCTAssertNil(EditorWindowController.parseLocation("1:2:3"))
    }

    func testSnapshot() throws {
        guard let out = ProcessInfo.processInfo.environment["MC_SNAPSHOT"] else { throw XCTSkip("needs MC_SNAPSHOT") }
        let code = "<?php\n// Giriş\n$ad = \"Ali $x\";\nfunction f($a) { return $a + 1; }\nif ($a {\n?>\n<div class=\"kutu\" id='a'>\n  <script>\n    const n = /ab+/g; // yorum\n    run(`v${n}`);\n  </script>\n  <style>p { color: #fff; }</style>\n</div>\n"
        let (editor, _) = try open("ornek.php", Data(code.utf8))
        editor.showFind(replacing: true)
        editor.findField.stringValue = "run"
        editor.refreshMatches(jump: true)
        spin("checked") { editor.report.didCheck }
        let view = editor.window!.contentView!
        view.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: .appFontChanged, object: nil)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}
