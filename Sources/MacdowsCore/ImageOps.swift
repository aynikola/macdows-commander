import CoreGraphics
import CoreText
import Foundation
import ImageIO
import libwebp

public enum ImageFormat: String, CaseIterable {
    case png, jpeg, webp, webpLossless

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .webp, .webpLossless: return "webp"
        }
    }

    public var usesQuality: Bool { self == .jpeg || self == .webp }
}

/// Text on a picture. Positions and sizes are in the picture's pixels, measured from its top left.
public struct TextBlock {
    public var text: String
    public var fontName: String
    public var fontSize: CGFloat
    public var color: CGColor
    public var x: CGFloat
    public var y: CGFloat
    public var hasShadow = false
    public var shadowColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.8)
    public var shadowBlur: CGFloat = 8
    public var shadowX: CGFloat = 3
    public var shadowY: CGFloat = 3

    public init(text: String, fontName: String, fontSize: CGFloat, color: CGColor, x: CGFloat, y: CGFloat) {
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.x = x
        self.y = y
    }
}

/// Picture operations. Each returns a new image, or nil when the result would be too large to hold.
public enum ImageOps {
    public static let maxSide = 32767
    private static let maxPixels = 400_000_000

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func colorSpace(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput { return space }
        return sRGB
    }

    private static func context(width: Int, height: Int, space: CGColorSpace, opaque: Bool = false) -> CGContext? {
        guard width > 0, height > 0, width <= maxSide, height <= maxSide, width * height <= maxPixels else { return nil }
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .high
        return context
    }

    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    // MARK: Reading

