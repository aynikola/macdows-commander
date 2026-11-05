import AppKit
import ImageIO
import MacdowsCore
import WebKit

/// One image in the viewer. `fetch` gives a local file: right away on disk, after a download on a server.
struct ViewerItem {
    let name: String
    let size: Int64
    /// Where Save As starts. Nil for a file on a server.
    var localFolder: String? = nil
    let fetch: (@escaping (URL?) -> Void) -> Void
}

private enum ImageDecoder {
    /// Decoding at screen size instead of full size is what makes flipping through photos instant.
    static func decode(_ url: URL, maxPixels: Int, pdfPage: Int = 0) -> (image: NSImage, pixelSize: NSSize)? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let page = ImageOps.renderPDF(url, page: pdfPage, dpi: 144, maxPixelSide: maxPixels) else { return nil }
            let size = NSSize(width: page.width, height: page.height)
            return (NSImage(cgImage: page, size: size), size)
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let height = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                let size = NSSize(width: cg.width, height: cg.height)
                return (NSImage(cgImage: cg, size: size), NSSize(width: width, height: height))
            }
        }
        // SVG and other formats ImageIO does not read.
        if let image = NSImage(contentsOf: url), image.size.width > 0 { return (image, image.size) }
        return nil
    }
}

private final class ViewerWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    /// ⌘S and ⌘Z belong to the picture, unless a text field has the cursor.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !(firstResponder is NSText), attachedSheet == nil, onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Keeps a smaller-than-window image in the middle of the scroll view.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if document.frame.width < proposedBounds.width { rect.origin.x = (document.frame.width - proposedBounds.width) / 2 }
        if document.frame.height < proposedBounds.height { rect.origin.y = (document.frame.height - proposedBounds.height) / 2 }
        return rect
    }
}

