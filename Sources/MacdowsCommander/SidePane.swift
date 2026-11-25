import AppKit
import AVKit

/// A pane laid over the panel that is not being used: size info (Ctrl+Q), preview (⌥F3) or the AI chat (F12).
/// The keyboard stays with the other panel, so the arrow keys keep moving the cursor and the pane follows.
final class SidePaneView: NSView {
    var onClose: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let body = NSView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        titleLabel.font = AppFont.interface(12, bold: true)
        titleLabel.textColor = Theme.onAccent
        titleLabel.lineBreakMode = .byTruncatingTail
        hint.font = AppFont.interface(11)
        hint.textColor = Theme.onAccent.withAlphaComponent(0.85)
        hint.alignment = .right
        hint.lineBreakMode = .byTruncatingHead
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.title = "✕"
        closeButton.isBordered = false
        closeButton.font = AppFont.interface(13, bold: true)
        closeButton.contentTintColor = Theme.onAccent
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Esc"
        let header = NSStackView(views: [titleLabel, hint, closeButton])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.accent.cgColor
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(body)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    /// Short text on the right of the title bar, such as the folder that is being shown.
    var detail: String {
        get { hint.stringValue }
        set { hint.stringValue = newValue }
    }

    func setBody(_ view: NSView) {
        body.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: body.topAnchor),
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        Theme.accent.setStroke()
        let frame = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        frame.lineWidth = 2
        frame.stroke()
    }

    @objc private func closeClicked() { onClose?() }
}

/// Read-only text with a bold title and "label: value" lines.
final class InfoPaneContent: NSView {
    private let scroll = NSTextView.scrollableTextView()
    let finderButton = NSButton()

    private var text: NSTextView? { scroll.documentView as? NSTextView }

    init() {
        super.init(frame: .zero)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        finderButton.translatesAutoresizingMaskIntoConstraints = false
        finderButton.bezelStyle = .rounded
        finderButton.controlSize = .small
        finderButton.font = AppFont.interface(11)
        addSubview(scroll)
        addSubview(finderButton)
        text?.isEditable = false
        text?.drawsBackground = false
        text?.textContainerInset = NSSize(width: 12, height: 12)
        scroll.drawsBackground = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: finderButton.topAnchor, constant: -6),
            finderButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            finderButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    var plainText: String { text?.string ?? "" }

    func show(title: String, lines: [(String, String)]) {
        let result = NSMutableAttributedString()
        let heading = NSMutableParagraphStyle()
        heading.paragraphSpacing = 10
        result.append(NSAttributedString(string: title + "\n", attributes: [.font: AppFont.interface(AppFont.size + 4, bold: true), .foregroundColor: Theme.text, .paragraphStyle: heading]))
        let row = NSMutableParagraphStyle()
        row.paragraphSpacing = 5
        row.tabStops = [NSTextTab(textAlignment: .left, location: AppFont.size * 9)]
        row.headIndent = AppFont.size * 9
        for (label, value) in lines {
            result.append(NSAttributedString(string: label, attributes: [.font: AppFont.interface(AppFont.size - 1), .foregroundColor: Theme.hiddenText, .paragraphStyle: row]))
            result.append(NSAttributedString(string: "\t" + value + "\n", attributes: [.font: AppFont.interface(AppFont.size), .foregroundColor: Theme.text, .paragraphStyle: row]))
        }
        text?.textStorage?.setAttributedString(result)
    }
}

/// What the ⌥F3 pane shows for the file under the cursor.
final class PreviewPaneContent: NSView {
    private let imageView = NSImageView()
    private let textScroll = NSTextView.scrollableTextView()
    private let player = AVPlayerView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var shown: NSView?

    private var textView: NSTextView? { textScroll.documentView as? NSTextView }

    enum Shown { case nothing, image, text, media, message }
    private(set) var kind = Shown.nothing
    var shownText: String { kind == .text ? textView?.string ?? "" : message.stringValue }

    init() {
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        player.controlsStyle = .inline
        textView?.isEditable = false
        textView?.backgroundColor = Theme.background
        textView?.textColor = Theme.text
        textView?.textContainerInset = NSSize(width: 10, height: 10)
        message.textColor = Theme.hiddenText
        message.alignment = .center
        message.font = AppFont.interface(AppFont.size)
        for view in [imageView, textScroll, player, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = true
            addSubview(view)
        }
        for view in [imageView, textScroll, player] as [NSView] {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        }
        NSLayoutConstraint.activate([
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    private func only(_ view: NSView) {
        kind = view === imageView ? .image : view === textScroll ? .text : view === player ? .media : .message
        if view !== player { player.player?.pause() }
        for other in [imageView, textScroll, player, message] as [NSView] { other.isHidden = other !== view }
    }

    func show(image: NSImage) {
        imageView.image = image
        only(imageView)
    }

    func show(text: String, monospaced: Bool = true) {
        textView?.font = monospaced ? AppFont.mono : AppFont.interface(AppFont.size)
        textView?.string = text
        textView?.scrollToBeginningOfDocument(nil)
        only(textScroll)
    }

    func show(media url: URL) {
        player.player?.pause()
        player.player = AVPlayer(url: url)
        only(player)
    }

    func show(message text: String) {
        message.stringValue = text
        only(message)
    }

    func stop() {
        player.player?.pause()
        player.player = nil
    }
}