    /// The full picture, turned the way its camera data says. PDFs give one page.
    public static func load(_ url: URL, pdfPage: Int = 0, dpi: CGFloat = 200) -> CGImage? {
        if url.pathExtension.lowercased() == "pdf" { return renderPDF(url, page: pdfPage, dpi: dpi) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Zero for a file that is not a PDF, is damaged or needs a password.
    public static func pdfPageCount(_ url: URL) -> Int {
        guard let document = CGPDFDocument(url as CFURL), document.isUnlocked else { return 0 }
        return document.numberOfPages
    }

    public static func renderPDF(_ url: URL, page index: Int, dpi: CGFloat, maxPixelSide: Int = 16000) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL), document.isUnlocked, let page = document.page(at: index + 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let sideways = abs(page.rotationAngle) % 180 == 90
        let points = CGSize(width: sideways ? box.height : box.width, height: sideways ? box.width : box.height)
        guard points.width > 0, points.height > 0 else { return nil }
        let scale = min(dpi / 72, CGFloat(maxPixelSide) / max(points.width, points.height))
        guard let context = context(width: Int((points.width * scale).rounded()), height: Int((points.height * scale).rounded()), space: sRGB, opaque: true) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: points), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    // MARK: Changing

    public static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = context(width: width, height: height, space: colorSpace(of: image)) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// `rect` is measured from the top left and is cut down to the picture.
    public static func cropped(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let area = rect.integral.intersection(bounds)
        guard !area.isEmpty else { return nil }
        return image.cropping(to: area)
    }

    /// Changes the canvas without scaling. `anchorX` and `anchorY` run from 0 (left, top) to 1 (right, bottom).
    public static func canvas(_ image: CGImage, width: Int, height: Int, anchorX: CGFloat, anchorY: CGFloat, fill: CGColor?) -> CGImage? {
        guard let context = context(width: width, height: height, space: colorSpace(of: image)) else { return nil }
        if let fill {
            context.setFillColor(fill)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let x = (CGFloat(width - image.width) * anchorX).rounded()
        let y = (CGFloat(height - image.height) * (1 - anchorY)).rounded()
        context.draw(image, in: CGRect(x: x, y: y, width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }

    /// Clockwise. The canvas grows to hold the corners; `fill` nil leaves them transparent.
    public static func rotated(_ image: CGImage, degrees: CGFloat, fill: CGColor? = nil) -> CGImage? {
        var turn = degrees.truncatingRemainder(dividingBy: 360)
        if turn < 0 { turn += 360 }
        let radians = turn * .pi / 180
        // Exact for quarter turns, where rounding must not add a row of pixels.
        var sine = abs(sin(radians)), cosine = abs(cos(radians))
        if turn.truncatingRemainder(dividingBy: 90) == 0 {
            sine = sine.rounded()
            cosine = cosine.rounded()
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let width = Int((w * cosine + h * sine).rounded(.up)), height = Int((w * sine + h * cosine).rounded(.up))
        guard let context = context(width: width, height: height, space: colorSpace(of: image)) else { return nil }
        if let fill {
            context.setFillColor(fill)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -radians)
        context.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return context.makeImage()
    }

    public static func flipped(_ image: CGImage, horizontally: Bool) -> CGImage? {
        guard let context = context(width: image.width, height: image.height, space: colorSpace(of: image)) else { return nil }
        if horizontally {
            context.translateBy(x: CGFloat(image.width), y: 0)
            context.scaleBy(x: -1, y: 1)
        } else {
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    // MARK: Text

    private static func lines(of block: TextBlock) -> (lines: [CTLine], ascent: CGFloat, lineHeight: CGFloat) {
        let font = CTFontCreateWithName(block.fontName as CFString, block.fontSize, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: block.color]
        let lines = block.text.split(separator: "\n", omittingEmptySubsequences: false).map { part in
            CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, String(part) as CFString, attributes as CFDictionary))
        }
        let ascent = CTFontGetAscent(font)
        return (lines, ascent, ascent + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    /// The area the text takes, measured from the top left of the picture.
    public static func bounds(of block: TextBlock) -> CGRect {
        let measured = lines(of: block)
        let width = measured.lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        return CGRect(x: block.x, y: block.y, width: width, height: measured.lineHeight * CGFloat(measured.lines.count))
    }

    /// Draws in a context whose y runs upward. Shadows ignore the context's scale, so `deviceScale` says what it is.
    public static func draw(_ block: TextBlock, in context: CGContext, canvasHeight: CGFloat, deviceScale: CGFloat = 1) {
        let measured = lines(of: block)
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        if block.hasShadow {
            context.setShadow(offset: CGSize(width: block.shadowX * deviceScale, height: -block.shadowY * deviceScale), blur: block.shadowBlur * deviceScale, color: block.shadowColor)
        }
        for (number, line) in measured.lines.enumerated() {
            context.textPosition = CGPoint(x: block.x, y: canvasHeight - block.y - measured.ascent - measured.lineHeight * CGFloat(number))
            CTLineDraw(line, context)
        }
    }

    public static func drawing(_ block: TextBlock, on image: CGImage) -> CGImage? {
        guard let context = context(width: image.width, height: image.height, space: colorSpace(of: image)) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        draw(block, in: context, canvasHeight: CGFloat(image.height))
        return context.makeImage()
    }

    // MARK: Writing

    /// `quality` runs from 0 to 1. JPEG has no transparency, so transparent areas turn white.
    public static func encode(_ image: CGImage, as format: ImageFormat, quality: CGFloat = 0.9) -> Data? {
        switch format {
        case .png: return imageIOData(image, type: "public.png", options: [:])
        case .jpeg:
            guard let context = context(width: image.width, height: image.height, space: sRGB, opaque: true) else { return nil }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flat = context.makeImage() else { return nil }
            return imageIOData(flat, type: "public.jpeg", options: [kCGImageDestinationLossyCompressionQuality: quality])
        case .webp: return webPData(image, quality: quality, lossless: false)
        case .webpLossless: return webPData(image, quality: 1, lossless: true)
        }
    }

    private static func imageIOData(_ image: CGImage, type: String, options: [CFString: Any]) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// macOS reads WebP but cannot write it, hence libwebp.
    private static func webPData(_ image: CGImage, quality: CGFloat, lossless: Bool) -> Data? {
        guard let context = context(width: image.width, height: image.height, space: sRGB), let base = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let stride = context.bytesPerRow
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        // libwebp wants plain colors, not ones already multiplied by their transparency.
        for y in 0..<image.height {
            let row = pixels + y * stride
            for x in 0..<image.width {
                let pixel = row + x * 4
                let alpha = Int(pixel[3])
                guard alpha != 0, alpha != 255 else { continue }
                for channel in 0..<3 { pixel[channel] = UInt8(min(255, Int(pixel[channel]) * 255 / alpha)) }
            }
        }
        var output: UnsafeMutablePointer<UInt8>?
        let size = lossless
            ? WebPEncodeLosslessRGBA(pixels, Int32(image.width), Int32(image.height), Int32(stride), &output)
            : WebPEncodeRGBA(pixels, Int32(image.width), Int32(image.height), Int32(stride), Float(max(0, min(1, quality)) * 100), &output)
        defer { if let output { WebPFree(output) } }
        guard size > 0, let output else { return nil }
        return Data(bytes: output, count: size)
    }
}

/// The picture being edited, with its undo steps.
public final class ImageEditHistory {
    public private(set) var current: CGImage
    private var undoSteps: [CGImage] = []
    private var redoSteps: [CGImage] = []
    private var revision = 0
    private var nextRevision = 1
    private var revisions: [Int] = []
    private var redoRevisions: [Int] = []
    private var savedRevision = 0
    /// Large photos add up fast, so the oldest steps go first.
    private let byteLimit: Int

    public init(image: CGImage, byteLimit: Int = 1 << 31) {
        current = image
        self.byteLimit = byteLimit
    }

    public var canUndo: Bool { !undoSteps.isEmpty }
    public var canRedo: Bool { !redoSteps.isEmpty }
    public var isDirty: Bool { revision != savedRevision }

    public func push(_ image: CGImage) {
        undoSteps.append(current)
        revisions.append(revision)
        current = image
        revision = nextRevision
        nextRevision += 1
        redoSteps = []
        redoRevisions = []
        var used = undoSteps.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        while used > byteLimit, undoSteps.count > 1 {
            used -= undoSteps[0].bytesPerRow * undoSteps[0].height
            undoSteps.removeFirst()
            revisions.removeFirst()
        }
    }

    public func undo() {
        guard let previous = undoSteps.popLast(), let previousRevision = revisions.popLast() else { return }
        redoSteps.append(current)
        redoRevisions.append(revision)
        current = previous
        revision = previousRevision
    }

    public func redo() {
        guard let next = redoSteps.popLast(), let nextOne = redoRevisions.popLast() else { return }
        undoSteps.append(current)
        revisions.append(revision)
        current = next
        revision = nextOne
    }

    public func markSaved() { savedRevision = revision }
}
