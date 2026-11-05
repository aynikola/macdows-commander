import AppKit
import ImageIO

/// One image in the viewer. `fetch` gives a local file: right away on disk, after a download on a server.
struct ViewerItem {
    let name: String
    let size: Int64
    let fetch: (@escaping (URL?) -> Void) -> Void
}

private enum ImageDecoder {
    /// Decoding at screen size instead of full size is what makes flipping through photos instant.
    static func decode(_ url: URL, maxPixels: Int) -> (image: NSImage, pixelSize: NSSize)? {
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

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
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

final class ImageViewerController: NSWindowController, NSWindowDelegate {
    private let items: [ViewerItem]
    private var index: Int
    private var zoom: CGFloat = 1
    private var generation = 0
    private let cache = NSCache<NSString, CachedImage>()
    private let decodeQueue = DispatchQueue(label: "macdows.viewer.decode", qos: .userInitiated, attributes: .concurrent)
    private let thumbQueue = DispatchQueue(label: "macdows.viewer.thumbs", qos: .utility, attributes: .concurrent)
    private let thumbSlots = DispatchSemaphore(value: 4)

    private let scroll = NSScrollView()
    private let imageView = NSImageView()
    private let thumbStack = NSStackView()
    private var thumbs: [ThumbView] = []
    private var maxPixels = 2560

    var onIndexChange: ((String) -> Void)?
    var onEdit: ((Int) -> Void)?
    var onClosed: (() -> Void)?

    private final class CachedImage {
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
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = ViewerWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] in self?.handleKey($0) ?? false }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        maxPixels = Int(max(frame.width, frame.height) * scale)
        cache.countLimit = 12
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

        content.addSubview(scroll)
        content.addSubview(strip)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: strip.topAnchor),
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            strip.heightAnchor.constraint(equalToConstant: items.count > 1 ? 84 : 0),
            thumbStack.topAnchor.constraint(equalTo: strip.contentView.topAnchor),
            thumbStack.leadingAnchor.constraint(equalTo: strip.contentView.leadingAnchor),
        ])
    }

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
            button.onClick = { [weak self] in self?.show(index: position) }
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

    private func show(index newIndex: Int) {
        index = max(0, min(items.count - 1, newIndex))
        zoom = 1
        generation += 1
        let current = generation
        let item = items[index]
        onIndexChange?(item.name)
        for (position, thumb) in thumbs.enumerated() {
            thumb.layer?.borderWidth = position == index ? 2 : 0
        }
        if !thumbs.isEmpty { thumbs[index].scrollToVisible(thumbs[index].bounds) }
        if let cached = cache.object(forKey: item.name as NSString) {
            present(cached, for: item)
        } else {
            window?.title = "\(item.name) — \(index + 1) / \(items.count)"
            load(position: index) { [weak self] cached in
                guard let self, current == self.generation else { return }
                if let cached { self.present(cached, for: item) } else { self.imageView.image = nil }
            }
        }
        // The next and previous images are ready before you press the key.
        for offset in [1, -1, 2] where items.indices.contains(index + offset) {
            load(position: index + offset, completion: nil)
        }
        loadThumbs(around: index)
    }

    private func load(position: Int, completion: ((CachedImage?) -> Void)?) {
        let item = items[position]
        if let cached = cache.object(forKey: item.name as NSString) {
            completion?(cached)
            return
        }
        item.fetch { [weak self] url in
            guard let self, let url else { completion?(nil); return }
            let maxPixels = self.maxPixels
            self.decodeQueue.async {
                let decoded = ImageDecoder.decode(url, maxPixels: maxPixels)
                DispatchQueue.main.async {
                    guard let decoded else { completion?(nil); return }
                    let cached = CachedImage(image: decoded.image, pixelSize: decoded.pixelSize)
                    self.cache.setObject(cached, forKey: item.name as NSString)
                    completion?(cached)
                }
            }
        }
    }

    private func present(_ cached: CachedImage, for item: ViewerItem) {
        imageView.image = cached.image
        layoutImage()
        updateTitle(item, pixelSize: cached.pixelSize)
    }

    private func updateTitle(_ item: ViewerItem, pixelSize: NSSize) {
        let zoomText = zoom == 1 ? L10n.t("viewer.fit") : "\(Int(zoom * 100))%"
        window?.title = "\(item.name) — \(index + 1) / \(items.count) — \(Int(pixelSize.width))×\(Int(pixelSize.height)) — \(Format.size(item.size)) — \(zoomText)"
    }

    private func layoutImage() {
        guard let image = imageView.image else { return }
        let available = scroll.contentSize
        guard image.size.width > 0, image.size.height > 0, available.width > 0 else { return }
        let fit = min(available.width / image.size.width, available.height / image.size.height)
        imageView.frame = NSRect(x: 0, y: 0, width: image.size.width * fit * zoom, height: image.size.height * fit * zoom)
    }

    private func setZoom(_ value: CGFloat) {
        zoom = max(0.5, min(8, value))
        layoutImage()
        let item = items[index]
        if let cached = cache.object(forKey: item.name as NSString) { updateTitle(item, pixelSize: cached.pixelSize) }
    }

    func windowDidResize(_ notification: Notification) { layoutImage() }

    func windowWillClose(_ notification: Notification) { onClosed?() }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53, 99: // Esc, F3
            close()
        case 118: // F4
            onEdit?(index)
        case 124, 125, 121, 49: // right, down, page down, space
            show(index: index + 1)
        case 123, 126, 116: // left, up, page up
            show(index: index - 1)
        case 115: show(index: 0)
        case 119: show(index: items.count - 1)
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=": setZoom(zoom * 1.25)
            case "-": setZoom(zoom / 1.25)
            case "0": setZoom(1)
            default: return false
            }
        }
        return true
    }
}

private final class ViewerTextView: NSTextView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

final class TextViewerController: NSWindowController, NSWindowDelegate {
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

    init(name: String, detail: String, text: String) {
        let frame = NSRect(x: 0, y: 0, width: 960, height: 720)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "\(name) — \(detail)"
        Theme.apply(to: window)
        super.init(window: window)
        window.delegate = self
        window.center()

        let scroll = ViewerTextView.scrollableTextView()
        // scrollableTextView gives a plain NSTextView, so build our own subclass inside it.
        let textView = ViewerTextView(frame: scroll.bounds)
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
        textView.onKey = { [weak self] event in
            switch event.keyCode {
            case 53, 99:
                self?.close()
                return true
            case 118:
                self?.onEdit?()
                return true
            default:
                return false
            }
        }
        scroll.documentView = textView
        window.contentView = scroll
        window.makeFirstResponder(textView)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    func windowWillClose(_ notification: Notification) { onClosed?() }
}
