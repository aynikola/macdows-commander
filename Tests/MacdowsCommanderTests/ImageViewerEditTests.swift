import AppKit
import ImageIO
import XCTest
import MacdowsCore
@testable import MacdowsCommander

final class ImageViewerEditTests: XCTestCase {
    private var folder: URL!
    private var viewers: [ImageViewerController] = []

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: "/tmp/mcimg-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        viewers.forEach { $0.markClean(); $0.window?.close() }
        viewers = []
        try FileManager.default.removeItem(at: folder)
    }

    private func spin(_ what: String, timeout: TimeInterval = 10, until: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if until() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out: \(what)")
    }

    private func picture(_ name: String, width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = folder.appendingPathComponent(name)
        try XCTUnwrap(ImageOps.encode(context.makeImage()!, as: .png)).write(to: url)
        return url
    }

    private func viewer(_ urls: [URL]) -> ImageViewerController {
        let items = urls.map { url in ViewerItem(name: url.lastPathComponent, size: 1, localFolder: url.deletingLastPathComponent().path) { $0(url) } }
        let viewer = ImageViewerController(items: items, start: 0)
        viewers.append(viewer)
        viewer.window?.orderBack(nil)
        spin("image shown") { viewer.imageView.image != nil }
        return viewer
    }

    private func edited(_ viewer: ImageViewerController) {
        var ready = false
        viewer.withSession { _ in ready = true }
        spin("full picture") { ready }
    }

    func testHTMLAndMarkdownOfferAPageViewAndOthersDoNot() throws {
        XCTAssertNotNil(TextViewerController.pageHTML(fileName: "a.HTML", text: "<p>x</p>"))
        XCTAssertTrue(TextViewerController.pageHTML(fileName: "a.md", text: "# x")?.contains("<h1>x</h1>") ?? false)
        XCTAssertNil(TextViewerController.pageHTML(fileName: "a.txt", text: "x"))
        XCTAssertNil(TextViewerController.pageHTML(fileName: "a.php", text: "x"))
        UserDefaults.standard.removeObject(forKey: "viewer.showsPage")
        let page = TextViewerController.PageView(html: "<p>x</p>", folder: folder.path, source: nil, queue: DispatchQueue(label: "t"))
        let viewer = TextViewerController(name: "a.md", detail: "", text: "# x", pageView: page)
        XCTAssertTrue(viewer.isShowingPage, "a page first")
        viewer.show(page: false)
        XCTAssertFalse(viewer.isShowingPage)
        viewer.show(page: true)
        XCTAssertTrue(viewer.isShowingPage)
        viewer.close()
    }

    func testASmallPictureIsNotBlownUp() throws {
        let viewer = viewer([try picture("small.png", width: 200, height: 120)])
        XCTAssertEqual(viewer.imageView.frame.size, NSSize(width: 200, height: 120))
    }

    func testALargePictureShrinksToFitWithItsShapeKept() throws {
        let viewer = viewer([try picture("big.png", width: 6000, height: 3000)])
        let frame = viewer.imageView.frame.size
        XCTAssertLessThan(frame.width, 6000)
        XCTAssertEqual(frame.width / frame.height, 2, accuracy: 0.01)
        XCTAssertEqual(viewer.displayPixels, NSSize(width: 6000, height: 3000))
    }

    func testEditsChangeThePictureAndCanBeUndone() throws {
        let viewer = viewer([try picture("a.png", width: 300, height: 200)])
        edited(viewer)
        XCTAssertFalse(viewer.isDirty)
        viewer.rotateRightClicked()
        XCTAssertEqual(viewer.session?.current.width, 200)
        XCTAssertEqual(viewer.imageView.frame.size, NSSize(width: 200, height: 300))
        XCTAssertTrue(viewer.isDirty)
        XCTAssertTrue(viewer.window?.isDocumentEdited ?? false)
        XCTAssertTrue(viewer.undoButton.isEnabled)
        viewer.undoClicked()
        XCTAssertEqual(viewer.session?.current.width, 300)
        XCTAssertFalse(viewer.isDirty)
        viewer.redoClicked()
        XCTAssertEqual(viewer.session?.current.width, 200)
    }

    func testCropUsesTheRectangleOnThePicture() throws {
        let viewer = viewer([try picture("a.png", width: 300, height: 200)])
        viewer.cropClicked()
        spin("crop tool") { viewer.overlay.mode == .crop }
        XCTAssertFalse(viewer.cropBar.isHidden)
        viewer.overlay.cropRect = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(viewer.cropLabel.stringValue, "100 × 50")
        viewer.applyTool()
        XCTAssertEqual(viewer.overlay.mode, .off)
        XCTAssertTrue(viewer.cropBar.isHidden)
        XCTAssertEqual(viewer.session?.current.width, 100)
        XCTAssertEqual(viewer.session?.current.height, 50)
    }

    func testTextGoesOnThePictureOnlyWhenApplied() throws {
        let viewer = viewer([try picture("a.png", width: 300, height: 200)])
        viewer.textClicked()
        spin("text tool") { viewer.overlay.mode == .text }
        viewer.textField.stringValue = "Merhaba"
        viewer.textChanged()
        XCTAssertEqual(viewer.overlay.textBlock?.text, "Merhaba")
        XCTAssertEqual(viewer.overlay.textBlock?.hasShadow, true)
        XCTAssertFalse(viewer.isDirty, "a preview changes nothing")
        viewer.applyTool()
        XCTAssertTrue(viewer.isDirty)
        XCTAssertNil(viewer.overlay.textBlock)
    }

    func testCancellingAToolChangesNothing() throws {
        let viewer = viewer([try picture("a.png", width: 300, height: 200)])
        viewer.cropClicked()
        spin("crop tool") { viewer.overlay.mode == .crop }
        viewer.cancelTool()
        XCTAssertEqual(viewer.session?.current.width, 300)
        XCTAssertFalse(viewer.isDirty)
    }

    func testSavingWritesTheFormatAndLeavesTheOriginalAlone() throws {
        let source = try picture("a.png", width: 300, height: 200)
        let before = try Data(contentsOf: source)
        let viewer = viewer([source])
        var saved = 0
        viewer.onSaved = { saved += 1 }
        edited(viewer)
        viewer.rotateLeftClicked()
        for (format, name, magic) in [(ImageFormat.jpeg, "b.jpg", [UInt8(0xFF), 0xD8]), (.png, "b.png", [0x89, 0x50]), (.webp, "b.webp", [0x52, 0x49])] {
            let url = folder.appendingPathComponent(name)
            XCTAssertTrue(viewer.write(to: url, format: format, quality: 0.8))
            XCTAssertEqual(Array(try Data(contentsOf: url).prefix(2)), magic, name)
            let image = try XCTUnwrap(ImageOps.load(url))
            XCTAssertEqual(image.width, 200, name)
        }
        XCTAssertEqual(saved, 3)
        XCTAssertFalse(viewer.isDirty)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testAPDFOpensAndItsPagesTurn() throws {
        let url = folder.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 100, height: 200)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage()
        context.beginPDFPage(nil); context.endPDFPage()
        context.closePDF()
        let viewer = viewer([url])
        spin("pages counted") { viewer.pdfPageCount == 2 }
        viewer.nextPageClicked()
        XCTAssertEqual(viewer.pdfPage, 1)
        spin("page shown") { viewer.imageView.image != nil }
        edited(viewer)
        XCTAssertEqual(viewer.session?.current.width, Int((100.0 * 200 / 72).rounded()), "editing reads the page at 200 DPI")
        let out = folder.appendingPathComponent("doc.jpg")
        XCTAssertTrue(viewer.write(to: out, format: .jpeg, quality: 0.9))
        XCTAssertEqual(Array(try Data(contentsOf: out).prefix(2)), [0xFF, 0xD8])
    }

    func testUnsavedEditsStopTheWindowClosing() throws {
        let viewer = viewer([try picture("a.png", width: 30, height: 20)])
        edited(viewer)
        XCTAssertTrue(viewer.windowShouldClose(viewer.window!))
        viewer.rotateLeftClicked()
        XCTAssertFalse(viewer.windowShouldClose(viewer.window!))
        viewer.window?.attachedSheet.map { viewer.window?.endSheet($0) }
    }

    func testMovingOverlayTextOnScreenIsInPicturePixels() throws {
        let viewer = viewer([try picture("a.png", width: 400, height: 200)])
        viewer.textClicked()
        spin("text tool") { viewer.overlay.mode == .text }
        XCTAssertEqual(viewer.overlay.pixelSize, NSSize(width: 400, height: 200))
        XCTAssertEqual(viewer.overlay.frame.size, viewer.imageView.bounds.size)
    }
}
