import AppKit
import MacdowsCore

/// Sends every key to the window's shortcuts first, whichever field has focus.
final class KeyFirstWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

private enum EditorColors {
    static let background = Theme.editorBackground
    static let text = Theme.editorText
    static let gutter = Theme.gutter
    static let gutterText = Theme.gutterText
    static let gutterCurrent = Theme.gutterCurrent
    static let error = Theme.error
    static let match = Theme.match
    static let currentMatch = Theme.currentMatch

    /// Readable on the background of each theme.
    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .comment: return Theme.token(0x7A8450, dark: 0x7FA86F, norton: 0x8FD0FF)
        case .string: return Theme.token(0xA8552C, dark: 0xE5A07B, norton: 0xFFFF55)
        case .keyword: return Theme.token(0x9A3E8C, dark: 0xD197D9, norton: 0xFF9FFF)
        case .number: return Theme.token(0x2F7D4F, dark: 0xB9DDA5, norton: 0x55FF55)
        case .tag: return Theme.token(0x2B6CA3, dark: 0x6DB3F2, norton: 0x55FFFF)
        case .attribute: return Theme.token(0x8A5A12, dark: 0x9CDCFE, norton: 0xFFD27F)
        case .variable: return Theme.token(0x12788A, dark: 0x7FD6F0, norton: 0x9FFFB0)
        case .function: return Theme.token(0x6A4FB0, dark: 0xE6DFA0, norton: 0xFFFFAA)
        case .meta: return Theme.token(0xC6613F, dark: 0xFF8F8F, norton: 0xFF7F7F)
        case .regex: return Theme.token(0xB5305F, dark: 0xF08FA8, norton: 0xFFAAD0)
        }
    }
}

