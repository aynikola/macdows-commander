import CoreGraphics
import ImageIO
import XCTest
@testable import MacdowsCore

final class ImageOpsTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Four colored quarters, from the top left clockwise: red, green, blue, white.
    private func quarters(width: Int = 40, height: Int = 20, alpha: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        fill(1, 0, 0, 0, h)
        fill(0, 1, 0, w, h)
        fill(0, 0, 1, w, 0)
        fill(1, 1, 1, 0, 0)
        return context.makeImage()!
    }

    /// Red, green, blue and alpha of one pixel, counted from the top left.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return bytes.map(Int.init)
    }

    private func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func testResize() throws {
        let result = try XCTUnwrap(ImageOps.resized(quarters(), width: 200, height: 50))
        XCTAssertEqual([result.width, result.height], [200, 50])
        XCTAssertEqual(pixel(result, 10, 5), [255, 0, 0, 255])
        XCTAssertEqual(pixel(result, 190, 45), [0, 0, 255, 255])
    }

    func testTooLargeResultIsRefused() {
        XCTAssertNil(ImageOps.resized(quarters(), width: 40000, height: 10))
        XCTAssertNil(ImageOps.resized(quarters(), width: 30000, height: 30000))
        XCTAssertNil(ImageOps.resized(quarters(), width: 0, height: 10))
    }

    func testCropMeasuresFromTheTopLeftAndStaysInside() throws {
        let result = try XCTUnwrap(ImageOps.cropped(quarters(), to: CGRect(x: 20, y: 0, width: 20, height: 10)))
        XCTAssertEqual([result.width, result.height], [20, 10])
        XCTAssertEqual(pixel(result, 5, 5), [0, 255, 0, 255])
        let cut = try XCTUnwrap(ImageOps.cropped(quarters(), to: CGRect(x: 30, y: 15, width: 100, height: 100)))
        XCTAssertEqual([cut.width, cut.height], [10, 5])
        XCTAssertNil(ImageOps.cropped(quarters(), to: CGRect(x: 100, y: 100, width: 5, height: 5)))
    }

    func testCanvasKeepsThePictureWhereTheAnchorSays() throws {
        let topLeft = try XCTUnwrap(ImageOps.canvas(quarters(), width: 60, height: 40, anchorX: 0, anchorY: 0, fill: nil))
        XCTAssertEqual([topLeft.width, topLeft.height], [60, 40])
        XCTAssertEqual(pixel(topLeft, 5, 5), [255, 0, 0, 255])
        XCTAssertEqual(pixel(topLeft, 50, 30)[3], 0, "the new area is transparent")

        let center = try XCTUnwrap(ImageOps.canvas(quarters(), width: 60, height: 40, anchorX: 0.5, anchorY: 0.5, fill: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)))
        XCTAssertEqual(pixel(center, 2, 2), [0, 0, 0, 255])
        XCTAssertEqual(pixel(center, 15, 15), [255, 0, 0, 255])

        let smaller = try XCTUnwrap(ImageOps.canvas(quarters(), width: 20, height: 10, anchorX: 1, anchorY: 1, fill: nil))
        XCTAssertEqual(pixel(smaller, 5, 5), [0, 0, 255, 255], "bottom right part stays")
    }

    func testQuarterTurnsAreExact() throws {
        let right = try XCTUnwrap(ImageOps.rotated(quarters(), degrees: 90))
        XCTAssertEqual([right.width, right.height], [20, 40])
        XCTAssertEqual(pixel(right, 15, 5), [255, 0, 0, 255], "the top left goes to the top right")
        let left = try XCTUnwrap(ImageOps.rotated(quarters(), degrees: -90))
        XCTAssertEqual([left.width, left.height], [20, 40])
        XCTAssertEqual(pixel(left, 5, 35), [255, 0, 0, 255], "the top left goes to the bottom left")
        let half = try XCTUnwrap(ImageOps.rotated(quarters(), degrees: 180))
        XCTAssertEqual([half.width, half.height], [40, 20])
        XCTAssertEqual(pixel(half, 35, 15), [255, 0, 0, 255])
    }

    func testFreeAngleGrowsTheCanvasWithTransparentCorners() throws {
        let result = try XCTUnwrap(ImageOps.rotated(quarters(width: 40, height: 40), degrees: 45))
        XCTAssertEqual(result.width, 57)
        XCTAssertEqual(result.height, 57)
        XCTAssertEqual(pixel(result, 1, 1)[3], 0)
        XCTAssertEqual(pixel(result, 28, 28)[3], 255)
    }

    func testFlip() throws {
        let horizontal = try XCTUnwrap(ImageOps.flipped(quarters(), horizontally: true))
        XCTAssertEqual(pixel(horizontal, 35, 5), [255, 0, 0, 255])
        let vertical = try XCTUnwrap(ImageOps.flipped(quarters(), horizontally: false))
        XCTAssertEqual(pixel(vertical, 5, 15), [255, 0, 0, 255])
    }

    private func blackPicture() -> CGImage {
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        return context.makeImage()!
    }

    private func count(_ image: CGImage, where test: ([Int]) -> Bool) -> Int {
        var total = 0
        for y in 0..<image.height { for x in 0..<image.width where test(pixel(image, x, y)) { total += 1 } }
        return total
    }

    func testTextHasItsColorAndIsAtTheTopLeftPosition() throws {
        let block = TextBlock(text: "Merhaba", fontName: "Helvetica-Bold", fontSize: 30, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), x: 10, y: 5)
        let result = try XCTUnwrap(ImageOps.drawing(block, on: blackPicture()))
        XCTAssertGreaterThan(count(result) { $0[0] > 200 && $0[2] < 60 }, 100)
        let bounds = ImageOps.bounds(of: block)
        for y in stride(from: Int(bounds.maxY) + 2, to: 100, by: 1) {
            for x in stride(from: 0, to: 200, by: 4) { XCTAssertEqual(pixel(result, x, y), [0, 0, 255, 255]) }
        }
    }

    func testShadowFallsDownAndRight() throws {
        var block = TextBlock(text: "I", fontName: "Helvetica-Bold", fontSize: 60, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), x: 50, y: 10)
        let plain = try XCTUnwrap(ImageOps.drawing(block, on: blackPicture()))
        block.hasShadow = true
        block.shadowColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        block.shadowBlur = 0
        block.shadowX = 6
        block.shadowY = 6
        let shadowed = try XCTUnwrap(ImageOps.drawing(block, on: blackPicture()))
        let dark: ([Int]) -> Bool = { $0[2] < 40 }
        XCTAssertEqual(count(plain, where: dark), 0)
        XCTAssertGreaterThan(count(shadowed, where: dark), 20)
        let darkBelow = (0..<200).contains { x in (0..<100).contains { y in dark(pixel(shadowed, x, y)) && pixel(plain, x, y)[0] < 50 && y > 40 } }
        XCTAssertTrue(darkBelow)
    }

    func testMoreThanOneLineTakesMoreRoom() {
        let one = TextBlock(text: "a", fontName: "Helvetica", fontSize: 20, color: CGColor(gray: 1, alpha: 1), x: 0, y: 0)
        var two = one
        two.text = "a\nb"
        XCTAssertEqual(ImageOps.bounds(of: two).height, ImageOps.bounds(of: one).height * 2, accuracy: 0.01)
    }

    func testPNGKeepsPixelsAndTransparency() throws {
        let source = try XCTUnwrap(ImageOps.canvas(quarters(), width: 60, height: 20, anchorX: 0, anchorY: 0, fill: nil))
        let image = try XCTUnwrap(decode(XCTUnwrap(ImageOps.encode(source, as: .png))))
        XCTAssertEqual(pixel(image, 5, 5), [255, 0, 0, 255])
        XCTAssertEqual(pixel(image, 50, 5)[3], 0)
    }

    func testJPEGTurnsTransparencyWhite() throws {
        let source = try XCTUnwrap(ImageOps.canvas(quarters(), width: 80, height: 40, anchorX: 0, anchorY: 0, fill: nil))
        let data = try XCTUnwrap(ImageOps.encode(source, as: .jpeg, quality: 0.95))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        let image = try XCTUnwrap(decode(data))
        XCTAssertGreaterThan(pixel(image, 70, 30)[0], 250)
        XCTAssertGreaterThan(pixel(image, 5, 5)[0], 230)
        XCTAssertLessThan(pixel(image, 5, 5)[1], 40)
    }

    func testWebPLossyAndLosslessAreRealWebPFiles() throws {
        let source = quarters(width: 64, height: 64, alpha: true)
        for format in [ImageFormat.webp, .webpLossless] {
            let data = try XCTUnwrap(ImageOps.encode(source, as: format, quality: 0.9))
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WEBP")
            let image = try XCTUnwrap(decode(data), "macOS reads it back")
            XCTAssertEqual([image.width, image.height], [64, 64])
            XCTAssertGreaterThan(pixel(image, 8, 8)[0], 230)
        }
        let exact = try XCTUnwrap(decode(XCTUnwrap(ImageOps.encode(source, as: .webpLossless))))
        XCTAssertEqual(pixel(exact, 50, 50), [0, 0, 255, 255])
    }

    func testWebPKeepsPartialTransparency() throws {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(decode(XCTUnwrap(ImageOps.encode(context.makeImage()!, as: .webpLossless))))
        let value = pixel(image, 4, 4)
        XCTAssertEqual(value[3], 128, accuracy: 2)
        XCTAssertEqual(value[0], 128, accuracy: 3, "premultiplied by the test's reader")
        XCTAssertEqual(value[1], 0)
    }

    private func makePDF(pages: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(page == 0 ? CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1) : CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
            context.endPDFPage()
        }
        context.closePDF()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPDFOpensAtTheAskedResolutionWithAWhitePage() throws {
        let url = try makePDF(pages: 2)
        XCTAssertEqual(ImageOps.pdfPageCount(url), 2)
        let first = try XCTUnwrap(ImageOps.load(url, pdfPage: 0, dpi: 144))
        XCTAssertEqual([first.width, first.height], [400, 200])
        XCTAssertGreaterThan(pixel(first, 50, 50)[0], 240)
        XCTAssertLessThan(pixel(first, 50, 50)[2], 40)
        XCTAssertEqual(pixel(first, 300, 150), [255, 255, 255, 255])
        let second = try XCTUnwrap(ImageOps.load(url, pdfPage: 1, dpi: 72))
        XCTAssertEqual([second.width, second.height], [200, 100])
        XCTAssertGreaterThan(pixel(second, 25, 25)[2], 240)
        XCTAssertNil(ImageOps.load(url, pdfPage: 5, dpi: 72))
    }

    func testPDFSavesAsJPEG() throws {
        let page = try XCTUnwrap(ImageOps.load(try makePDF(pages: 1), dpi: 200))
        let data = try XCTUnwrap(ImageOps.encode(page, as: .jpeg))
        let back = try XCTUnwrap(decode(data))
        XCTAssertEqual(back.width, page.width)
    }

    func testHistoryKnowsWhatIsSaved() {
        let history = ImageEditHistory(image: quarters())
        XCTAssertFalse(history.isDirty)
        history.push(quarters(width: 10, height: 10))
        XCTAssertTrue(history.isDirty)
        XCTAssertEqual(history.current.width, 10)
        history.undo()
        XCTAssertFalse(history.isDirty, "back at what the file holds")
        XCTAssertEqual(history.current.width, 40)
        history.redo()
        XCTAssertEqual(history.current.width, 10)
        history.markSaved()
        XCTAssertFalse(history.isDirty)
        history.undo()
        XCTAssertTrue(history.isDirty, "the saved file now differs from this")
        history.redo()
        XCTAssertFalse(history.isDirty)
        history.undo()
        history.push(quarters(width: 12, height: 12))
        XCTAssertFalse(history.canRedo)
    }

    func testHistoryDropsOldStepsAtItsLimit() {
        let history = ImageEditHistory(image: quarters(), byteLimit: 1)
        history.push(quarters())
        history.push(quarters())
        history.undo()
        XCTAssertFalse(history.canUndo, "only one step is kept")
    }
}
