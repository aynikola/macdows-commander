import XCTest
@testable import MacdowsCore

final class RichDocumentTests: XCTestCase {
    func testBalmyFileKeepsEverythingAroundTheContent() {
        let html = "<html><head><title>x</title></head><body>\n<article class=\"theme-balmy\"><h1>A</h1><article>iç</article></article>\n<!-- son --></body></html>"
        let document = RichDocument.parse(html)
        XCTAssertEqual(document.content, "<h1>A</h1><article>iç</article>")
        XCTAssertEqual(document.assembled(content: document.content), html)
        XCTAssertTrue(document.assembled(content: "<p>B</p>").hasSuffix("</article>\n<!-- son --></body></html>"))
    }

    func testPastedTemplateWithoutClosingTagsIsCompleted() {
        let document = RichDocument.parse(RichDocument.balmyTemplate + "<p>metin</p>")
        XCTAssertEqual(document.content, "<p>metin</p>")
        XCTAssertTrue(document.assembled(content: "x").hasSuffix("</article>\n</body>\n</html>\n"))
    }

    func testOrdinaryPageEditsItsBody() {
        let html = "<!DOCTYPE html><html><head><style>p{}</style></head><BODY class=\"a\"><p>x</p></BODY></html>"
        let document = RichDocument.parse(html)
        XCTAssertEqual(document.content, "<p>x</p>")
        XCTAssertEqual(document.assembled(content: "<p>y</p>"), "<!DOCTYPE html><html><head><style>p{}</style></head><BODY class=\"a\"><p>y</p></BODY></html>")
    }

    func testFragmentSavesWithoutTheTemplate() {
        let document = RichDocument.parse("<p>x</p>")
        XCTAssertEqual(document.assembled(content: "<p>y</p>"), "<p>y</p>")
        XCTAssertTrue(document.display.contains("theme-balmy"))
    }

    func testBlankUsesTheTemplate() {
        let page = RichDocument.blank.assembled(content: "<p>x</p>")
        for piece in ["background: #fefcf3", ".rect-header.color-5", "<article class=\"theme-balmy\"><p>x</p>"] {
            XCTAssertTrue(page.contains(piece), piece)
        }
    }

    func testServerCodeIsNoticed() {
        XCTAssertTrue(RichDocument.containsServerCode("<p><?php echo 1; ?></p>"))
        XCTAssertTrue(RichDocument.containsServerCode("<?= $a ?>"))
        XCTAssertFalse(RichDocument.containsServerCode("<?xml version=\"1.0\"?><p>x</p>"))
        XCTAssertFalse(RichDocument.containsServerCode("<p>1 < 2</p>"))
    }
}