private final class ThumbView: NSImageView {
    var onClick: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class ImageViewerController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, DocumentWindow {
    let items: [ViewerItem]
    private(set) var index: Int
    private var zoom: CGFloat = 1
    private(set) var generation = 0
    let cache = NSCache<NSString, CachedImage>()
    let decodeQueue = DispatchQueue(label: "macdows.viewer.decode", qos: .userInitiated, attributes: .concurrent)
    private let thumbQueue = DispatchQueue(label: "macdows.viewer.thumbs", qos: .utility, attributes: .concurrent)
    private let thumbSlots = DispatchSemaphore(value: 4)

    private let scroll = NSScrollView()
    let imageView = NSImageView()
    let overlay = ImageOverlayView()
    /// Set once the picture is being edited: it holds the full picture and the undo steps.
    var session: ImageEditHistory?
    /// The picture's real size, which can be larger than what was decoded for the screen.
    var displayPixels = NSSize.zero
    private var didFitWindow = false
    var resizeFields: ResizeFields?
    var pdfPage = 0
    var pdfPageCount = 0
    var pdfDPI: CGFloat = 200

    let undoButton = NSButton()
    let redoButton = NSButton()
    let pdfDPIPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pdfGroup = NSStackView()
    private let pdfLabel = NSTextField(labelWithString: "")
    let cropBar = NSStackView()
    let cropLabel = NSTextField(labelWithString: "")
    let textBar = NSStackView()
    let textField = NSTextField(string: "")
    let textFont = NSPopUpButton(frame: .zero, pullsDown: false)
    let textSize = NSTextField(string: "48")
    let textBold = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let textColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
    let textShadow = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let shadowColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
    let shadowBlur = NSTextField(string: "8")
    let shadowX = NSTextField(string: "3")
    let shadowY = NSTextField(string: "3")
    var onSaved: (() -> Void)?
    private let thumbStack = NSStackView()
    private var thumbs: [ThumbView] = []
    private var maxPixels = 2560

    var onIndexChange: ((String) -> Void)?
    var onEdit: ((Int) -> Void)?
    var onClosed: (() -> Void)?

    final class CachedImage {
        let image: NSImage
        let pixelSize: NSSize
        init(image: NSImage, pixelSize: NSSize) {
            self.image = image
            self.pixelSize = pixelSize
        }
    }

    init(items: [ViewerItem], start: Int) {
        self.items = items
        self.index = start
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: min(980, screen.width), height: min(680, screen.height)), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] in self?.handleKey($0) ?? false }
        window.onCancel = { [weak self] in self?.escapePressed() }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        maxPixels = Int(max(screen.width, screen.height) * scale)
        cache.countLimit = 12
        OpenDocuments.add(self)
        build(in: window)
        buildThumbs()
        show(index: start)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    private func build(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = imageView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        overlay.isHidden = true
        overlay.autoresizingMask = [.width, .height]
        overlay.frame = imageView.bounds
        overlay.onChange = { [weak self] in self?.updateCropLabel() }
        imageView.addSubview(overlay)
        let toolbar = buildToolbar()
        buildCropBar()
        buildTextBar()

        thumbStack.orientation = .horizontal
        thumbStack.spacing = 6
        thumbStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        thumbStack.translatesAutoresizingMaskIntoConstraints = false
        let strip = NSScrollView()
        strip.documentView = thumbStack
        strip.drawsBackground = false
        strip.hasHorizontalScroller = true
        strip.autohidesScrollers = true
        strip.translatesAutoresizingMaskIntoConstraints = false

        let bars = NSStackView(views: [cropBar, textBar])
        bars.orientation = .vertical
        bars.spacing = 0
        bars.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)
        content.addSubview(scroll)
        content.addSubview(bars)
        content.addSubview(strip)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bars.topAnchor),
            bars.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bars.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bars.bottomAnchor.constraint(equalTo: strip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            strip.heightAnchor.constraint(equalToConstant: items.count > 1 ? 84 : 0),
            thumbStack.topAnchor.constraint(equalTo: strip.contentView.topAnchor),
            thumbStack.leadingAnchor.constraint(equalTo: strip.contentView.leadingAnchor),
        ])
    }

    private func buildToolbar() -> NSView {
        let tool = { [unowned self] (key: String, selector: Selector) in ImageEditUI.button(L10n.t(key), self, selector) }
        undoButton.title = "↶"
        redoButton.title = "↷"
        for (button, selector, tip) in [(undoButton, #selector(undoClicked), "⌘Z"), (redoButton, #selector(redoClicked), "⌘⇧Z")] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.refusesFirstResponder = true
            button.target = self
            button.action = selector
            button.toolTip = tip
            button.isEnabled = false
        }
        let previous = ImageEditUI.button("◀", self, #selector(previousPageClicked))
        let next = ImageEditUI.button("▶", self, #selector(nextPageClicked))
        pdfLabel.font = AppFont.interface(12)
        pdfDPIPopup.controlSize = .small
        pdfDPIPopup.font = AppFont.interface(12)
        pdfDPIPopup.refusesFirstResponder = true
        pdfDPIPopup.addItems(withTitles: ["72", "150", "200", "300", "600"])
        pdfDPIPopup.selectItem(withTitle: "200")
        pdfDPIPopup.target = self
        pdfDPIPopup.action = #selector(dpiChanged)
        [previous, pdfLabel, next, ImageEditUI.labeled("DPI", pdfDPIPopup)].forEach { pdfGroup.addArrangedSubview($0) }
        pdfGroup.spacing = 4
        pdfGroup.isHidden = true
        let views: [NSView] = [
            tool("image.crop", #selector(cropClicked)), tool("image.resize", #selector(resizeClicked)), tool("image.canvas", #selector(canvasClicked)),
            ImageEditUI.button("↺", tip: L10n.t("image.rotateLeft") + " [", self, #selector(rotateLeftClicked)),
            ImageEditUI.button("↻", tip: L10n.t("image.rotateRight") + " ]", self, #selector(rotateRightClicked)),
            tool("image.rotate", #selector(rotateAngleClicked)),
            ImageEditUI.button("⇋", tip: L10n.t("image.flipH"), self, #selector(flipHorizontalClicked)),
            ImageEditUI.button("⇅", tip: L10n.t("image.flipV"), self, #selector(flipVerticalClicked)),
            tool("image.text", #selector(textClicked)), undoButton, redoButton, tool("image.saveAs", #selector(saveAsClicked)), pdfGroup,
        ]
        let toolbar = NSStackView(views: views + [NSView()])
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        return toolbar
    }

    private func buildCropBar() {
        cropLabel.font = AppFont.interface(12)
        [ImageEditUI.button(L10n.t("image.apply"), self, #selector(applyTool)), ImageEditUI.button(L10n.t("image.cancel"), self, #selector(cancelTool)), cropLabel, NSView()].forEach { cropBar.addArrangedSubview($0) }
        cropBar.spacing = 6
        cropBar.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        cropBar.isHidden = true
    }

    private func buildTextBar() {
        textField.placeholderString = L10n.t("image.textHint")
        textField.controlSize = .small
        textField.font = AppFont.interface(12)
        textField.delegate = self
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        textFont.controlSize = .small
        textFont.font = AppFont.interface(12)
        textFont.addItems(withTitles: NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") })
        textFont.selectItem(withTitle: "Helvetica")
        textFont.refusesFirstResponder = true
        textFont.widthAnchor.constraint(equalToConstant: 130).isActive = true
        textBold.title = L10n.t("image.bold")
        textShadow.title = L10n.t("image.shadow")
        textShadow.state = .on
        textColor.color = .white
        shadowColor.color = .black
        for control in [textFont, textBold, textShadow, textColor, shadowColor] as [NSControl] {
            control.target = self
            control.action = #selector(textChanged)
        }
        for well in [textColor, shadowColor] { well.widthAnchor.constraint(equalToConstant: 40).isActive = true }
        for (field, width) in [(textSize, CGFloat(46)), (shadowBlur, 34), (shadowX, 34), (shadowY, 34)] {
            field.controlSize = .small
            field.font = AppFont.interface(12)
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        let views: [NSView] = [
            textField, textFont, ImageEditUI.labeled(L10n.t("image.size"), textSize), textBold, textColor,
            textShadow, shadowColor, ImageEditUI.labeled(L10n.t("image.blur"), shadowBlur), ImageEditUI.labeled("X", shadowX), ImageEditUI.labeled("Y", shadowY),
            ImageEditUI.button(L10n.t("image.apply"), self, #selector(applyTool)), ImageEditUI.button(L10n.t("image.cancel"), self, #selector(cancelTool)),
        ]
        views.forEach { textBar.addArrangedSubview($0) }
        textBar.spacing = 6
        textBar.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        textBar.isHidden = true
    }

    func controlTextDidChange(_ notification: Notification) { textChanged() }

    private func buildThumbs() {
        guard items.count > 1 else { return }
        for (position, item) in items.enumerated() {
            let button = ThumbView()
            button.imageScaling = .scaleProportionallyUpOrDown
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
            button.layer?.borderColor = NSColor.white.cgColor
            button.layer?.cornerRadius = 3
            button.toolTip = item.name
            button.onClick = { [weak self] in self?.navigate(to: position) }
            button.widthAnchor.constraint(equalToConstant: 96).isActive = true
            button.heightAnchor.constraint(equalToConstant: 64).isActive = true
            thumbStack.addArrangedSubview(button)
            thumbs.append(button)
        }
    }

    /// Loads thumbnails near the cursor only: a server folder must not download everything.
    private func loadThumbs(around center: Int) {
        guard items.count > 1 else { return }
        let range = max(0, center - 8)...min(items.count - 1, center + 8)
        for position in range where thumbs[position].image == nil {
            items[position].fetch { [weak self] url in
                guard let self, let url else { return }
                self.thumbQueue.async {
                    self.thumbSlots.wait()
                    defer { self.thumbSlots.signal() }
                    let image = ImageDecoder.decode(url, maxPixels: 192)?.image
                    DispatchQueue.main.async { self.thumbs[position].image = image }
                }
            }
        }
    }

    // MARK: Showing

    private func navigate(to newIndex: Int) {
        let target = max(0, min(items.count - 1, newIndex))
        guard target != index else { return }
        leaveEdits { [weak self] in self?.show(index: target) }
    }

    func reshowCurrent() { show(index: index, keepPage: true) }

    private func cacheKey(_ name: String, page: Int) -> NSString { "\(name)#\(page)" as NSString }

    private func show(index newIndex: Int, keepPage: Bool = false) {
        index = max(0, min(items.count - 1, newIndex))
        zoom = 1
        generation += 1
        cancelTool()
        session = nil
        imageView.layer?.backgroundColor = nil
        if !keepPage {
            pdfPage = 0
            pdfPageCount = 0
        }
        refreshEditState()
        let current = generation
        let item = items[index]
        onIndexChange?(item.name)
        for (position, thumb) in thumbs.enumerated() {
            thumb.layer?.borderWidth = position == index ? 2 : 0
        }
        if !thumbs.isEmpty { thumbs[index].scrollToVisible(thumbs[index].bounds) }
        if let cached = cache.object(forKey: cacheKey(item.name, page: pdfPage)) {
            present(cached, for: item)
        } else {
            window?.title = "\(item.name) — \(index + 1) / \(items.count)"
            load(position: index, page: pdfPage) { [weak self] cached in
                guard let self, current == self.generation else { return }
                if let cached { self.present(cached, for: item) } else { self.imageView.image = nil }
            }
        }
        // The next and previous images are ready before you press the key.
        for offset in [1, -1, 2] where items.indices.contains(index + offset) {
            load(position: index + offset, completion: nil)
        }
        loadThumbs(around: index)
        updatePDFControls(item)
    }

    private func updatePDFControls(_ item: ViewerItem) {
        let isPDF = (item.name as NSString).pathExtension.lowercased() == "pdf"
        pdfGroup.isHidden = !isPDF
        guard isPDF else { return }
        pdfLabel.stringValue = pdfPageCount > 0 ? "\(pdfPage + 1) / \(pdfPageCount)" : ""
        guard pdfPageCount == 0 else { return }
        let current = generation
        item.fetch { [weak self] url in
            guard let self, let url, current == self.generation else { return }
            self.pdfPageCount = ImageOps.pdfPageCount(url)
            self.pdfLabel.stringValue = "\(self.pdfPage + 1) / \(self.pdfPageCount)"
        }
    }

    private func load(position: Int, page: Int = 0, completion: ((CachedImage?) -> Void)?) {
        let item = items[position]
        let key = cacheKey(item.name, page: page)
        if let cached = cache.object(forKey: key) {
            completion?(cached)
            return
        }
        item.fetch { [weak self] url in
            guard let self, let url else { completion?(nil); return }
            let maxPixels = self.maxPixels
            self.decodeQueue.async {
                let decoded = ImageDecoder.decode(url, maxPixels: maxPixels, pdfPage: page)
                DispatchQueue.main.async {
                    guard let decoded else { completion?(nil); return }
                    let cached = CachedImage(image: decoded.image, pixelSize: decoded.pixelSize)
                    self.cache.setObject(cached, forKey: key)
                    completion?(cached)
                }
            }
        }
    }

    private func present(_ cached: CachedImage, for item: ViewerItem) {
        imageView.image = cached.image
        displayPixels = cached.pixelSize.width > 0 ? cached.pixelSize : cached.image.size
        fitWindowOnce()
        layoutImage()
        refreshTitle()
    }

    /// The window takes the picture's size the first time, up to the screen, and is left alone after that.
    private func fitWindowOnce() {
        guard !didFitWindow, let window, let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        didFitWindow = true
        let chrome = window.frame.height - scroll.frame.height
        let width = min(screen.width, max(window.frame.width, displayPixels.width))
        let height = min(screen.height, max(window.frame.height, displayPixels.height + chrome + 2))
        var frame = NSRect(x: 0, y: 0, width: width, height: height)
        frame.origin = NSPoint(x: screen.midX - width / 2, y: screen.midY - height / 2)
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Below 100% only when the picture does not fit. A small picture stays small until you zoom in.
    private var scaleToShow: CGFloat {
        let available = scroll.contentSize
        guard displayPixels.width > 0, displayPixels.height > 0, available.width > 0, available.height > 0 else { return 1 }
        return min(1, min(available.width / displayPixels.width, available.height / displayPixels.height)) * zoom
    }

    func refreshTitle() {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        let size = "\(Int(displayPixels.width))×\(Int(displayPixels.height))"
        window?.title = "\(item.name) — \(index + 1) / \(items.count) — \(size) — \(Format.size(item.size)) — \(Int((scaleToShow * 100).rounded()))%"
    }

    func layoutImage() {
        guard imageView.image != nil, displayPixels.width > 0 else { return }
        let scale = scaleToShow
        imageView.frame = NSRect(x: 0, y: 0, width: (displayPixels.width * scale).rounded(), height: (displayPixels.height * scale).rounded())
        overlay.frame = imageView.bounds
        overlay.needsDisplay = true
    }

    private func setZoom(_ value: CGFloat) {
        zoom = max(0.1, min(16, value))
        layoutImage()
        refreshTitle()
    }

    func windowDidResize(_ notification: Notification) { layoutImage() }

    func windowWillClose(_ notification: Notification) {
        cancelTool()
        OpenDocuments.remove(self)
        onClosed?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        askToDiscard { [weak self] fine in
            guard fine, let self else { return }
            self.markClean()
            self.window?.close()
        }
        return false
    }

    var isDirty: Bool { session?.isDirty ?? false }
    func markClean() { session?.markSaved() }

    func askToDiscard(_ answer: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = L10n.t("image.unsavedTitle", items[index].name)
        alert.informativeText = L10n.t("image.unsavedText")
        alert.addButton(withTitle: L10n.t("image.discard"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.buttons[0].hasDestructiveAction = true
        guard let window else {
            answer(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }

    private func escapePressed() {
        if overlay.mode != .off {
            cancelTool()
        } else {
            window?.performClose(nil)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        let letter = event.charactersIgnoringModifiers?.lowercased()
        if command {
            switch letter {
            case "s": saveAsClicked()
            case "z": event.modifierFlags.contains(.shift) ? redoClicked() : undoClicked()
            default: return false
            }
            return true
        }
        if overlay.mode != .off {
            switch event.keyCode {
            case 36, 76: applyTool()
            case 53: cancelTool()
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 53, 99: // Esc, F3
            window?.performClose(nil)
        case 118: // F4
            onEdit?(index)
        case 124, 125, 121, 49: // right, down, page down, space
            navigate(to: index + 1)
        case 123, 126, 116: // left, up, page up
            navigate(to: index - 1)
        case 115: navigate(to: 0)
        case 119: navigate(to: items.count - 1)
        default:
            switch letter {
            case "+", "=": setZoom(zoom * 1.25)
            case "-": setZoom(zoom / 1.25)
            case "0": setZoom(1)
            case "c": cropClicked()
            case "r": resizeClicked()
            case "k": canvasClicked()
            case "t": textClicked()
            case "[": rotateLeftClicked()
            case "]": rotateRightClicked()
            default: return false
            }
        }
        return true
    }
}

private final class ViewerTextView: NSTextView {}

final class TextViewerController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    var onEdit: (() -> Void)?
    var onClosed: (() -> Void)?

    /// Previews stay quick on huge logs: only the start of the file is read.
    static let previewLimit = 8 << 20

    /// Text decoded from the start of a file, or nil when it looks binary.
    static func readText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: previewLimit) else { return "" }
        if data.prefix(8192).contains(0) { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        // A cut at the limit can split a UTF-8 character.
        if data.count == previewLimit { return String(decoding: data, as: UTF8.self) }
        let turkish = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatin5.rawValue)))
        return String(data: data, encoding: turkish)
    }

    /// How an HTML or Markdown file can also be shown as a page.
    struct PageView {
        let html: String
        let folder: String
        let source: FileSource?
        let queue: DispatchQueue
    }

    private static let showsPageKey = "viewer.showsPage"
    private let pageView: PageView?
    private var webView: WKWebView?
    private let textScroll: NSScrollView
    private let modes = NSSegmentedControl()

    /// The page for a file this viewer can show as one, or nil.
    static func pageHTML(fileName: String, text: String) -> String? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "html", "htm": return text
        case "md", "markdown", "mdown", "mkd": return Markdown.page(text)
        default: return nil
        }
    }

    var isShowingPage: Bool { webView?.isHidden == false }

    init(name: String, detail: String, text: String, pageView: PageView? = nil) {
        self.pageView = pageView
        let frame = NSRect(x: 0, y: 0, width: 960, height: 720)
        let window = KeyFirstWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "\(name) — \(detail)"
        Theme.apply(to: window)
        textScroll = ViewerTextView.scrollableTextView()
        super.init(window: window)
        window.delegate = self
        window.center()

        // scrollableTextView gives a plain NSTextView, so build our own subclass inside it.
        let textView = ViewerTextView(frame: textScroll.bounds)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = AppFont.mono
        textView.backgroundColor = Theme.background
        textView.textColor = Theme.text
        textView.string = text
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textScroll.documentView = textView
        window.onKey = { [weak self] in self?.handleKey($0) ?? false }

        guard pageView != nil, let content = window.contentView else {
            window.contentView = textScroll
            window.makeFirstResponder(textView)
            return
        }
        modes.segmentCount = 2
        modes.setLabel(L10n.t("viewer.source"), forSegment: 0)
        modes.setLabel(L10n.t("viewer.page"), forSegment: 1)
        modes.trackingMode = .selectOne
        modes.controlSize = .small
        modes.font = AppFont.interface(12)
        modes.target = self
        modes.action = #selector(modeChanged)
        modes.toolTip = "Tab"
        modes.refusesFirstResponder = true
        modes.translatesAutoresizingMaskIntoConstraints = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(modes)
        content.addSubview(textScroll)
        NSLayoutConstraint.activate([
            modes.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            modes.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            textScroll.topAnchor.constraint(equalTo: modes.bottomAnchor, constant: 6),
            textScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        // The page is what most people open these files to see, until they choose otherwise.
        let showsPage = UserDefaults.standard.object(forKey: Self.showsPageKey) as? Bool ?? true
        show(page: showsPage)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53, 99:
            close()
        case 118:
            onEdit?()
        case 48 where pageView != nil:
            show(page: !isShowingPage)
            UserDefaults.standard.set(isShowingPage, forKey: Self.showsPageKey)
        default:
            return false
        }
        return true
    }

    @objc private func modeChanged() {
        show(page: modes.selectedSegment == 1)
        UserDefaults.standard.set(isShowingPage, forKey: Self.showsPageKey)
    }

    func show(page: Bool) {
        modes.selectedSegment = page ? 1 : 0
        if page, webView == nil { buildPage() }
        webView?.isHidden = !page
        textScroll.isHidden = page
        window?.makeFirstResponder(page ? webView : textScroll.documentView)
    }

    private func buildPage() {
        guard let pageView, let content = window?.contentView else { return }
        let configuration = WKWebViewConfiguration()
        // A file off a server is only ever looked at here: its scripts don't run.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(DocumentFilesHandler(source: pageView.source, queue: pageView.queue), forURLScheme: DocumentFilesHandler.scheme)
        let web = WKWebView(frame: textScroll.frame, configuration: configuration)
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: textScroll.topAnchor),
            web.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: textScroll.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: textScroll.bottomAnchor),
        ])
        var base = URLComponents()
        base.scheme = DocumentFilesHandler.scheme
        base.host = "doc"
        base.path = pageView.folder.hasSuffix("/") ? pageView.folder : pageView.folder + "/"
        web.loadHTMLString(pageView.html, baseURL: base.url)
        webView = web
    }

    /// Links open in the browser, so the viewer keeps showing the file.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == DocumentFilesHandler.scheme, url.fragment != nil {
            decisionHandler(.allow)
            return
        }
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func windowWillClose(_ notification: Notification) { onClosed?() }
}
