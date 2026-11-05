import AppKit
import MacdowsCore

/// ⌥F3: two files side by side, lined up, with what differs in color.
final class CompareWindowController: NSWindowController, NSWindowDelegate {
    struct Side {
        let title: String
        let text: String
        var size: Int64 = 0
        var date: Date? = nil
    }

    enum Age: Equatable { case newer, older, same, unknown }

    /// How the first date compares with the second. A file without a date can't be called newer.
    static func age(of first: Date?, against second: Date?) -> Age {
        guard let first, let second else { return .unknown }
        // Servers often round to the second or the minute, so a hair's difference isn't an age.
        if abs(first.timeIntervalSince(second)) < 1 { return .same }
        return first > second ? .newer : .older
    }

    /// The line under a file's name: its size, its date and how old it is next to the other file.
    static func details(of side: Side, against other: Side) -> String {
        var parts = [Format.size(side.size)]
        if side.date != nil { parts.append(Format.date(side.date)) }
        switch age(of: side.date, against: other.date) {
        case .newer: parts.append(L10n.t("compare.newer"))
        case .older: parts.append(L10n.t("compare.older"))
        case .same: parts.append(L10n.t("compare.sameDate"))
        case .unknown: break
        }
        return parts.joined(separator: " · ")
    }

    private static var open: [CompareWindowController] = []

    private let left: Side
    private let right: Side
    private let leftLines: [String]
    private let rightLines: [String]
    private let leftView = NSTextView()
    private let rightView = NSTextView()
    private let leftScroll = NSScrollView()
    private let rightScroll = NSScrollView()
    private let summary = NSTextField(labelWithString: "")
    private(set) lazy var leftDetails = NSTextField(labelWithString: Self.details(of: left, against: right))
    private(set) lazy var rightDetails = NSTextField(labelWithString: Self.details(of: right, against: left))
    private let ignoreSpace = NSButton(checkboxWithTitle: L10n.t("compare.ignoreSpace"), target: nil, action: nil)
    private var isSyncing = false
    private(set) var rows: [DiffRow] = []
    private(set) var changes: [Int] = []
    private(set) var currentChange = -1
    /// Line endings or encoding can differ when every line reads the same.
    private let bytesDiffer: Bool

