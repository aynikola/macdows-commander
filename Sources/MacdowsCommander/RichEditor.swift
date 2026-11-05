import AppKit
import UniformTypeIdentifiers
import WebKit
import MacdowsCore

/// An editor window with work that must not be lost when the app quits.
protocol DocumentWindow: AnyObject {
    var isDirty: Bool { get }
    func askToDiscard(_ answer: @escaping (Bool) -> Void)
    func markClean()
}

enum OpenDocuments {
    private static var all: [DocumentWindow] = []

    static func add(_ document: DocumentWindow) { all.append(document) }
    static func remove(_ document: DocumentWindow) { all.removeAll { $0 === document } }
    static var hasUnsavedWork: Bool { all.contains { $0.isDirty } }

    /// Walks through the windows with unsaved work before the app quits. False keeps the app open.
    static func confirmQuit(_ answer: @escaping (Bool) -> Void) {
        func next(_ remaining: [DocumentWindow]) {
            guard let document = remaining.first else {
                answer(true)
                return
            }
            document.askToDiscard { fine in
                if fine {
                    document.markClean()
                    next(Array(remaining.dropFirst()))
                } else {
                    answer(false)
                }
            }
        }
        next(all.filter { $0.isDirty })
    }
}

/// Serves pictures and styles next to the document, from this Mac or from the server it came from.
private final class DocumentFilesHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mcdoc"
    private let source: FileSource?
    private let queue: DispatchQueue
    private var stopped: Set<ObjectIdentifier> = []

    init(source: FileSource?, queue: DispatchQueue) {
        self.source = source
        self.queue = queue
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path
        let source = self.source
        queue.async { [weak self] in
            var data: Data?
            if let source {
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mcdoc-\(UUID().uuidString)")
                if (try? source.download(path, to: temporary) { _ in true }) != nil { data = try? Data(contentsOf: temporary) }
                try? FileManager.default.removeItem(at: temporary)
            } else {
                data = try? Data(contentsOf: URL(fileURLWithPath: path))
            }
            DispatchQueue.main.async {
                guard let self, self.stopped.remove(ObjectIdentifier(task)) == nil else { return }
                guard let data else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}

/// F10: the writing editor. The page's own scripts never run, so an HTML file off a server is safe to open;
/// the editing code below lives in a separate script world that the page can't reach.
final class RichEditorController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler, DocumentWindow {
    private(set) static var open: [RichEditorController] = []

    static func existing(path: String, source: FileSource?) -> RichEditorController? {
        open.first { $0.target?.path == path && $0.source === source }
    }

    private static let script = #"""
    (function () {
      const root = document.querySelector('article.theme-balmy') || document.body;
      root.setAttribute('contenteditable', 'true');
      root.style.outline = 'none';
      root.style.minHeight = '60vh';
      document.execCommand('defaultParagraphSeparator', false, 'p');
      const changed = () => webkit.messageHandlers.changed.postMessage(1);
      root.addEventListener('input', changed);

      const escapeText = (text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      const run = (command, value) => {
        root.focus();
        document.execCommand(command, false, value === undefined ? null : value);
      };

      const currentCell = () => {
        const selection = window.getSelection();
        if (!selection.rangeCount) return null;
        let node = selection.getRangeAt(0).startContainer;
        if (node.nodeType !== 1) node = node.parentNode;
        const cell = node.closest('td,th');
        return cell && root.contains(cell) ? cell : null;
      };
      const columnOf = (cell) => {
        let column = 0;
        for (let other = cell.previousElementSibling; other; other = other.previousElementSibling) column += other.colSpan;
        return column;
      };
      const cellAt = (row, column) => {
        for (const cell of Array.from(row.cells)) {
          const start = columnOf(cell);
          if (column >= start && column < start + cell.colSpan) return cell;
        }
        return null;
      };
      const columnCount = (table) => Math.max(...Array.from(table.rows).map((row) => Array.from(row.cells).reduce((sum, cell) => sum + cell.colSpan, 0)));
      const emptyCell = (tag) => {
        const cell = document.createElement(tag);
        cell.appendChild(document.createElement('br'));
        return cell;
      };
      const newRow = (table) => {
        const row = document.createElement('tr');
        for (let i = 0, count = columnCount(table); i < count; i++) row.appendChild(emptyCell('td'));
        return row;
      };
      const addCell = (row, column) => {
        const covering = cellAt(row, column);
        if (covering && columnOf(covering) < column) {
          covering.colSpan += 1;
          return covering;
        }
        const added = emptyCell(row.parentNode.tagName === 'THEAD' ? 'th' : 'td');
        row.insertBefore(added, covering);
        return added;
      };
      // Replaced through the editing command so that ⌘Z brings the old table back.
      const swapTable = (table, copy, cursor) => {
        cursor.setAttribute('data-mc-cursor', '1');
        root.focus();
        const range = document.createRange();
        range.selectNode(table);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        document.execCommand('insertHTML', false, copy.outerHTML);
        const placed = root.querySelector('[data-mc-cursor]');
        if (!placed) return;
        placed.removeAttribute('data-mc-cursor');
        placeCursor(placed);
      };
      const placeCursor = (cell) => {
        const range = document.createRange();
        range.selectNodeContents(cell);
        range.collapse(true);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
      };
      const removeTable = (table) => {
        root.focus();
        const holder = table.parentNode.classList && table.parentNode.classList.contains('table-wrapper') ? table.parentNode : table;
        const range = document.createRange();
        range.selectNode(holder);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        document.execCommand('delete');
        // The browser keeps the emptied wrapper around the cursor.
        for (const wrapper of Array.from(root.querySelectorAll('.table-wrapper'))) {
          if (wrapper.querySelector('table') || wrapper.textContent.trim()) continue;
          const neighbor = wrapper.nextElementSibling || wrapper.previousElementSibling;
          wrapper.remove();
          if (neighbor) placeCursor(neighbor);
        }
      };
      root.addEventListener('keydown', (event) => {
        if (event.key !== 'Tab') return;
        const cell = currentCell();
        if (!cell) return;
        event.preventDefault();
        const table = cell.closest('table');
        const cells = Array.from(table.querySelectorAll('td,th'));
        const next = cells[cells.indexOf(cell) + (event.shiftKey ? -1 : 1)];
        if (next) placeCursor(next);
        else if (!event.shiftKey) mc.tableEdit('rowBelow');
      });

      // Pasted pages bring their own styles, which would fight the theme. Structure stays, styling goes.
      function clean(html) {
        const page = new DOMParser().parseFromString(html, 'text/html');
        page.querySelectorAll('script,style,meta,link,iframe,object,embed,title').forEach((e) => e.remove());
        page.querySelectorAll('*').forEach((e) => {
          for (const attribute of Array.from(e.attributes)) {
            const keep = (e.tagName === 'A' && attribute.name === 'href' && !/^\s*javascript:/i.test(attribute.value))
              || (e.tagName === 'IMG' && (attribute.name === 'src' || attribute.name === 'alt'));
            if (!keep) e.removeAttribute(attribute.name);
          }
        });
        page.querySelectorAll('span,font').forEach((e) => e.replaceWith(...e.childNodes));
        return page.body.innerHTML;
      }
      root.addEventListener('paste', (event) => {
        const html = event.clipboardData.getData('text/html');
        const text = event.clipboardData.getData('text/plain');
        if (!html && !text) return;
        event.preventDefault();
        if (html) run('insertHTML', clean(html)); else run('insertText', text);
      });

      function selectionInside() {
        const selection = window.getSelection();
        if (!selection.rangeCount) return null;
        const range = selection.getRangeAt(0);
        return root.contains(range.commonAncestorContainer) ? range : null;
      }
      let remembered = null;

      window.mc = {
        html: () => root.innerHTML,
        run,
        block: (tag) => run('formatBlock', '<' + tag + '>'),
        insert: (html) => run('insertHTML', html),
        remember: () => { remembered = selectionInside(); },
        recall: () => {
          root.focus();
          if (!remembered) return;
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(remembered);
        },
        code: () => {
          const range = selectionInside();
          run('insertHTML', '<code>' + escapeText(range && !range.collapsed ? range.toString() : '​') + '</code>');
        },
        table: () => {
          const cell = (tag) => '<' + tag + '><br></' + tag + '>';
          const row = (tag) => '<tr>' + cell(tag) + cell(tag) + cell(tag) + '</tr>';
          run('insertHTML', '<div class="table-wrapper"><table><thead>' + row('th') + '</thead><tbody>' + row('td') + row('td') + '</tbody></table></div><p><br></p>');
        },
        // What the Table menu does at the cursor. False means the cursor is not in a table.
        tableEdit: (action) => {
          const cell = currentCell();
          if (!cell) return false;
          const table = cell.closest('table');
          const rowIndex = Array.from(table.rows).indexOf(cell.parentNode);
          const cellIndex = cell.cellIndex;
          if (action === 'deleteTable') { removeTable(table); return true; }
          const copy = table.cloneNode(true);
          const row = copy.rows[rowIndex];
          const here = row.cells[cellIndex];
          const start = columnOf(here);
          let cursor = null;
          if (action === 'rowAbove' || action === 'rowBelow') {
            const fresh = newRow(copy);
            if (row.parentNode.tagName === 'THEAD') {
              let body = copy.tBodies[0];
              if (!body) body = copy.appendChild(document.createElement('tbody'));
              body.insertBefore(fresh, body.firstChild);
            } else {
              row.parentNode.insertBefore(fresh, action === 'rowAbove' ? row : row.nextSibling);
            }
            cursor = fresh.cells[0];
          } else if (action === 'columnLeft' || action === 'columnRight') {
            const column = action === 'columnLeft' ? start : start + here.colSpan;
            for (const each of Array.from(copy.rows)) {
              const added = addCell(each, column);
              if (each === row) cursor = added;
            }
          } else if (action === 'deleteRow') {
            if (copy.rows.length === 1) { removeTable(table); return true; }
            const rows = Array.from(copy.rows);
            const next = rows[rowIndex + 1] || rows[rowIndex - 1];
            const section = row.parentNode;
            row.remove();
            if (!section.rows.length) section.remove();
            cursor = next.cells[Math.min(cellIndex, next.cells.length - 1)];
          } else if (action === 'deleteColumn') {
            if (columnCount(copy) === 1) { removeTable(table); return true; }
            for (const each of Array.from(copy.rows)) {
              const found = cellAt(each, start);
              if (!found) continue;
              if (found.colSpan > 1) found.colSpan -= 1; else found.remove();
              if (!each.cells.length) each.remove();
            }
            const left = copy.rows[Math.min(rowIndex, copy.rows.length - 1)];
            cursor = left.cells[Math.min(cellIndex, left.cells.length - 1)];
          } else {
            return false;
          }
          swapTable(table, copy, cursor);
          return true;
        },
        // Wraps the selection, or the paragraph the cursor is in, in a callout or header box.
        box: (classes) => {
          root.focus();
          const range = selectionInside();
          if (!range) return;
          if (range.collapsed) {
            let block = range.startContainer;
            while (block && block.parentNode !== root) block = block.parentNode;
            if (block) range.selectNode(block);
          }
          const holder = document.createElement('div');
          holder.appendChild(range.cloneContents());
          const window_ = window.getSelection();
          window_.removeAllRanges();
          window_.addRange(range);
          run('insertHTML', '<div class="' + classes + '">' + (holder.textContent.trim() ? holder.innerHTML : '<br>') + '</div><p><br></p>');
        },
      };
    })();
    """#

    private let webView: WKWebView
    private let handler: DocumentFilesHandler
    private var page: RichDocument
    private var encoded: EditorDocument
    private var target: EditorWindowController.Target?
    private let source: FileSource?
    private let folder: String
    private let queue: DispatchQueue
    private var stamp: EditorWindowController.Stamp?
    private var didLoad = false
    private(set) var isDirty = false
    private(set) var isSaving = false
    private var changeCount = 0
    var onLoaded: (() -> Void)?
    var onSaved: (() -> Void)?
    var onMessage: ((String) -> Void)?
    /// Replaced in tests, which have nobody to answer.
    var confirmOverwrite: ((@escaping (Bool) -> Void) -> Void)?
    var askForName: ((@escaping (String?) -> Void) -> Void)?

    /// `target` nil starts a new document, which asks for a name in `folder` on first save.
    init(target: EditorWindowController.Target?, file: EditorDocument?, stamp: EditorWindowController.Stamp?, folder: String, source: FileSource?, queue: DispatchQueue) {
        self.target = target
        self.stamp = stamp
        self.folder = folder
        self.source = source
        self.queue = queue
        page = file.map { RichDocument.parse($0.text) } ?? .starter(content: Self.demoContent())
        encoded = file ?? EditorDocument(text: "", encoding: .utf8, usesCRLF: false)
        handler = DocumentFilesHandler(source: source, queue: queue)

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(handler, forURLScheme: DocumentFilesHandler.scheme)
        configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 740), configuration: configuration)

        let window = KeyFirstWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        Theme.apply(to: window)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] in self?.handleKey($0) ?? false }
        configuration.userContentController.add(self, contentWorld: .defaultClient, name: "changed")
        webView.navigationDelegate = self
        build(in: window)
        updateTitle()
        Self.open.append(self)
        OpenDocuments.add(self)
        load()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    /// The sample a new document opens with, from Resources/<language>.lproj/WriterDemo.html.
    private static func demoContent() -> String? {
        for code in [L10n.language, "en"] {
            if let path = Bundle.main.path(forResource: "WriterDemo", ofType: "html", inDirectory: nil, forLocalization: code),
               let text = try? String(contentsOfFile: path, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    private func load() {
        var base = URLComponents()
        base.scheme = DocumentFilesHandler.scheme
        base.host = "doc"
        base.path = folder.hasSuffix("/") ? folder : folder + "/"
        webView.loadHTMLString(page.display, baseURL: base.url)
    }

    // MARK: Toolbar

    private func action(_ title: String, tip: String? = nil, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = AppFont.interface(12)
        button.refusesFirstResponder = true
        button.toolTip = tip
        return button
    }

    private func command(_ title: String, _ tag: Int, tip: String? = nil) -> NSButton {
        let button = action(title, tip: tip, #selector(commandClicked(_:)))
        button.tag = tag
        return button
    }

    private func pulldown(_ title: String, _ items: [(String, String)], _ selector: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.controlSize = .small
        popup.font = AppFont.interface(12)
        popup.refusesFirstResponder = true
        popup.addItem(withTitle: title)
        for (name, value) in items {
            popup.addItem(withTitle: name)
            popup.lastItem?.representedObject = value
            popup.lastItem?.target = self
            popup.lastItem?.action = selector
        }
        return popup
    }

    /// The commands the toolbar and keys can run, as calls into the page's editing script.
    private static let commands: [String] = [
        "mc.run('bold')", "mc.run('italic')", "mc.run('underline')",
        "mc.block('h1')", "mc.block('h2')", "mc.block('h3')", "mc.block('p')", "mc.block('blockquote')",
        "mc.run('insertUnorderedList')", "mc.run('insertOrderedList')", "mc.run('insertHorizontalRule')",
        "mc.code()", "mc.table()", "mc.run('undo')", "mc.run('redo')",
    ]

    private func build(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let colors = ["blue", "green", "yellow", "red", "purple"]
        let boxes = colors.map { (L10n.t("rich.color.\($0)"), "callout-box box-\($0)") }
        let headers = zip(["blue", "green", "orange", "pink", "purple"], 1...5).map { (L10n.t("rich.color.\($0)"), "rect-header color-\($1)") }
        let views: [NSView] = [
            action(L10n.t("edit.save"), #selector(saveClicked)),
            command("B", 0, tip: "⌘B"), command("I", 1, tip: "⌘I"), command("U", 2, tip: "⌘U"),
            command("H1", 3, tip: "⌘1"), command("H2", 4, tip: "⌘2"), command("H3", 5, tip: "⌘3"), command("¶", 6, tip: "⌘0"),
            command("❝", 7, tip: L10n.t("rich.quote")),
            command("•", 8, tip: L10n.t("rich.bullets")), command("1.", 9, tip: L10n.t("rich.numbers")),
            command("—", 10, tip: L10n.t("rich.rule")), command("</>", 11, tip: L10n.t("rich.code")),
            action("🔗", tip: L10n.t("rich.link") + " ⌘K", #selector(linkClicked)),
            action("🖼", tip: L10n.t("rich.image"), #selector(imageClicked)),
            pulldown(L10n.t("rich.table"), [
                (L10n.t("rich.table.new"), "new"), (L10n.t("rich.table.rowAbove"), "rowAbove"), (L10n.t("rich.table.rowBelow"), "rowBelow"),
                (L10n.t("rich.table.columnLeft"), "columnLeft"), (L10n.t("rich.table.columnRight"), "columnRight"),
                (L10n.t("rich.table.deleteRow"), "deleteRow"), (L10n.t("rich.table.deleteColumn"), "deleteColumn"), (L10n.t("rich.table.deleteTable"), "deleteTable"),
            ], #selector(tableChosen(_:))),
            pulldown(L10n.t("rich.box"), boxes, #selector(boxChosen(_:))),
            pulldown(L10n.t("rich.header"), headers, #selector(boxChosen(_:))),
            command("↶", 13, tip: "⌘Z"), command("↷", 14, tip: "⌘⇧Z"),
        ]
        let toolbar = NSStackView(views: views + [NSView()])
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)
        content.addSubview(webView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func updateTitle() {
        window?.title = target.map { "\($0.name) — \($0.path)" } ?? L10n.t("rich.untitled")
        window?.isDocumentEdited = isDirty
    }

    // MARK: Page

    func evaluate(_ code: String, completion: ((Any?) -> Void)? = nil) {
        webView.evaluateJavaScript(code, in: nil, in: .defaultClient) { result in
            completion?(try? result.get())
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didLoad = true
        window?.makeFirstResponder(webView)
        evaluate("mc.run('selectAll'); window.getSelection().collapseToStart();")
        onLoaded?()
    }

    /// Clicking a link while writing must not leave the document.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        decisionHandler(didLoad && isMainFrame ? .cancel : .allow)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        changeCount += 1
        if !isDirty {
            isDirty = true
            updateTitle()
        }
    }

    // MARK: Commands

    @objc private func commandClicked(_ sender: NSButton) { runCommand(sender.tag) }

    func runCommand(_ index: Int) {
        guard Self.commands.indices.contains(index) else { return }
        evaluate(Self.commands[index])
    }

    @objc private func tableChosen(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        if action == "new" {
            evaluate(Self.commands[12])
            return
        }
        evaluate("mc.tableEdit(\(Self.quoted(action)))") { [weak self] result in
            guard (result as? Bool) != true else { return }
            NSSound.beep()
            self?.onMessage?(L10n.t("rich.table.noCell"))
        }
    }

    @objc private func boxChosen(_ sender: NSMenuItem) {
        guard let classes = sender.representedObject as? String else { return }
        evaluate("mc.box(\(Self.quoted(classes)))")
    }

    @objc private func saveClicked() { save() }
    @objc private func linkClicked() { askForLink() }

    /// A JavaScript string, safely quoted.
    static func quoted(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]), let json = String(data: data, encoding: .utf8) else { return "''" }
        return String(json.dropFirst().dropLast())
    }

    private func askForText(title: String, placeholder: String, extra: NSButton? = nil, field: NSTextField = NSTextField(), answer: @escaping (String?) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: L10n.t("common.cancel")).keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            answer(response == .alertFirstButtonReturn && !text.isEmpty ? text : nil)
        }
    }

    private func askForLink() {
        evaluate("mc.remember()")
        askForText(title: L10n.t("rich.link"), placeholder: "https://") { [weak self] url in
            guard let self else { return }
            self.evaluate("mc.recall()")
            guard let url else { return }
            let quoted = Self.quoted(url)
            self.evaluate("(() => { const s = window.getSelection(); if (s.isCollapsed) mc.insert('<a href=\"' + \(quoted).replace(/\"/g, '&quot;') + '\">' + \(quoted).replace(/&/g, '&amp;').replace(/</g, '&lt;') + '</a>'); else mc.run('createLink', \(quoted)); })()")
        }
    }

    @objc private func imageClicked() {
        evaluate("mc.remember()")
        // A picture on this Mac is referred to from the document's folder. On a server, or for one
        // elsewhere, the address is typed in.
        askForText(title: L10n.t("rich.image"), placeholder: L10n.t("rich.imageHint")) { [weak self] address in
            guard let self else { return }
            self.evaluate("mc.recall()")
            guard let address else { return }
            let quoted = Self.quoted(address)
            self.evaluate("mc.insert('<img alt=\"\" src=\"' + \(quoted).replace(/\"/g, '&quot;') + '\">')")
        }
    }

    // MARK: Keys

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, flags.isEmpty {
            window?.performClose(nil)
            return true
        }
        guard flags.contains(.command) || flags.contains(.control), !flags.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = flags.contains(.shift)
        switch key {
        case "s" where !shift: save()
        case "b" where !shift: runCommand(0)
        case "i" where !shift: runCommand(1)
        case "u" where !shift: runCommand(2)
        case "1" where !shift: runCommand(3)
        case "2" where !shift: runCommand(4)
        case "3" where !shift: runCommand(5)
        case "0" where !shift: runCommand(6)
        case "k" where !shift: askForLink()
        case "z": runCommand(shift ? 14 : 13)
        default: return false
        }
        return true
    }

    // MARK: Saving

    func save(completion: ((Bool) -> Void)? = nil) {
        guard !isSaving else {
            completion?(false)
            return
        }
        guard target != nil else {
            chooseName { [weak self] chosen in
                guard let self else { return }
                if chosen { self.save(completion: completion) } else { completion?(false) }
            }
            return
        }
        isSaving = true
        let revision = changeCount
        evaluate("mc.html()") { [weak self] result in
            guard let self else { return }
            guard let content = result as? String else {
                self.isSaving = false
                completion?(false)
                return
            }
            self.write(content: content, revision: revision, completion: completion)
        }
    }

    private func write(content: String, revision: Int, completion: ((Bool) -> Void)?) {
        guard let target else { return }
        let html = page.assembled(content: content)
        guard let data = encoded.encode(html) else {
            // Characters the old encoding can't hold. The page declares its own charset, so this asks.
            isSaving = false
            showConfirm(title: L10n.t("edit.convertTitle", encoded.encoding.title), text: L10n.t("edit.convertText"), button: L10n.t("edit.convert")) { [weak self] yes in
                guard let self else { return }
                if yes {
                    self.encoded.encoding = .utf8
                    self.save(completion: completion)
                } else {
                    completion?(false)
                }
            }
            return
        }
        EditorWindowController.guardedWrite(data, target: target, baseline: stamp, ask: { [weak self] answer in
            guard let self else { return answer(false) }
            if let confirmOverwrite = self.confirmOverwrite { return confirmOverwrite(answer) }
            self.showConfirm(title: L10n.t("edit.changedTitle", target.name), text: L10n.t("edit.changedText"), button: L10n.t("edit.overwrite"), completion: answer)
        }, completion: { [weak self] outcome in
            guard let self else { return }
            self.isSaving = false
            switch outcome {
            case .saved(let newStamp):
                self.stamp = newStamp
                if self.changeCount == revision {
                    self.isDirty = false
                    self.updateTitle()
                }
                self.onSaved?()
                if target.source != nil { self.onMessage?(L10n.t("editor.uploaded", target.name)) }
                completion?(true)
            case .declined:
                completion?(false)
            case .failed(let error):
                let alert = NSAlert(error: error)
                alert.messageText = L10n.t("edit.saveFailed", target.name)
                if let window = self.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
                completion?(false)
            }
        })
    }

    /// First save of a new document. An existing file of that name is not replaced without asking.
    private func chooseName(_ done: @escaping (Bool) -> Void) {
        let answer: (String?) -> Void = { [weak self] typed in
            guard let self, var name = typed, !name.contains("/") else { return done(false) }
            if !["html", "htm"].contains((name as NSString).pathExtension.lowercased()) { name += ".html" }
            let path = PathUtil.join(self.folder, name)
            let target = EditorWindowController.Target(name: name, path: path, source: self.source, queue: self.queue)
            self.queue.async {
                let exists = EditorWindowController.currentStamp(of: target) != nil
                DispatchQueue.main.async {
                    let accept: (Bool) -> Void = { yes in
                        guard yes else { return done(false) }
                        self.target = target
                        self.updateTitle()
                        done(true)
                    }
                    guard exists else { return accept(true) }
                    if let confirmOverwrite = self.confirmOverwrite { return confirmOverwrite(accept) }
                    self.showConfirm(title: L10n.t("rich.existsTitle", name), text: L10n.t("edit.changedText"), button: L10n.t("edit.overwrite"), completion: accept)
                }
            }
        }
        if let askForName { return askForName(answer) }
        let field = NSTextField(string: "belge.html")
        askForText(title: L10n.t("rich.nameTitle"), placeholder: "belge.html", field: field, answer: answer)
    }

    /// Enter must not confirm something that replaces work, so the risky button has no key.
    private func showConfirm(title: String, text: String, button: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: button).keyEquivalent = ""
        alert.addButton(withTitle: L10n.t("common.cancel")).keyEquivalent = "\u{1b}"
        guard let window else { return completion(alert.runModal() == .alertFirstButtonReturn) }
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    }

    // MARK: Closing

    func askToDiscard(_ answer: @escaping (Bool) -> Void) {
        guard let window else { return answer(true) }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = L10n.t("edit.unsavedTitle", target?.name ?? L10n.t("rich.untitled"))
        alert.informativeText = L10n.t("edit.unsavedText")
        alert.addButton(withTitle: L10n.t("edit.save"))
        alert.addButton(withTitle: L10n.t("edit.dontSave"))
        alert.addButton(withTitle: L10n.t("common.cancel")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.save(completion: answer)
            case .alertSecondButtonReturn: answer(true)
            default: answer(false)
            }
        }
    }

    func markClean() { isDirty = false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty || isSaving else { return true }
        askToDiscard { [weak self] closing in
            guard closing, let self else { return }
            self.isDirty = false
            self.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        webView.configuration.userContentController.removeAllScriptMessageHandlers(from: .defaultClient)
        Self.open.removeAll { $0 === self }
        OpenDocuments.remove(self)
    }
}
