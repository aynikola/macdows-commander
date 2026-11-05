import AppKit
import MacdowsCore

/// Sits over the picture while cropping or placing text. Everything it holds is in the picture's pixels, from the top left.
final class ImageOverlayView: NSView {
    enum Mode { case off, crop, text }

    var mode = Mode.off { didSet { isHidden = mode == .off; needsDisplay = true } }
    var pixelSize = NSSize(width: 1, height: 1)
    var cropRect = CGRect.zero { didSet { needsDisplay = true; onChange?() } }
    var textBlock: TextBlock? { didSet { needsDisplay = true } }
    var onChange: (() -> Void)?

    private enum Drag {
        case corner(oppositeX: CGFloat, oppositeY: CGFloat)
        case move(dx: CGFloat, dy: CGFloat)
        case text(dx: CGFloat, dy: CGFloat)
    }
    private var drag: Drag?
    private let handle: CGFloat = 10

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var scale: CGFloat { bounds.width / max(1, pixelSize.width) }

    private func viewRect(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX * scale, y: bounds.height - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    private func pixelPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x / scale, y: (bounds.height - point.y) / scale)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(pixelSize.width, point.x)), y: max(0, min(pixelSize.height, point.y)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        switch mode {
        case .off: break
        case .crop: drawCrop(context)
        case .text:
            guard let textBlock else { return }
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            ImageOps.draw(textBlock, in: context, canvasHeight: pixelSize.height, deviceScale: scale * (window?.backingScaleFactor ?? 2))
            context.restoreGState()
            let frame = NSBezierPath(rect: viewRect(ImageOps.bounds(of: textBlock)).insetBy(dx: -2, dy: -2))
            frame.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.8).setStroke()
            frame.stroke()
        }
    }

    private func drawCrop(_ context: CGContext) {
        let area = viewRect(cropRect)
        let shade = NSBezierPath(rect: bounds)
        shade.append(NSBezierPath(rect: area))
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        shade.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        for third in 1...2 {
            let x = area.minX + area.width * CGFloat(third) / 3, y = area.minY + area.height * CGFloat(third) / 3
            NSBezierPath.strokeLine(from: NSPoint(x: x, y: area.minY), to: NSPoint(x: x, y: area.maxY))
            NSBezierPath.strokeLine(from: NSPoint(x: area.minX, y: y), to: NSPoint(x: area.maxX, y: y))
        }
        NSColor.white.setStroke()
        NSBezierPath(rect: area).stroke()
        NSColor.white.setFill()
        for x in [area.minX, area.maxX] {
            for y in [area.minY, area.maxY] {
                NSRect(x: x - handle / 2, y: y - handle / 2, width: handle, height: handle).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = pixelPoint(event)
        switch mode {
        case .off: break
        case .crop:
            let reach = (handle + 4) / scale
            let corners = [(cropRect.minX, cropRect.minY), (cropRect.maxX, cropRect.minY), (cropRect.minX, cropRect.maxY), (cropRect.maxX, cropRect.maxY)]
            if let hit = corners.first(where: { abs($0.0 - point.x) <= reach && abs($0.1 - point.y) <= reach }) {
                drag = .corner(oppositeX: hit.0 == cropRect.minX ? cropRect.maxX : cropRect.minX, oppositeY: hit.1 == cropRect.minY ? cropRect.maxY : cropRect.minY)
            } else if cropRect.contains(point) {
                drag = .move(dx: point.x - cropRect.minX, dy: point.y - cropRect.minY)
            } else {
                let start = clamped(point)
                drag = .corner(oppositeX: start.x, oppositeY: start.y)
            }
        case .text:
            guard let textBlock else { return }
            if ImageOps.bounds(of: textBlock).contains(point) {
                drag = .text(dx: point.x - textBlock.x, dy: point.y - textBlock.y)
            } else {
                drag = .text(dx: 0, dy: 0)
                self.textBlock?.x = point.x
                self.textBlock?.y = point.y
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = pixelPoint(event)
        switch drag {
        case .corner(let oppositeX, let oppositeY):
            let end = clamped(point)
            cropRect = CGRect(x: min(end.x, oppositeX), y: min(end.y, oppositeY), width: abs(end.x - oppositeX), height: abs(end.y - oppositeY))
        case .move(let dx, let dy):
            let x = max(0, min(pixelSize.width - cropRect.width, point.x - dx))
            let y = max(0, min(pixelSize.height - cropRect.height, point.y - dy))
            cropRect.origin = CGPoint(x: x, y: y)
        case .text(let dx, let dy):
            textBlock?.x = point.x - dx
            textBlock?.y = point.y - dy
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) { drag = nil }
}

/// The fields of the Resize dialog: changing one side changes the other while the ratio is locked.
final class ResizeFields: NSObject, NSTextFieldDelegate {
    let widthField: NSTextField
    let heightField: NSTextField
    let lock: NSButton
    private let ratio: CGFloat

    init(width: Int, height: Int) {
        widthField = NSTextField(string: String(width))
        heightField = NSTextField(string: String(height))
        lock = NSButton(checkboxWithTitle: L10n.t("image.keepRatio"), target: nil, action: nil)
        lock.state = .on
        ratio = CGFloat(width) / CGFloat(max(1, height))
        super.init()
        widthField.delegate = self
        heightField.delegate = self
    }

    func controlTextDidChange(_ notification: Notification) {
        guard lock.state == .on, let field = notification.object as? NSTextField, let value = Double(field.stringValue) else { return }
        if field === widthField {
            heightField.stringValue = String(max(1, Int((CGFloat(value) / ratio).rounded())))
        } else {
            widthField.stringValue = String(max(1, Int((CGFloat(value) * ratio).rounded())))
        }
    }
}

enum ImageEditUI {
    static func labeled(_ title: String, _ view: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = AppFont.interface(11)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, view])
        row.spacing = 4
        return row
    }

    static func numberField(_ value: CGFloat, width: CGFloat = 50) -> NSTextField {
        let field = NSTextField(string: String(Int(value)))
        field.controlSize = .small
        field.font = AppFont.interface(12)
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    static func button(_ title: String, tip: String? = nil, _ target: AnyObject, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: selector)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = AppFont.interface(12)
        button.refusesFirstResponder = true
        button.toolTip = tip
        return button
    }

    static func cgColor(_ well: NSColorWell) -> CGColor {
        (well.color.usingColorSpace(.sRGB) ?? well.color).cgColor
    }

    static func form(_ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(origin: .zero, size: NSSize(width: 300, height: stack.fittingSize.height))
        return stack
    }
}

extension ImageViewerController {
    // MARK: Loading for edits

    /// Editing needs the full picture, while viewing only decodes it at screen size.
    func withSession(_ body: @escaping (ImageEditHistory) -> Void) {
        if let session {
            body(session)
            return
        }
        let current = generation, page = pdfPage, dpi = pdfDPI
        items[index].fetch { [weak self] url in
            guard let self, let url else { return }
            self.decodeQueue.async {
                var image = ImageOps.load(url, pdfPage: page, dpi: dpi)
                if image == nil, let picture = NSImage(contentsOf: url) {
                    image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
                DispatchQueue.main.async {
                    guard current == self.generation else { return }
                    guard let image else {
                        self.showProblem(L10n.t("image.cannotOpen", self.items[self.index].name))
                        return
                    }
                    let history = ImageEditHistory(image: image)
                    self.session = history
                    self.presentSession()
                    body(history)
                }
            }
        }
    }

    func presentSession() {
        guard let session else { return }
        let image = session.current
        let size = NSSize(width: image.width, height: image.height)
        imageView.image = NSImage(cgImage: image, size: size)
        displayPixels = size
        overlay.pixelSize = size
        showTransparency(ImageOps.hasAlpha(image))
        layoutImage()
        refreshEditState()
    }

    private func showTransparency(_ show: Bool) {
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = show ? NSColor(patternImage: Self.checkerboard).cgColor : nil
    }

    private static let checkerboard = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        NSColor(white: 0.55, alpha: 1).setFill()
        rect.fill()
        NSColor(white: 0.75, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSRect(x: 8, y: 8, width: 8, height: 8).fill()
        return true
    }

    func refreshEditState() {
        window?.isDocumentEdited = isDirty
        undoButton.isEnabled = session?.canUndo ?? false
        redoButton.isEnabled = session?.canRedo ?? false
        pdfDPIPopup.isEnabled = !isDirty
        refreshTitle()
    }

    func apply(_ operation: @escaping (CGImage) -> CGImage?) {
        withSession { [weak self] session in
            guard let self else { return }
            guard let result = operation(session.current) else {
                self.showProblem(L10n.t("image.tooLarge", String(ImageOps.maxSide)))
                return
            }
            session.push(result)
            self.presentSession()
        }
    }

    func showProblem(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: L10n.t("common.ok"))
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func askForm(title: String, form: NSView, first: NSView?, accepted: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = form
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: L10n.t("common.cancel"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { accepted() }
        }
        alert.window.initialFirstResponder = first
        alert.window.makeFirstResponder(first)
    }

    private func side(_ field: NSTextField) -> Int? {
        guard let value = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), value >= 1, value <= ImageOps.maxSide else {
            showProblem(L10n.t("image.badSize", String(ImageOps.maxSide)))
            return nil
        }
        return value
    }

    // MARK: Commands

    @objc func resizeClicked() {
        cancelTool()
        withSession { [weak self] session in
            guard let self else { return }
            let fields = ResizeFields(width: session.current.width, height: session.current.height)
            self.resizeFields = fields
            let form = ImageEditUI.form([ImageEditUI.labeled(L10n.t("image.width"), fields.widthField), ImageEditUI.labeled(L10n.t("image.height"), fields.heightField), fields.lock])
            fields.widthField.widthAnchor.constraint(equalToConstant: 90).isActive = true
            fields.heightField.widthAnchor.constraint(equalToConstant: 90).isActive = true
            self.askForm(title: L10n.t("image.resizeTitle"), form: form, first: fields.widthField) {
                guard let width = self.side(fields.widthField), let height = self.side(fields.heightField) else { return }
                self.apply { ImageOps.resized($0, width: width, height: height) }
            }
        }
    }

    @objc func canvasClicked() {
        cancelTool()
        withSession { [weak self] session in
            guard let self else { return }
            let width = NSTextField(string: String(session.current.width)), height = NSTextField(string: String(session.current.height))
            width.widthAnchor.constraint(equalToConstant: 90).isActive = true
            height.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let anchors: [(String, CGFloat, CGFloat)] = [
                ("topLeft", 0, 0), ("top", 0.5, 0), ("topRight", 1, 0),
                ("left", 0, 0.5), ("center", 0.5, 0.5), ("right", 1, 0.5),
                ("bottomLeft", 0, 1), ("bottom", 0.5, 1), ("bottomRight", 1, 1),
            ]
            let anchor = NSPopUpButton(frame: .zero, pullsDown: false)
            anchors.forEach { anchor.addItem(withTitle: L10n.t("image.anchor.\($0.0)")) }
            anchor.selectItem(at: 4)
            let transparent = NSButton(checkboxWithTitle: L10n.t("image.transparent"), target: nil, action: nil)
            transparent.state = .on
            let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
            well.color = .white
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let form = ImageEditUI.form([
                ImageEditUI.labeled(L10n.t("image.width"), width), ImageEditUI.labeled(L10n.t("image.height"), height),
                ImageEditUI.labeled(L10n.t("image.anchor"), anchor), transparent, ImageEditUI.labeled(L10n.t("image.fillColor"), well),
            ])
            self.askForm(title: L10n.t("image.canvasTitle"), form: form, first: width) {
                guard let w = self.side(width), let h = self.side(height) else { return }
                let choice = anchors[anchor.indexOfSelectedItem]
                let fill = transparent.state == .on ? nil : ImageEditUI.cgColor(well)
                NSColorPanel.shared.orderOut(nil)
                self.apply { ImageOps.canvas($0, width: w, height: h, anchorX: choice.1, anchorY: choice.2, fill: fill) }
            }
        }
    }

    @objc func rotateLeftClicked() { cancelTool(); apply { ImageOps.rotated($0, degrees: -90) } }
    @objc func rotateRightClicked() { cancelTool(); apply { ImageOps.rotated($0, degrees: 90) } }
    @objc func flipHorizontalClicked() { cancelTool(); apply { ImageOps.flipped($0, horizontally: true) } }
    @objc func flipVerticalClicked() { cancelTool(); apply { ImageOps.flipped($0, horizontally: false) } }

    @objc func rotateAngleClicked() {
        cancelTool()
        let angle = NSTextField(string: "15")
        angle.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let form = ImageEditUI.form([ImageEditUI.labeled(L10n.t("image.angle"), angle)])
        askForm(title: L10n.t("image.rotateTitle"), form: form, first: angle) { [weak self] in
            let text = angle.stringValue.replacingOccurrences(of: ",", with: ".")
            guard let self else { return }
            guard let degrees = Double(text) else {
                self.showProblem(L10n.t("image.badAngle"))
                return
            }
            self.apply { ImageOps.rotated($0, degrees: CGFloat(degrees)) }
        }
    }

    @objc func undoClicked() {
        cancelTool()
        session?.undo()
        presentSession()
    }

    @objc func redoClicked() {
        cancelTool()
        session?.redo()
        presentSession()
    }

    // MARK: Crop

    @objc func cropClicked() {
        cancelTool()
        withSession { [weak self] session in
            guard let self else { return }
            let w = CGFloat(session.current.width), h = CGFloat(session.current.height)
            self.overlay.cropRect = CGRect(x: (w * 0.1).rounded(), y: (h * 0.1).rounded(), width: (w * 0.8).rounded(), height: (h * 0.8).rounded())
            self.overlay.mode = .crop
            self.setBar(self.cropBar)
            self.window?.makeFirstResponder(self.window)
        }
    }

    func updateCropLabel() {
        cropLabel.stringValue = "\(Int(overlay.cropRect.width)) × \(Int(overlay.cropRect.height))"
    }

    @objc func applyTool() {
        switch overlay.mode {
        case .off: break
        case .crop:
            let rect = overlay.cropRect
            cancelTool()
            apply { ImageOps.cropped($0, to: rect) }
        case .text:
            let block = overlay.textBlock
            cancelTool()
            guard let block, !block.text.isEmpty else { return }
            apply { ImageOps.drawing(block, on: $0) }
        }
    }

    @objc func cancelTool() {
        overlay.mode = .off
        overlay.textBlock = nil
        setBar(nil)
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
    }

    func setBar(_ bar: NSView?) {
        cropBar.isHidden = bar !== cropBar
        textBar.isHidden = bar !== textBar
        window?.contentView?.layoutSubtreeIfNeeded()
        layoutImage()
    }

    // MARK: Text

    @objc func textClicked() {
        cancelTool()
        withSession { [weak self] session in
            guard let self else { return }
            let height = CGFloat(session.current.height), width = CGFloat(session.current.width)
            let size = max(12, (min(width, height) / 10).rounded())
            self.textSize.stringValue = String(Int(size))
            let block = TextBlock(text: self.textField.stringValue, fontName: "Helvetica", fontSize: size, color: CGColor(gray: 1, alpha: 1), x: (width * 0.08).rounded(), y: (height * 0.08).rounded())
            self.overlay.textBlock = block
            self.overlay.mode = .text
            self.setBar(self.textBar)
            self.textChanged()
            self.window?.makeFirstResponder(self.textField)
        }
    }

    @objc func textChanged() {
        guard var block = overlay.textBlock else { return }
        block.text = textField.stringValue
        let family = textFont.titleOfSelectedItem ?? "Helvetica"
        let size = CGFloat(Double(textSize.stringValue) ?? Double(block.fontSize))
        block.fontSize = max(1, size)
        let traits: NSFontTraitMask = textBold.state == .on ? .boldFontMask : []
        block.fontName = NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: 12)?.fontName ?? family
        block.color = ImageEditUI.cgColor(textColor)
        block.hasShadow = textShadow.state == .on
        block.shadowColor = ImageEditUI.cgColor(shadowColor)
        block.shadowBlur = CGFloat(Double(shadowBlur.stringValue) ?? 0)
        block.shadowX = CGFloat(Double(shadowX.stringValue) ?? 0)
        block.shadowY = CGFloat(Double(shadowY.stringValue) ?? 0)
        overlay.textBlock = block
    }

    // MARK: Saving

    @objc func saveAsClicked() {
        applyTool()
        withSession { [weak self] _ in self?.askWhereToSave() }
    }

    private func askWhereToSave() {
        guard let window else { return }
        let formats: [(ImageFormat, String)] = [(.png, "PNG"), (.jpeg, "JPG"), (.webp, "WebP"), (.webpLossless, L10n.t("image.webpLossless"))]
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        formats.forEach { popup.addItem(withTitle: $0.1) }
        let quality = NSSlider(value: 90, minValue: 10, maxValue: 100, target: nil, action: nil)
        quality.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let row = NSStackView(views: [ImageEditUI.labeled(L10n.t("image.format"), popup), ImageEditUI.labeled(L10n.t("image.quality"), quality)])
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        row.frame = NSRect(origin: .zero, size: row.fittingSize)

        let panel = NSSavePanel()
        panel.accessoryView = row
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let stem = (items[index].name as NSString).deletingPathExtension
        let current = (items[index].name as NSString).pathExtension.lowercased()
        // A PDF page is usually kept as a JPG.
        let start = current == "pdf" ? 1 : formats.firstIndex { $0.0.fileExtension == current || (current == "jpeg" && $0.0 == .jpeg) } ?? 0
        popup.selectItem(at: start)
        func apply(_ position: Int) {
            let format = formats[position].0
            panel.nameFieldStringValue = ((panel.nameFieldStringValue.isEmpty ? stem : (panel.nameFieldStringValue as NSString).deletingPathExtension) as NSString).appendingPathExtension(format.fileExtension) ?? stem
            quality.isEnabled = format.usesQuality
        }
        panel.nameFieldStringValue = stem
        apply(start)
        let changer = BlockTarget { [weak popup] in
            if let popup { apply(popup.indexOfSelectedItem) }
        }
        popup.target = changer
        popup.action = #selector(BlockTarget.fire)
        if let folder = items[index].localFolder { panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true) }
        panel.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(changer) {}
            guard response == .OK, let url = panel.url, let self else { return }
            self.write(to: url, format: formats[popup.indexOfSelectedItem].0, quality: CGFloat(quality.doubleValue) / 100)
        }
    }

    @discardableResult
    func write(to url: URL, format: ImageFormat, quality: CGFloat) -> Bool {
        guard let session else { return false }
        do {
            guard let data = ImageOps.encode(session.current, as: format, quality: quality) else {
                showProblem(L10n.t("image.saveFailed", url.lastPathComponent))
                return false
            }
            try data.write(to: url, options: .atomic)
        } catch {
            showProblem(L10n.t("image.saveFailed", url.lastPathComponent) + "\n" + error.localizedDescription)
            return false
        }
        session.markSaved()
        cache.removeAllObjects()
        refreshEditState()
        onSaved?()
        return true
    }

    // MARK: PDF

    @objc func previousPageClicked() { goToPDFPage(pdfPage - 1) }
    @objc func nextPageClicked() { goToPDFPage(pdfPage + 1) }

    func goToPDFPage(_ page: Int) {
        guard page >= 0, page < pdfPageCount, page != pdfPage else { return }
        leaveEdits { [weak self] in
            guard let self else { return }
            self.pdfPage = page
            self.reshowCurrent()
        }
    }

    @objc func dpiChanged() {
        pdfDPI = CGFloat(Double(pdfDPIPopup.titleOfSelectedItem ?? "") ?? 200)
        // Not edited yet, so the next edit reads the page at the new resolution.
        if session != nil, !isDirty {
            session = nil
            reshowCurrent()
        }
    }

    /// Runs `then` once any unsaved edit is saved or given up.
    func leaveEdits(then: @escaping () -> Void) {
        guard isDirty else {
            then()
            return
        }
        askToDiscard { [weak self] fine in
            guard fine else { return }
            self?.session?.markSaved()
            then()
        }
    }
}

final class BlockTarget: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
