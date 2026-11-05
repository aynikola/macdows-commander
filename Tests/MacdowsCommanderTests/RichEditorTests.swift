import AppKit
import XCTest
import MacdowsCore
@testable import MacdowsCommander

final class RichEditorTests: XCTestCase {
    private var folder: URL!
    private var editors: [RichEditorController] = []

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: "/tmp/mcrich-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        editors.forEach { $0.markClean(); $0.close() }
        editors = []
        try FileManager.default.removeItem(at: folder)
    }

    private func spin(_ what: String, timeout: TimeInterval = 20, until: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if until() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out: \(what)")
    }

    private func open(_ html: String?, name: String = "a.html") throws -> (RichEditorController, URL) {
        let queue = DispatchQueue(label: "rich.test")
        let url = folder.appendingPathComponent(name)
        let editor: RichEditorController
        if let html {
            try Data(html.utf8).write(to: url)
            let target = EditorWindowController.Target(name: name, path: url.path, source: nil, queue: queue)
            editor = RichEditorController(target: target, file: EditorDocument.decode(Data(html.utf8)), stamp: EditorWindowController.currentStamp(of: target), folder: folder.path, source: nil, queue: queue)
        } else {
            editor = RichEditorController(target: nil, file: nil, stamp: nil, folder: folder.path, source: nil, queue: queue)
        }
        editors.append(editor)
        var loaded = false
        editor.onLoaded = { loaded = true }
        spin("page loaded") { loaded }
        return (editor, url)
    }

    private func run(_ editor: RichEditorController, _ code: String) -> Any? {
        var done = false
        var value: Any?
        editor.evaluate(code) { value = $0; done = true }
        spin("script") { done }
        return value
    }

    private func save(_ editor: RichEditorController) -> Bool {
        var result: Bool?
        editor.save { result = $0 }
        spin("save") { result != nil }
        return result ?? false
    }

    func testBoldHeadingListTableAndBoxesEditThePage() throws {
        let (editor, url) = try open("<html><head><title>t</title></head><body><article class=\"theme-balmy\"><p>merhaba dünya</p></article></body></html>")
        _ = run(editor, "mc.run('selectAll')")
        editor.runCommand(0)
        spin("bold") { (run(editor, "mc.html()") as? String)?.contains("<b>") == true }
        spin("marked dirty") { editor.isDirty }
        _ = run(editor, "window.getSelection().collapseToEnd()")
        editor.runCommand(12)
        spin("table") { (run(editor, "mc.html()") as? String)?.contains("table-wrapper") == true }
        _ = run(editor, "mc.box('callout-box box-green')")
        spin("box") { (run(editor, "mc.html()") as? String)?.contains("callout-box box-green") == true }
        XCTAssertTrue(save(editor))
        let saved = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(saved.hasPrefix("<html><head><title>t</title></head><body><article class=\"theme-balmy\">"))
        XCTAssertTrue(saved.contains("merhaba dünya"))
        XCTAssertTrue(saved.hasSuffix("</article></body></html>"))
        XCTAssertFalse(saved.contains("contenteditable"), "editing state stays out of the file")
        XCTAssertFalse(editor.isDirty)
    }

    func testPageScriptsDoNotRun() throws {
        let (editor, _) = try open("<html><body><p id=\"p\">x</p><script>document.getElementById('p').textContent = 'ran';</script></body></html>")
        XCTAssertEqual(run(editor, "document.getElementById('p').textContent") as? String, "x")
        XCTAssertEqual(run(editor, "document.body.getAttribute('contenteditable')") as? String, "true")
    }

    func testPastedStylingIsDropped() throws {
        let (editor, _) = try open("<html><body><p>x</p></body></html>")
        _ = run(editor, """
        (() => { const d = new DataTransfer(); d.setData('text/html', '<h2 style="color:red" onclick="x()">B<span style="font-size:40px">aş</span></h2><script>bad()<\\/script>');
        d.setData('text/plain', 'Baş'); document.body.dispatchEvent(new ClipboardEvent('paste', {clipboardData: d, bubbles: true, cancelable: true})); })()
        """)
        spin("pasted") { (run(editor, "mc.html()") as? String)?.contains("Baş") == true }
        let html = run(editor, "mc.html()") as? String ?? ""
        XCTAssertTrue(html.contains("<h2>Baş</h2>"), html)
        XCTAssertFalse(html.contains("style="))
        XCTAssertFalse(html.contains("bad()"))
    }

    private let tablePage = """
    <!doctype html><html><body><article class="theme-balmy"><h1>T</h1><div class="table-wrapper"><table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td id="c">1</td><td>2</td></tr><tr><td>3</td><td>4</td></tr></tbody></table></div><p>Son</p></article></body></html>
    """

    /// The table's cells by row, as text.
    private func cells(_ editor: RichEditorController) -> [[String]] {
        run(editor, "Array.from(document.querySelectorAll('article table tr')).map(r => Array.from(r.cells).map(c => c.textContent))") as? [[String]] ?? []
    }

    private func putCursor(_ editor: RichEditorController, row: Int, cell: Int) {
        _ = run(editor, "(() => { const c = document.querySelector('article table').rows[\(row)].cells[\(cell)]; const r = document.createRange(); r.selectNodeContents(c); r.collapse(true); const s = getSelection(); s.removeAllRanges(); s.addRange(r); document.querySelector('article').focus(); return 1; })()")
    }

    private func table(_ editor: RichEditorController, _ action: String) -> Any? {
        run(editor, "mc.tableEdit('\(action)')")
    }

    func testTableRowsAndColumnsAreAddedWhereTheCursorIs() throws {
        let (editor, _) = try open(tablePage)
        putCursor(editor, row: 1, cell: 0)
        XCTAssertEqual(table(editor, "rowAbove") as? Bool, true)
        XCTAssertEqual(cells(editor), [["A", "B"], ["", ""], ["1", "2"], ["3", "4"]])
        XCTAssertEqual(run(editor, "document.querySelectorAll('article table').length") as? Int, 1, "the table is replaced, not nested")
        XCTAssertEqual(run(editor, "document.querySelector('article .table-wrapper table') !== null") as? Bool, true)
        XCTAssertEqual(run(editor, "document.querySelector('[data-mc-cursor]') === null") as? Bool, true)
        XCTAssertEqual(run(editor, "getSelection().anchorNode.closest ? getSelection().anchorNode.closest('tr').rowIndex : getSelection().anchorNode.parentNode.closest('tr').rowIndex") as? Int, 1, "the cursor goes to the new row")

        putCursor(editor, row: 2, cell: 1)
        _ = table(editor, "rowBelow")
        XCTAssertEqual(cells(editor), [["A", "B"], ["", ""], ["1", "2"], ["", ""], ["3", "4"]])

        putCursor(editor, row: 2, cell: 0)
        _ = table(editor, "columnRight")
        XCTAssertEqual(cells(editor), [["A", "", "B"], ["", "", ""], ["1", "", "2"], ["", "", ""], ["3", "", "4"]])
        XCTAssertEqual(run(editor, "document.querySelector('article thead tr').cells[1].tagName") as? String, "TH")

        putCursor(editor, row: 2, cell: 0)
        _ = table(editor, "columnLeft")
        XCTAssertEqual(cells(editor)[2], ["", "1", "", "2"])
        XCTAssertTrue(editor.isDirty)
    }

    func testTheTableMenuItemsRunTheirActions() throws {
        let (editor, _) = try open(tablePage)
        func popups(_ view: NSView) -> [NSPopUpButton] { (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups) }
        let all = popups(try XCTUnwrap(editor.window?.contentView))
        let menu = try XCTUnwrap(all.first { $0.itemArray.contains { $0.representedObject as? String == "rowBelow" } }?.menu)
        func choose(_ action: String) throws {
            let position = try XCTUnwrap(menu.items.firstIndex { $0.representedObject as? String == action })
            menu.performActionForItem(at: position)
            _ = run(editor, "1")
        }
        putCursor(editor, row: 1, cell: 0)
        try choose("rowBelow")
        XCTAssertEqual(cells(editor).count, 4)
        putCursor(editor, row: 1, cell: 0)
        try choose("columnRight")
        XCTAssertEqual(cells(editor)[1], ["1", "", "2"])
        putCursor(editor, row: 1, cell: 1)
        try choose("deleteColumn")
        XCTAssertEqual(cells(editor)[1], ["1", "2"])
        putCursor(editor, row: 1, cell: 0)
        try choose("deleteRow")
        XCTAssertEqual(cells(editor).count, 3)
        putCursor(editor, row: 1, cell: 0)
        try choose("deleteTable")
        XCTAssertEqual(cells(editor), [])
        try choose("new")
        XCTAssertEqual(cells(editor).count, 3, "a new table")
    }

    func testARowAddedFromTheHeaderGoesIntoTheBody() throws {
        let (editor, _) = try open(tablePage)
        putCursor(editor, row: 0, cell: 0)
        _ = table(editor, "rowBelow")
        XCTAssertEqual(cells(editor), [["A", "B"], ["", ""], ["1", "2"], ["3", "4"]])
        XCTAssertEqual(run(editor, "document.querySelectorAll('article thead tr').length") as? Int, 1)
    }

    func testTableRowsAndColumnsAreDeleted() throws {
        let (editor, _) = try open(tablePage)
        putCursor(editor, row: 1, cell: 1)
        _ = table(editor, "deleteRow")
        XCTAssertEqual(cells(editor), [["A", "B"], ["3", "4"]])
        putCursor(editor, row: 1, cell: 0)
        _ = table(editor, "deleteColumn")
        XCTAssertEqual(cells(editor), [["B"], ["4"]])
        putCursor(editor, row: 1, cell: 0)
        _ = table(editor, "deleteColumn")
        XCTAssertEqual(cells(editor), [], "the last column takes the table with it")
        XCTAssertEqual(run(editor, "document.querySelector('article .table-wrapper') === null") as? Bool, true)
        XCTAssertEqual(run(editor, "document.querySelector('article').textContent.includes('Son')") as? Bool, true)
    }

    func testDeletingTheTableAndUndoingBringsItBack() throws {
        let (editor, _) = try open(tablePage)
        putCursor(editor, row: 1, cell: 0)
        _ = table(editor, "rowBelow")
        XCTAssertEqual(cells(editor).count, 4)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        _ = run(editor, "mc.run('undo')")
        XCTAssertEqual(cells(editor), [["A", "B"], ["1", "2"], ["3", "4"]], "⌘Z undoes a table change")
        putCursor(editor, row: 1, cell: 0)
        _ = table(editor, "deleteTable")
        XCTAssertEqual(cells(editor), [])
    }

    func testTableActionOutsideATableSaysSo() throws {
        let (editor, _) = try open(tablePage)
        _ = run(editor, "(() => { const r = document.createRange(); r.selectNodeContents(document.querySelector('article h1')); getSelection().removeAllRanges(); getSelection().addRange(r); })()")
        XCTAssertEqual(table(editor, "rowBelow") as? Bool, false)
    }

    func testTableChangesAreSavedWithoutEditorMarks() throws {
        let (editor, url) = try open(tablePage)
        putCursor(editor, row: 1, cell: 0)
        _ = table(editor, "rowBelow")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(save(editor))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("data-mc"))
        XCTAssertEqual(text.components(separatedBy: "<tr").count - 1, 4)
    }

    func testNewDocumentAsksForANameAndNeverOverwritesSilently() throws {
        let (editor, _) = try open(nil)
        let existing = folder.appendingPathComponent("var.html")
        try Data("eski".utf8).write(to: existing)
        editor.askForName = { $0("var") }
        var asked = 0
        editor.confirmOverwrite = { asked += 1; $0(false) }
        XCTAssertFalse(save(editor))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(String(decoding: try Data(contentsOf: existing), as: UTF8.self), "eski")
        editor.askForName = { $0("yeni") }
        XCTAssertTrue(save(editor))
        let saved = String(decoding: try Data(contentsOf: folder.appendingPathComponent("yeni.html")), as: UTF8.self)
        XCTAssertTrue(saved.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(saved.contains("theme-balmy"))
    }

    func testNeighboringPicturesLoad() throws {
        // A 1x1 PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAEAQH/7yMK/gAAAABJRU5ErkJggg==")!
        try png.write(to: folder.appendingPathComponent("r.png"))
        let (editor, _) = try open("<html><body><img id=\"i\" src=\"r.png\"></body></html>")
        spin("image") { (run(editor, "document.getElementById('i').naturalWidth") as? Int) == 1 }
    }

    func testSnapshot() throws {
        guard let out = ProcessInfo.processInfo.environment["MC_RICH_SNAPSHOT"] else { throw XCTSkip("needs MC_RICH_SNAPSHOT") }
        let body = "<h1>Başlık</h1><h2>Alt başlık</h2><p>Bir paragraf, <b>kalın</b> ve <a href=\"#\">bağlantı</a>.</p><blockquote>Alıntı</blockquote><div class=\"callout-box box-green\">Yeşil kutu</div><div class=\"rect-header color-3\">Başlık kutusu</div><ul><li>Bir</li></ul>"
        let (editor, _) = try open(RichDocument.balmyTemplate + body + RichDocument.closing)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        var image: NSImage?
        let web = editor.window!.contentView!.subviews.compactMap { $0 as? NSView }.first { String(describing: type(of: $0)).contains("WKWebView") }
        (web as? WKWebViewSnapshot)?.snap { image = $0 }
        spin("snapshot") { image != nil }
        let rep = NSBitmapImageRep(data: image!.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        let view = editor.window!.contentView!
        let whole = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: whole)
        try whole.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + ".window.png"))
    }
}

import WebKit
private protocol WKWebViewSnapshot { func snap(_ done: @escaping (NSImage?) -> Void) }
extension WKWebView: WKWebViewSnapshot {
    fileprivate func snap(_ done: @escaping (NSImage?) -> Void) { takeSnapshot(with: nil) { image, _ in done(image) } }
}