    init(left: Side, right: Side, bytesDiffer: Bool) {
        self.left = left
        self.right = right
        self.bytesDiffer = bytesDiffer
        leftLines = LineDiff.lines(of: left.text)
        rightLines = LineDiff.lines(of: right.text)
        let window = KeyFirstWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "\(left.title) ↔ \(right.title)"
        Theme.apply(to: window)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] in self?.handleKey($0) ?? false }
        build(in: window)
        render()
        Self.open.append(self)
        NotificationCenter.default.addObserver(self, selector: #selector(render), name: .themeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self } }

    private func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = AppFont.interface(12, bold: true)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func configure(_ view: NSTextView, in scroll: NSScrollView) {
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = Theme.editorBackground
        view.textColor = Theme.editorText
        view.font = AppFont.mono
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // No wrapping, or the two sides would stop lining up.
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    private func build(in window: NSWindow) {
        guard let content = window.contentView else { return }
        configure(leftView, in: leftScroll)
        configure(rightView, in: rightScroll)
        let previous = NSButton(title: L10n.t("compare.previous"), target: self, action: #selector(previousClicked))
        let next = NSButton(title: L10n.t("compare.next"), target: self, action: #selector(nextClicked))
        for button in [previous, next] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = AppFont.interface(12)
            button.refusesFirstResponder = true
        }
        ignoreSpace.target = self
        ignoreSpace.action = #selector(render)
        ignoreSpace.controlSize = .small
        ignoreSpace.font = AppFont.interface(12)
        ignoreSpace.refusesFirstResponder = true
        summary.font = AppFont.interface(12)
        summary.textColor = Theme.secondaryText
        let bar = NSStackView(views: [previous, next, ignoreSpace, summary, NSView()])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 2, right: 8)
        let leftTitle = title(left.title), rightTitle = title(right.title)
        let titles = NSStackView(views: [leftTitle, rightTitle])
        titles.distribution = .fillEqually
        titles.spacing = 2
        titles.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 0, right: 8)
        let isNewer = { (side: Side, other: Side) in Self.age(of: side.date, against: other.date) == .newer }
        for (label, newer) in [(leftDetails, isNewer(left, right)), (rightDetails, isNewer(right, left))] {
            label.font = AppFont.interface(12, bold: newer)
            label.textColor = newer ? Theme.success : Theme.secondaryText
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let details = NSStackView(views: [leftDetails, rightDetails])
        details.distribution = .fillEqually
        details.spacing = 2
        details.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 4, right: 8)
        let panes = NSStackView(views: [leftScroll, rightScroll])
        panes.distribution = .fillEqually
        panes.spacing = 2
        for view in [bar, titles, details, panes] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            titles.topAnchor.constraint(equalTo: bar.bottomAnchor),
            details.topAnchor.constraint(equalTo: titles.bottomAnchor),
            panes.topAnchor.constraint(equalTo: details.bottomAnchor),
            panes.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    @objc private func render() {
        rows = LineDiff.compare(leftLines, rightLines, ignoringSpace: ignoreSpace.state == .on)
        changes = LineDiff.changeStarts(rows)
        currentChange = -1
        leftView.textStorage?.setAttributedString(side(leftLines, isLeft: true))
        rightView.textStorage?.setAttributedString(side(rightLines, isLeft: false))
        if changes.isEmpty {
            summary.stringValue = L10n.t(bytesDiffer ? "compare.onlyEndings" : "compare.same")
        } else {
            summary.stringValue = L10n.t("compare.count", String(changes.count))
            goTo(change: 0)
        }
    }

    private func side(_ lines: [String], isLeft: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = AppFont.mono
        let digits = String(max(leftLines.count, rightLines.count)).count
        result.beginEditing()
        for row in rows {
            let number = isLeft ? row.left : row.right
            let prefix = number.map { String(repeating: " ", count: digits - String($0 + 1).count) + String($0 + 1) } ?? String(repeating: " ", count: digits)
            let line = number.map { lines[$0] } ?? ""
            let start = result.length
            result.append(NSAttributedString(string: prefix + "  ", attributes: [.font: font, .foregroundColor: Theme.gutterText]))
            let textStart = result.length
            result.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: Theme.editorText]))
            let whole = NSRange(location: start, length: result.length - start)
            switch row.kind {
            case .same: break
            case .removed where number != nil, .added where number != nil:
                result.addAttribute(.backgroundColor, value: isLeft ? Theme.diffRemoved : Theme.diffAdded, range: whole)
            case .removed, .added:
                result.addAttribute(.backgroundColor, value: Theme.diffEmpty, range: whole)
            case .changed:
                result.addAttribute(.backgroundColor, value: Theme.diffChanged, range: whole)
                if let l = row.left, let r = row.right {
                    let parts = LineDiff.changedRanges(leftLines[l], rightLines[r])
                    let part = isLeft ? parts.left : parts.right
                    if part.length > 0 { result.addAttribute(.backgroundColor, value: Theme.diffWord, range: NSRange(location: textStart + part.location, length: part.length)) }
                }
            }
        }
        result.endEditing()
        return result
    }

    @objc private func scrolled(_ notification: Notification) {
        guard !isSyncing, let clip = notification.object as? NSClipView else { return }
        isSyncing = true
        let other = clip === leftScroll.contentView ? rightScroll : leftScroll
        other.contentView.scroll(to: clip.bounds.origin)
        other.reflectScrolledClipView(other.contentView)
        isSyncing = false
    }

    @objc private func previousClicked() { moveChange(by: -1) }
    @objc private func nextClicked() { moveChange(by: 1) }

    func moveChange(by step: Int) {
        guard !changes.isEmpty else { return }
        goTo(change: (currentChange + step + changes.count) % changes.count)
    }

    private func goTo(change: Int) {
        currentChange = change
        summary.stringValue = L10n.t("compare.position", String(change + 1), String(changes.count))
        guard let manager = leftView.layoutManager, let container = leftView.textContainer else { return }
        // Rows are one line each, so a row's place is its number times the line height.
        manager.ensureLayout(for: container)
        let height = manager.defaultLineHeight(for: AppFont.mono)
        let y = max(0, CGFloat(changes[change]) * height - height * 4)
        leftScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        leftScroll.reflectScrolledClipView(leftScroll.contentView)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            close()
        case 99: // F3
            moveChange(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        default:
            return false
        }
        return true
    }
}