/// Line numbers, with lines holding a syntax error in red.
private final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    var lineStarts: [Int] = [0]
    var errorLines: Set<Int> = []
    var currentLine = 1

    func lineNumber(of index: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= index { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    func updateThickness() {
        let digits = max(3, String(lineStarts.count).count)
        let font = AppFont.mono
        let width = ("9" as NSString).size(withAttributes: [.font: font]).width
        let wanted = ceil(width * CGFloat(digits)) + 18
        if ruleThickness != wanted { ruleThickness = wanted }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorColors.gutter.setFill()
        bounds.fill()
        guard let textView, let manager = textView.layoutManager, let container = textView.textContainer else { return }
        let font = NSFont(name: AppFont.monoFamily, size: max(10, AppFont.size - 1)) ?? .monospacedDigitSystemFont(ofSize: max(10, AppFont.size - 1), weight: .regular)
        let origin = textView.textContainerOrigin.y
        let draw: (Int, CGFloat, CGFloat) -> Void = { line, top, height in
            let color: NSColor
            if self.errorLines.contains(line) {
                color = EditorColors.error
                let y = self.convert(NSPoint(x: 0, y: top), from: textView).y
                EditorColors.error.withAlphaComponent(0.2).setFill()
                NSRect(x: 0, y: y, width: self.bounds.width, height: height).fill()
            } else {
                color = line == self.currentLine ? EditorColors.gutterCurrent : EditorColors.gutterText
            }
            let text = String(line) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = text.size(withAttributes: attributes)
            let y = self.convert(NSPoint(x: 0, y: top), from: textView).y + (height - size.height) / 2
            text.draw(at: NSPoint(x: self.ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }
        let visible = textView.visibleRect
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        let string = textView.string as NSString
        var glyph = glyphs.location
        while glyph < NSMaxRange(glyphs) {
            var fragment = NSRange()
            let box = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragment)
            let index = manager.characterIndexForGlyph(at: glyph)
            let line = lineNumber(of: index)
            if index < string.length, lineStarts[line - 1] == index {
                draw(line, box.minY + origin, box.height)
            }
            glyph = NSMaxRange(fragment)
        }
        // The empty last line after a final line break has no glyphs.
        let extra = manager.extraLineFragmentRect
        if !extra.isEmpty { draw(lineStarts.count, extra.minY + origin, extra.height) }
    }
}

/// The built-in F4 editor: colors, line numbers, find and replace, line commands and syntax errors.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate, DocumentWindow {
    struct Target {
        let name: String
        let path: String
        /// Nil for a file on this Mac.
        let source: FileSource?
        let queue: DispatchQueue
    }

    /// Identifies what the file looked like, to notice someone else changing it.
    struct Stamp: Equatable {
        let size: Int64
        let date: Date?
    }

    static let sizeLimit: Int64 = 32 << 20
    private static let syncHighlightLimit = 300_000
    private static let highlightLimit = 10 << 20

    /// Editors outlive the main window that opened them, so unsaved work is never dropped with it.
    private(set) static var openEditors: [EditorWindowController] = []

    static func existing(path: String, source: FileSource?) -> EditorWindowController? {
        openEditors.first { $0.target.path == path && $0.target.source === source }
    }

    private(set) var target: Target
    private var file: EditorDocument
    private var stamp: Stamp?
    private(set) var language: CodeLanguage
    var onSaved: (() -> Void)?
    var onMessage: ((String) -> Void)?
    /// Asks before replacing a file that changed elsewhere. Replaced in tests.
    var confirmOverwrite: ((@escaping (Bool) -> Void) -> Void)?

    let textView: NSTextView
    private let scroll = NSScrollView()
    private let ruler: LineNumberRuler
    private let storage = NSTextStorage()
    private let saveButton = NSButton()
    private let saveAsButton = NSButton()
    private let visualButton = NSButton()
    /// Opens this file in the writing editor, with what the window holds.
    var onOpenVisual: ((Target, EditorDocument, Stamp?) -> Void)?
    private let findButton = NSButton()
    private let replaceButton = NSButton()
    private let duplicateButton = NSButton()
    private let deleteButton = NSButton()
    private let goToButton = NSButton()
    private let findBar = NSStackView()
    private let replaceRow = NSStackView()
    let findField = NSTextField()
    let replaceField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let caseBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let replaceOneButton = NSButton()
    private let replaceAllButton = NSButton()
    private let closeFindButton = NSButton()
    private let syntaxButton = NSButton()
    private let infoLabel = NSTextField(labelWithString: "")

    private(set) var tokens: [SyntaxToken] = []
    private(set) var report = SyntaxReport()
    private(set) var matches: [NSRange] = []
    private var currentMatch: Int?
    private var issueCursor = 0
    private var analysisGeneration = 0
    private var analysisWork: DispatchWorkItem?
    private var checkGeneration = 0
    private var checkWork: DispatchWorkItem?
    private(set) var isDirty = false
    private var changeCount = 0
    private(set) var isSaving = false
    private var searchAnchor = 0

    private static let analysisQueue = DispatchQueue(label: "macdows.editor.analysis", qos: .userInitiated)
    private static let checkQueue = DispatchQueue(label: "macdows.editor.check", qos: .utility)

    init(target: Target, document: EditorDocument, stamp: Stamp?) {
        self.target = target
        self.file = document
        self.stamp = stamp
        language = CodeLanguage.detect(fileName: target.name)

        let manager = NSLayoutManager()
        manager.allowsNonContiguousLayout = true
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        manager.addTextContainer(container)
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), textContainer: container)
        ruler = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)

        let window = KeyFirstWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        Theme.apply(to: window)
        window.center()
        window.setFrameAutosaveName("MacdowsEditor")
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] in self?.handleKey($0) ?? false }

        configureTextView()
        build(in: window)
        relabel()
        applyFont()
        textView.string = file.text
        applyBaseAttributes()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.allowsUndo = true
        textView.delegate = self
        rebuildLineStarts()
        analyzeNow()
        refreshStatus()
        scheduleCheck(delay: 0)
        updateTitle()
        window.makeFirstResponder(textView)
        Self.openEditors.append(self)
        OpenDocuments.add(self)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        center.addObserver(self, selector: #selector(viewportChanged), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        center.addObserver(self, selector: #selector(fontChanged), name: .appFontChanged, object: nil)
        center.addObserver(self, selector: #selector(languageChanged), name: .languageChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Building

    private func configureTextView() {
        let view = textView
        view.isRichText = false
        view.importsGraphics = false
        view.usesFontPanel = false
        view.usesRuler = false
        // Every "smart" feature here would silently change code.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.drawsBackground = true
        view.backgroundColor = EditorColors.background
        view.insertionPointColor = Theme.editorCaret
        view.textColor = EditorColors.text
        view.selectedTextAttributes = [.backgroundColor: Theme.textSelection]
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width, .height]
    }

    private func toolbarButton(_ button: NSButton, _ action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.refusesFirstResponder = true
        button.target = self
        button.action = action
        button.font = AppFont.interface(11)
    }

    private func build(in window: NSWindow) {
        guard let content = window.contentView else { return }
        toolbarButton(saveButton, #selector(saveClicked))
        toolbarButton(saveAsButton, #selector(saveAsClicked))
        toolbarButton(visualButton, #selector(visualClicked))
        toolbarButton(findButton, #selector(findClicked))
        toolbarButton(replaceButton, #selector(replaceClicked))
        toolbarButton(duplicateButton, #selector(duplicateClicked))
        toolbarButton(deleteButton, #selector(deleteClicked))
        toolbarButton(goToButton, #selector(goToClicked))
        let toolbar = NSStackView(views: [saveButton, saveAsButton, visualButton, findButton, replaceButton, goToButton, duplicateButton, deleteButton, NSView()])
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        for field in [findField, replaceField] {
            field.delegate = self
            field.controlSize = .small
            field.font = AppFont.interface(13)
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        toolbarButton(previousButton, #selector(previousClicked))
        toolbarButton(nextButton, #selector(nextClicked))
        toolbarButton(replaceOneButton, #selector(replaceOneClicked))
        toolbarButton(replaceAllButton, #selector(replaceAllClicked))
        toolbarButton(closeFindButton, #selector(closeFindClicked))
        previousButton.title = "▲"
        nextButton.title = "▼"
        closeFindButton.title = "✕"
        caseBox.controlSize = .small
        caseBox.refusesFirstResponder = true
        caseBox.target = self
        caseBox.action = #selector(caseChanged)
        countLabel.font = AppFont.interface(11)
        countLabel.textColor = Theme.secondaryText
        let findRow = NSStackView(views: [findField, previousButton, nextButton, caseBox, countLabel, NSView(), closeFindButton])
        findRow.spacing = 6
        replaceRow.setViews([replaceField, replaceOneButton, replaceAllButton, NSView()], in: .leading)
        replaceRow.spacing = 6
        replaceRow.orientation = .horizontal
        findBar.setViews([findRow, replaceRow], in: .top)
        findBar.orientation = .vertical
        findBar.alignment = .leading
        findBar.spacing = 4
        findBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        findBar.isHidden = true
        findRow.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        ruler.textView = textView
        ruler.clientView = textView
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        syntaxButton.isBordered = false
        syntaxButton.alignment = .left
        syntaxButton.lineBreakMode = .byTruncatingTail
        syntaxButton.refusesFirstResponder = true
        syntaxButton.target = self
        syntaxButton.action = #selector(syntaxClicked)
        syntaxButton.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        infoLabel.font = AppFont.interface(11)
        infoLabel.textColor = Theme.secondaryText
        infoLabel.setContentHuggingPriority(.required, for: .horizontal)
        infoLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let statusBar = NSStackView(views: [syntaxButton, infoLabel])
        statusBar.spacing = 10
        statusBar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        statusBar.distribution = .fill

        let stack = NSStackView(views: [toolbar, findBar, scroll, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            findBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            findRow.widthAnchor.constraint(equalTo: findBar.widthAnchor, constant: -16),
        ])
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
    }

    private func relabel() {
        saveButton.title = L10n.t("edit.save")
        saveAsButton.title = L10n.t("edit.saveAs")
        visualButton.title = L10n.t("edit.visual")
        refreshVisualButton()
        findButton.title = L10n.t("edit.find")
        replaceButton.title = L10n.t("edit.replace")
        duplicateButton.title = L10n.t("edit.duplicate")
        deleteButton.title = L10n.t("edit.deleteLine")
        goToButton.title = L10n.t("edit.goTo")
        findField.placeholderString = L10n.t("edit.findPlaceholder")
        replaceField.placeholderString = L10n.t("edit.replacePlaceholder")
        caseBox.title = L10n.t("edit.caseSensitive")
        replaceOneButton.title = L10n.t("edit.replaceOne")
        replaceAllButton.title = L10n.t("edit.replaceAll")
        refreshStatus()
        showReport()
    }

    @objc private func languageChanged() { relabel() }

    @objc private func fontChanged() {
        applyFont()
        applyBaseAttributes()
        applyColors()
    }

    private func applyFont() {
        textView.font = AppFont.mono
        ruler.updateThickness()
        ruler.needsDisplay = true
    }

    /// Fixed font and tab width. Colors are layered on top as temporary attributes, which never reach the undo history.
    private func applyBaseAttributes() {
        let font = AppFont.mono
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: font]).width
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: EditorColors.text, .paragraphStyle: style]
        storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        textView.typingAttributes = attributes
        textView.defaultParagraphStyle = style
    }

    private func updateTitle() {
        let place = target.source == nil ? target.path : "\(target.path) — \(L10n.t("preview.fromServer"))"
        window?.title = "\(target.name) — \(place)"
        window?.isDocumentEdited = isDirty
    }

    // MARK: Keys

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, flags.isEmpty { // Esc
            if !findBar.isHidden {
                hideFind()
            } else {
                window?.performClose(nil)
            }
            return true
        }
        if event.keyCode == 99 { // F3
            moveMatch(forward: !flags.contains(.shift))
            return true
        }
        let accelerator = flags.contains(.command) || flags.contains(.control)
        guard accelerator, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        switch key {
        case "f" where !shift:
            showFind(replacing: option)
        case "h" where control && !shift && !option:
            showFind(replacing: true)
        case "g" where control && !shift && !option:
            showGoToLine()
        case "g" where !option:
            moveMatch(forward: !shift)
        case "s" where !shift && !option:
            save()
        case "s" where shift && !option:
            saveAs()
        case "d" where !shift && !option:
            duplicateLines()
        case "l" where !shift && !option:
            deleteLines()
        case "z" where control && !option:
            if shift { textView.undoManager?.redo() } else { textView.undoManager?.undo() }
        default:
            return false
        }
        return true
    }

    @objc private func saveClicked() { save() }
    @objc private func saveAsClicked() { saveAs() }

    private func refreshVisualButton() {
        visualButton.isHidden = !["html", "htm", "md", "markdown", "mdown", "mkd"].contains((target.name as NSString).pathExtension.lowercased())
    }

    /// Saves first if needed, because the writing editor works from the file as it stands.
    @objc private func visualClicked() {
        let open = { [weak self] in
            guard let self else { return }
            let current = EditorDocument(text: self.textView.string, encoding: self.file.encoding, usesCRLF: self.file.usesCRLF)
            self.onOpenVisual?(self.target, current, self.stamp)
        }
        if isDirty {
            save { if $0 { open() } }
        } else {
            open()
        }
    }
    @objc private func findClicked() { showFind(replacing: false) }
    @objc private func replaceClicked() { showFind(replacing: true) }
    @objc private func duplicateClicked() { duplicateLines() }
    @objc private func deleteClicked() { deleteLines() }
    @objc private func goToClicked() { showGoToLine() }
    @objc private func previousClicked() { moveMatch(forward: false) }
    @objc private func nextClicked() { moveMatch(forward: true) }
    @objc private func replaceOneClicked() { replaceCurrent() }
    @objc private func replaceAllClicked() { replaceAll() }
    @objc private func closeFindClicked() { hideFind() }
    @objc private func caseChanged() { refreshMatches(jump: true) }

    // MARK: Changing text

    private func apply(_ change: TextChange, actionName: String) {
        guard textView.shouldChangeText(in: change.range, replacementString: change.replacement) else { return }
        storage.replaceCharacters(in: change.range, with: NSAttributedString(string: change.replacement, attributes: textView.typingAttributes))
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
        textView.setSelectedRange(change.selection)
        textView.scrollRangeToVisible(change.selection)
    }

    func duplicateLines() {
        apply(LineEdits.duplicate(in: textView.string as NSString, selection: textView.selectedRange()), actionName: L10n.t("edit.duplicate"))
    }

    func deleteLines() {
        guard storage.length > 0 else { return }
        apply(LineEdits.delete(in: textView.string as NSString, selection: textView.selectedRange()), actionName: L10n.t("edit.deleteLine"))
    }

    func textDidChange(_ notification: Notification) {
        changeCount += 1
        if !isDirty {
            isDirty = true
            updateTitle()
        }
        rebuildLineStarts()
        analyze()
        if !findBar.isHidden { refreshMatches(jump: false) }
        scheduleCheck(delay: 0.6)
        refreshStatus()
    }

    func textViewDidChangeSelection(_ notification: Notification) { refreshStatus() }

    private func rebuildLineStarts() {
        var starts = [0]
        var previous: UInt16 = 0
        var index = 0
        for c in textView.string.utf16 {
            if previous == 13, c != 10 { starts.append(index) }
            if c == 10 { starts.append(index + 1) }
            previous = c
            index += 1
        }
        if previous == 13 { starts.append(index) }
        ruler.lineStarts = starts
        ruler.updateThickness()
        ruler.needsDisplay = true
    }

    // MARK: Colors

    private func analyzeNow() {
        guard language != .plain, storage.length <= Self.highlightLimit else { return }
        tokens = SyntaxHighlighter.analyze(textView.string, language: language).tokens
        applyColors()
    }

    /// Small files color on every key press. Big ones wait for a pause and work in the background.
    private func analyze() {
        analysisWork?.cancel()
        guard language != .plain, storage.length <= Self.highlightLimit else { return }
        if storage.length <= Self.syncHighlightLimit {
            analyzeNow()
            return
        }
        applyColors()
        analysisGeneration += 1
        let generation = analysisGeneration
        let text = textView.string
        let language = self.language
        let work = DispatchWorkItem { [weak self] in
            let found = SyntaxHighlighter.analyze(text, language: language).tokens
            DispatchQueue.main.async {
                guard let self, generation == self.analysisGeneration else { return }
                self.tokens = found
                self.applyColors()
            }
        }
        analysisWork = work
        Self.analysisQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc private func viewportChanged() {
        applyColors()
        ruler.needsDisplay = true
    }

    /// Paints only what is on screen, so a long file costs the same as a short one.
    private func applyColors() {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        let length = storage.length
        guard length > 0 else { return }
        let glyphs = manager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        var visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let start = max(0, visible.location - 2000)
        visible = NSRange(location: start, length: min(length - start, visible.length + (visible.location - start) + 2000))
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineStyle, .underlineColor] {
            manager.removeTemporaryAttribute(key, forCharacterRange: visible)
        }
        paint(tokens.map(\.range), visible) { index in
            [.foregroundColor: EditorColors.color(for: self.tokens[index].kind)]
        }
        paint(matches, visible) { index in
            [.backgroundColor: index == self.currentMatch ? EditorColors.currentMatch : EditorColors.match]
        }
        let errorRanges = errorLineRanges()
        for range in errorRanges {
            let clipped = NSIntersectionRange(range, visible)
            guard clipped.length > 0 else { continue }
            manager.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: EditorColors.error], forCharacterRange: clipped)
        }
    }

    /// Ranges are sorted, so a binary search finds where the visible part begins.
    private func paint(_ ranges: [NSRange], _ visible: NSRange, attributes: (Int) -> [NSAttributedString.Key: Any]) {
        guard let manager = textView.layoutManager else { return }
        var low = 0, high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(ranges[middle]) <= visible.location { low = middle + 1 } else { high = middle }
        }
        var index = low
        while index < ranges.count, ranges[index].location < NSMaxRange(visible) {
            let clipped = NSIntersectionRange(ranges[index], visible)
            if clipped.length > 0 { manager.addTemporaryAttributes(attributes(index), forCharacterRange: clipped) }
            index += 1
        }
    }

    private func errorLineRanges() -> [NSRange] {
        let text = textView.string as NSString
        return report.issues.compactMap { issue in
            guard issue.line >= 1, issue.line <= ruler.lineStarts.count else { return nil }
            let location = ruler.lineStarts[issue.line - 1]
            guard location < text.length else { return nil }
            var end = location
            var contentsEnd = location
            var lineStart = location
            text.getLineStart(&lineStart, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            return NSRange(location: location, length: contentsEnd - location)
        }
    }

    // MARK: Find and replace

    func showFind(replacing: Bool) {
        let selected = textView.selectedRange()
        if selected.length > 0, selected.length < 200 {
            let text = (textView.string as NSString).substring(with: selected)
            if !text.contains("\n") { findField.stringValue = text }
        }
        findBar.isHidden = false
        replaceRow.isHidden = !replacing
        searchAnchor = selected.location
        window?.makeFirstResponder(replacing && !findField.stringValue.isEmpty ? replaceField : findField)
        refreshMatches(jump: false)
    }

    func hideFind() {
        findBar.isHidden = true
        matches = []
        currentMatch = nil
        applyColors()
        window?.makeFirstResponder(textView)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject === findField else { return }
        refreshMatches(jump: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if control === replaceField {
            replaceCurrent()
        } else {
            moveMatch(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
        }
        return true
    }

    func refreshMatches(jump: Bool) {
        matches = TextMatcher.find(findField.stringValue, in: textView.string, caseSensitive: caseBox.state == .on)
        currentMatch = matches.firstIndex { $0 == textView.selectedRange() }
        if jump {
            if let index = matches.firstIndex(where: { $0.location >= searchAnchor }) ?? matches.indices.first {
                select(match: index)
                return
            }
        }
        updateCount()
        applyColors()
    }

    private func updateCount() {
        if findField.stringValue.isEmpty {
            countLabel.stringValue = ""
        } else if matches.isEmpty {
            countLabel.stringValue = L10n.t("edit.noMatch")
        } else if let currentMatch {
            countLabel.stringValue = "\(currentMatch + 1) / \(matches.count)"
        } else {
            countLabel.stringValue = "\(matches.count)"
        }
    }

    private func select(match index: Int) {
        currentMatch = index
        textView.setSelectedRange(matches[index])
        textView.scrollRangeToVisible(matches[index])
        updateCount()
        applyColors()
    }

    func moveMatch(forward: Bool) {
        if findBar.isHidden {
            showFind(replacing: false)
            return
        }
        guard !matches.isEmpty else { return }
        let selection = textView.selectedRange()
        let index: Int
        if forward {
            index = matches.firstIndex { $0.location >= NSMaxRange(selection) } ?? 0
        } else {
            index = matches.lastIndex { NSMaxRange($0) <= selection.location } ?? matches.count - 1
        }
        searchAnchor = matches[index].location
        select(match: index)
    }

    func replaceCurrent() {
        let selection = textView.selectedRange()
        guard matches.contains(selection) else {
            moveMatch(forward: true)
            return
        }
        let replacement = replaceField.stringValue
        let end = NSRange(location: selection.location + (replacement as NSString).length, length: 0)
        apply(TextChange(range: selection, replacement: replacement, selection: end), actionName: L10n.t("edit.replaceOne"))
        moveMatch(forward: true)
    }

    /// One edit from the first match to the last, so a single undo takes it all back.
    func replaceAll() {
        guard let first = matches.first, let last = matches.last else { return }
        let text = textView.string as NSString
        let replacement = replaceField.stringValue
        var result = ""
        var position = first.location
        for match in matches {
            result += text.substring(with: NSRange(location: position, length: match.location - position))
            result += replacement
            position = NSMaxRange(match)
        }
        let count = matches.count
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        apply(TextChange(range: range, replacement: result, selection: NSRange(location: first.location, length: 0)), actionName: L10n.t("edit.replaceAll"))
        countLabel.stringValue = L10n.t("edit.replacedCount", String(count))
    }

    // MARK: Go to line

    /// Accepts "120" and "120:5" (line and column). Anything else is nil.
    static func parseLocation(_ text: String) -> (line: Int, column: Int)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let line = Int(parts[0]), line >= 0 else { return nil }
        guard parts.count == 2 else { return (line, 1) }
        guard let column = Int(parts[1]), column >= 0 else { return nil }
        return (line, column)
    }

    /// Numbers past the end go to the last line, and past the end of a line to its end.
    func goToLine(_ line: Int, column: Int = 1) {
        let number = min(max(1, line), ruler.lineStarts.count)
        let start = ruler.lineStarts[number - 1]
        let text = textView.string as NSString
        var end = start
        if start < text.length {
            var lineStart = start, lineEnd = start
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &end, for: NSRange(location: start, length: 0))
        }
        let range = NSRange(location: min(start + max(1, column) - 1, end), length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        window?.makeFirstResponder(textView)
    }

    private func showGoToLine() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("edit.goToTitle", String(ruler.lineStarts.count))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = L10n.t("edit.goToPlaceholder", String(ruler.currentLine))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: L10n.t("common.cancel")).keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if let location = Self.parseLocation(field.stringValue) {
                self.goToLine(location.line, column: location.column)
            }
        }
    }

    // MARK: Syntax check

    private func scheduleCheck(delay: TimeInterval) {
        checkWork?.cancel()
        guard SyntaxChecker.canCheck(language), storage.length <= Self.highlightLimit else { return }
        checkGeneration += 1
        let generation = checkGeneration
        let text = textView.string
        let language = self.language
        let name = target.name
        let work = DispatchWorkItem { [weak self] in
            let result = SyntaxChecker.check(text, language: language, fileName: name)
            DispatchQueue.main.async {
                guard let self, generation == self.checkGeneration else { return }
                self.report = result
                self.issueCursor = 0
                self.ruler.errorLines = Set(result.issues.map(\.line))
                self.ruler.needsDisplay = true
                self.showReport()
                self.applyColors()
            }
        }
        checkWork = work
        Self.checkQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func showReport() {
        guard report.didCheck else {
            syntaxButton.attributedTitle = NSAttributedString(string: "")
            return
        }
        let text: String
        let color: NSColor
        if let first = report.issues.first {
            text = L10n.t(report.issues.count == 1 ? "edit.syntaxOne" : "edit.syntaxMany", String(first.line), first.message, String(report.issues.count))
            color = EditorColors.error
        } else {
            var parts = [L10n.t("edit.syntaxOK")]
            if report.phpMissing {
                parts = [L10n.t("edit.phpMissing")]
            }
            if report.skippedScripts > 0 { parts.append(L10n.t("edit.scriptsSkipped", String(report.skippedScripts))) }
            text = parts.joined(separator: " · ")
            color = report.phpMissing ? Theme.warning : Theme.success
        }
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .font: AppFont.interface(12)]
        syntaxButton.attributedTitle = NSAttributedString(string: text, attributes: attributes)
        syntaxButton.toolTip = report.issues.map { L10n.t("edit.lineMessage", String($0.line), $0.message) }.joined(separator: "\n")
    }

    /// Clicking the error goes to its line, and on to the next error when there are several.
    @objc private func syntaxClicked() {
        guard !report.issues.isEmpty else { return }
        let issue = report.issues[issueCursor % report.issues.count]
        issueCursor += 1
        guard issue.line >= 1, issue.line <= ruler.lineStarts.count else { return }
        let range = NSRange(location: min(ruler.lineStarts[issue.line - 1], storage.length), length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        window?.makeFirstResponder(textView)
    }

    private func refreshStatus() {
        let location = min(textView.selectedRange().location, storage.length)
        let line = ruler.lineNumber(of: location)
        let column = location - ruler.lineStarts[line - 1] + 1
        if ruler.currentLine != line {
            ruler.currentLine = line
            ruler.needsDisplay = true
        }
        let ending = file.usesCRLF ? "CRLF" : "LF"
        infoLabel.stringValue = "\(language.rawValue) · \(file.encoding.title) · \(ending) · " + L10n.t("edit.position", String(line), String(column))
    }

    // MARK: Saving

    static func currentStamp(of target: Target) -> Stamp? {
        if let source = target.source {
            let folder = (target.path as NSString).deletingLastPathComponent
            guard let entry = (try? source.list(folder))?.first(where: { $0.name == target.name }) else { return nil }
            return Stamp(size: entry.size, date: entry.date)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path) else { return nil }
        return Stamp(size: (attributes[.size] as? NSNumber)?.int64Value ?? 0, date: attributes[.modificationDate] as? Date)
    }

    private static func store(_ data: Data, target: Target) throws {
        if let source = target.source {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macdows-save-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent(target.name)
            try data.write(to: file)
            try source.upload(file, to: target.path) { _ in true }
            return
        }
        // A symlink keeps pointing at the same file, and the file keeps its permissions.
        let url = URL(fileURLWithPath: target.path).resolvingSymlinksInPath()
        let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // A writable file in a folder we cannot create files in.
            try data.write(to: url)
        }
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }

    // MARK: Save as

    /// Replaced in tests, where nobody can answer a panel. Gives the chosen path, already confirmed if it replaces a file.
    var chooseSavePath: ((@escaping (String?) -> Void) -> Void)?

    func saveAs(completion: ((Bool) -> Void)? = nil) {
        guard !isSaving else {
            completion?(false)
            return
        }
        chooseNewPath { [weak self] path in
            guard let self else { return }
            guard let path else {
                completion?(false)
                return
            }
            self.write(to: path, completion: completion)
        }
    }

    private func chooseNewPath(_ answer: @escaping (String?) -> Void) {
        if let chooseSavePath {
            chooseSavePath(answer)
        } else if target.source == nil {
            guard let window else { return answer(nil) }
            let panel = NSSavePanel()
            panel.directoryURL = URL(fileURLWithPath: (target.path as NSString).deletingLastPathComponent, isDirectory: true)
            panel.nameFieldStringValue = target.name
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            // The panel itself asks before replacing a file.
            panel.beginSheetModal(for: window) { answer($0 == .OK ? panel.url?.path : nil) }
        } else {
            askForRemotePath(answer)
        }
    }

    /// A file on a server gets a new name in its folder: the Mac's save panel can't browse servers.
    private func askForRemotePath(_ answer: @escaping (String?) -> Void) {
        guard let window, let source = target.source else { return answer(nil) }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = target.name
        let alert = NSAlert()
        alert.messageText = L10n.t("edit.saveAsTitle")
        alert.informativeText = (target.path as NSString).deletingLastPathComponent
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t("edit.saveAsConfirm"))
        alert.addButton(withTitle: L10n.t("common.cancel")).keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        let folder = (target.path as NSString).deletingLastPathComponent
        let queue = target.queue
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return answer(nil) }
            let path = PathUtil.join(folder, name)
            queue.async {
                let exists = (try? source.list(folder))?.contains { $0.name == name } ?? false
                DispatchQueue.main.async {
                    guard exists, let self else { return answer(path) }
                    self.showAlert(title: L10n.t("rich.existsTitle", name), text: L10n.t("edit.changedText"), buttons: [L10n.t("edit.overwrite"), L10n.t("common.cancel")], cancelIndex: 1, safeDefault: true) {
                        answer($0 == 0 ? path : nil)
                    }
                }
            }
        }
    }

    private func write(to path: String, completion: ((Bool) -> Void)?) {
        if Self.existing(path: path, source: target.source).map({ $0 !== self }) == true {
            showAlert(title: L10n.t("edit.alreadyOpen", (path as NSString).lastPathComponent), text: "", buttons: [L10n.t("common.ok")]) { _ in }
            completion?(false)
            return
        }
        guard let data = file.encode(textView.string) else {
            askToConvert { [weak self] convert in
                guard let self else { return }
                if convert {
                    self.file.encoding = .utf8
                    self.refreshStatus()
                    self.write(to: path, completion: completion)
                } else {
                    completion?(false)
                }
            }
            return
        }
        isSaving = true
        let revision = changeCount
        let newTarget = Target(name: (path as NSString).lastPathComponent, path: path, source: target.source, queue: target.queue)
        // The choice to replace is made by now, so this writes without comparing to the old file.
        Self.guardedWrite(data, target: newTarget, baseline: nil, ask: { $0(true) }, completion: { [weak self] outcome in
            guard let self else { return }
            self.isSaving = false
            switch outcome {
            case .saved(let newStamp):
                // From here on the window edits the new file, and the old one stays as it was.
                self.target = newTarget
                self.stamp = newStamp
                if self.changeCount == revision { self.isDirty = false }
                self.language = CodeLanguage.detect(fileName: newTarget.name)
                self.refreshVisualButton()
                self.updateTitle()
                self.analyze()
                self.scheduleCheck(delay: 0)
                self.refreshStatus()
                self.onSaved?()
                if newTarget.source != nil { self.onMessage?(L10n.t("editor.uploaded", newTarget.name)) }
                completion?(true)
            case .declined:
                completion?(false)
            case .failed(let error):
                self.showAlert(title: L10n.t("edit.saveFailed", newTarget.name), text: error.localizedDescription, buttons: [L10n.t("common.ok")]) { _ in }
                completion?(false)
            }
        })
    }

    func save(completion: ((Bool) -> Void)? = nil) {
        guard !isSaving else {
            completion?(false)
            return
        }
        let text = textView.string
        guard let data = file.encode(text) else {
            askToConvert { [weak self] convert in
                guard let self else { return }
                if convert {
                    self.file.encoding = .utf8
                    self.refreshStatus()
                    self.save(completion: completion)
                } else {
                    completion?(false)
                }
            }
            return
        }
        isSaving = true
        let revision = changeCount
        let target = self.target
        Self.guardedWrite(data, target: target, baseline: stamp, ask: { [weak self] answer in
            self?.askToOverwrite(answer) ?? answer(false)
        }, completion: { [weak self] outcome in
            guard let self else { return }
            self.isSaving = false
            switch outcome {
            case .saved(let newStamp):
                self.stamp = newStamp
                // Typing during an upload stays unsaved.
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
                self.showAlert(title: L10n.t("edit.saveFailed", target.name), text: error.localizedDescription, buttons: [L10n.t("common.ok")]) { _ in }
                completion?(false)
            }
        })
    }

    enum SaveOutcome {
        case saved(Stamp?)
        case declined
        case failed(Error)
    }

    /// Writes unless the file changed since `baseline` and `ask` says no. Shared by both editors.
    static func guardedWrite(_ data: Data, target: Target, baseline: Stamp?, ask: @escaping (@escaping (Bool) -> Void) -> Void, completion: @escaping (SaveOutcome) -> Void) {
        let write = {
            target.queue.async {
                do {
                    try store(data, target: target)
                    let newStamp = currentStamp(of: target)
                    DispatchQueue.main.async { completion(.saved(newStamp)) }
                } catch {
                    DispatchQueue.main.async { completion(.failed(error)) }
                }
            }
        }
        target.queue.async {
            let current = currentStamp(of: target)
            let changed = baseline != nil && current != nil && baseline != current
            DispatchQueue.main.async {
                guard changed else { write(); return }
                ask { $0 ? write() : completion(.declined) }
            }
        }
    }

    private func askToOverwrite(_ answer: @escaping (Bool) -> Void) {
        if let confirmOverwrite {
            confirmOverwrite(answer)
            return
        }
        showAlert(title: L10n.t("edit.changedTitle", target.name), text: L10n.t("edit.changedText"), buttons: [L10n.t("edit.overwrite"), L10n.t("common.cancel")], cancelIndex: 1, safeDefault: true) { answer($0 == 0) }
    }

    private func askToConvert(_ answer: @escaping (Bool) -> Void) {
        showAlert(title: L10n.t("edit.convertTitle", file.encoding.title), text: L10n.t("edit.convertText"), buttons: [L10n.t("edit.convert"), L10n.t("common.cancel")], cancelIndex: 1) { answer($0 == 0) }
    }

    /// `safeDefault` keeps Enter from confirming the first button.
    private func showAlert(title: String, text: String, buttons: [String], cancelIndex: Int? = nil, safeDefault: Bool = false, completion: @escaping (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        for (index, name) in buttons.enumerated() {
            let button = alert.addButton(withTitle: name)
            if index == cancelIndex { button.keyEquivalent = "\u{1b}" }
            if safeDefault, index == 0 { button.keyEquivalent = "" }
        }
        guard let window else {
            completion(alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            return
        }
        alert.beginSheetModal(for: window) { response in
            completion(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        }
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty || isSaving else { return true }
        askToDiscard { [weak self] closing in
            if closing { self?.closeWithoutAsking() }
        }
        return false
    }

    private func closeWithoutAsking() {
        isDirty = false
        window?.close()
    }

    /// Answers true when the work is safe and the window may go.
    func askToDiscard(_ answer: @escaping (Bool) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        showAlert(title: L10n.t("edit.unsavedTitle", target.name), text: L10n.t("edit.unsavedText"), buttons: [L10n.t("edit.save"), L10n.t("edit.dontSave"), L10n.t("common.cancel")], cancelIndex: 2) { [weak self] button in
            switch button {
            case 0: self?.save(completion: answer)
            case 1: answer(true)
            default: answer(false)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        checkWork?.cancel()
        analysisWork?.cancel()
        Self.openEditors.removeAll { $0 === self }
        OpenDocuments.remove(self)
    }

    func markClean() { isDirty = false }
}
