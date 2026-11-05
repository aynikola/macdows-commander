import XCTest
@testable import MacdowsCore

final class MarkdownTests: XCTestCase {
    private func html(_ text: String) -> String { Markdown.html(text) }

    func testHeadingsAndParagraphs() {
        XCTAssertEqual(html("# Bir\n\nyazı burada\nikinci satır"), "<h1>Bir</h1>\n<p>yazı burada\nikinci satır</p>\n")
        XCTAssertEqual(html("### Üç ###"), "<h3>Üç</h3>\n")
        XCTAssertEqual(html("Baslik\n===\n\nAlt\n---"), "<h1>Baslik</h1>\n<h2>Alt</h2>\n")
        XCTAssertEqual(html("#etiket"), "<p>#etiket</p>\n")
    }

    func testInlineFormats() {
        XCTAssertEqual(html("**k** *e* __k2__ _e2_ ~~s~~ `c`"), "<p><strong>k</strong> <em>e</em> <strong>k2</strong> <em>e2</em> <del>s</del> <code>c</code></p>\n")
        XCTAssertTrue(html("***ikisi***").contains("<strong>") && html("***ikisi***").contains("<em>"))
        XCTAssertEqual(html("dosya_adi_uzun"), "<p>dosya_adi_uzun</p>\n", "underscores inside a word stay")
        XCTAssertEqual(html("2 * 3 * 4"), "<p>2 * 3 * 4</p>\n")
        XCTAssertEqual(html("`**kalın değil** <b>`"), "<p><code>**kalın değil** &lt;b&gt;</code></p>\n")
        XCTAssertEqual(html("\\*yıldız\\*"), "<p>*yıldız*</p>\n")
    }

    func testTextIsEscapedAndHTMLTagsPass() {
        XCTAssertEqual(html("a < b & c"), "<p>a &lt; b &amp; c</p>\n")
        XCTAssertEqual(html("x <br> y"), "<p>x <br> y</p>\n")
    }

    func testLinksAndImages() {
        XCTAssertEqual(html("[a](http://x.com \"t\")"), "<p><a href=\"http://x.com\" title=\"t\">a</a></p>\n")
        XCTAssertEqual(html("[**k**](u.html)"), "<p><a href=\"u.html\"><strong>k</strong></a></p>\n")
        XCTAssertEqual(html("![r](a.png)"), "<p><img src=\"a.png\" alt=\"r\"></p>\n")
        XCTAssertEqual(html("bak https://a.com/b_c_d."), "<p>bak <a href=\"https://a.com/b_c_d\">https://a.com/b_c_d</a>.</p>\n")
        XCTAssertEqual(html("[x](javascript:alert(1))").contains("javascript:"), false)
    }

    func testCodeBlocksKeepTheirText() {
        XCTAssertEqual(html("```php\n<?php *a* ?>\n\n# no\n```"), "<pre><code class=\"language-php\">&lt;?php *a* ?&gt;\n\n# no\n</code></pre>\n")
        XCTAssertEqual(html("    girintili <kod>"), "<pre><code>girintili &lt;kod&gt;\n</code></pre>\n")
        XCTAssertEqual(html("```\nkapanmadı"), "<pre><code>kapanmadı\n</code></pre>\n")
    }

    func testLists() {
        XCTAssertEqual(html("- a\n- b"), "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n")
        XCTAssertEqual(html("1. a\n2. b"), "<ol>\n<li>a</li>\n<li>b</li>\n</ol>\n")
        XCTAssertEqual(html("3. a"), "<ol start=\"3\">\n<li>a</li>\n</ol>\n")
        XCTAssertEqual(html("- a\n  - iç\n- b"), "<ul>\n<li>a\n<ul>\n<li>iç</li>\n</ul></li>\n<li>b</li>\n</ul>\n")
        XCTAssertEqual(html("- a\n\n- b"), "<ul>\n<li><p>a</p></li>\n<li><p>b</p></li>\n</ul>\n")
        XCTAssertTrue(html("- [x] bitti\n- [ ] bekliyor").contains("<input type=\"checkbox\" disabled checked> bitti"))
        XCTAssertEqual(html("- a\n\nyazı"), "<ul>\n<li>a</li>\n</ul>\n<p>yazı</p>\n")
    }

    func testQuoteAndRule() {
        XCTAssertEqual(html("> a\n> b"), "<blockquote>\n<p>a\nb</p>\n</blockquote>\n")
        XCTAssertEqual(html("> # B"), "<blockquote>\n<h1>B</h1>\n</blockquote>\n")
        XCTAssertEqual(html("---"), "<hr>\n")
        XCTAssertEqual(html("***"), "<hr>\n")
    }

    func testTables() {
        let result = html("| A | B |\n|---|:-:|\n| 1 | `x|y` |\n| 2 | a\\|b |")
        XCTAssertTrue(result.contains("<th>A</th><th style=\"text-align:center\">B</th>"), result)
        XCTAssertTrue(result.contains("<td>1</td><td style=\"text-align:center\"><code>x|y</code></td>"), result)
        XCTAssertTrue(result.contains("a|b"), result)
        XCTAssertEqual(html("a | b"), "<p>a | b</p>\n")
    }

    func testWindowsLineEndingsAndPage() {
        XCTAssertEqual(html("# a\r\n\r\nb"), "<h1>a</h1>\n<p>b</p>\n")
        XCTAssertTrue(Markdown.page("# a").contains("theme-balmy"))
        XCTAssertEqual(html("hard  \nbreak"), "<p>hard<br>\nbreak</p>\n")
    }

    func testNewFileNames() {
        XCTAssertEqual(NewFileKind.md.fileName(typed: " notlar "), "notlar.md")
        XCTAssertEqual(NewFileKind.txt.fileName(typed: "a.php"), "a.php", "a typed extension wins")
        for bad in ["", " ", ".", "..", "a/b"] { XCTAssertNil(NewFileKind.txt.fileName(typed: bad), bad) }
        XCTAssertEqual(NewFileKind.txt.content(title: "x"), "")
        XCTAssertEqual(NewFileKind.md.content(title: "x"), "# x\n\n")
        XCTAssertTrue(NewFileKind.html.content(title: "a&b").contains("<title>a&amp;b</title>"))
    }
}

final class TransferRenameTests: XCTestCase {
    func testRenameChangesOnlyThatFilesDestination() {
        var plan = TransferPlan()
        plan.files = [TransferFile(relative: "a.txt", source: "/s/a.txt", destination: "/d/a.txt", size: 1), TransferFile(relative: "k/b.txt", source: "/s/k/b.txt", destination: "/d/k/b.txt", size: 1)]
        plan.rename(relative: "k/b.txt", to: "c.txt")
        XCTAssertEqual(plan.files[1].destination, "/d/k/c.txt")
        XCTAssertEqual(plan.files[1].relative, "k/b.txt", "the source is still found by it")
        XCTAssertEqual(plan.files[0].destination, "/d/a.txt")
    }

    func testFreeNameTakesTheFirstNumberFree() {
        XCTAssertEqual(TransferPlan.freeName(for: "a.txt", taken: ["a.txt"]), "a (2).txt")
        XCTAssertEqual(TransferPlan.freeName(for: "a.txt", taken: ["a.txt", "a (2).txt", "a (3).txt"]), "a (4).txt")
        XCTAssertEqual(TransferPlan.freeName(for: "README", taken: ["README"]), "README (2)")
        XCTAssertEqual(TransferPlan.freeName(for: "a.tar.gz", taken: []), "a.tar (2).gz")
    }
}

final class FrontMatterTests: XCTestCase {
    func testSplit() {
        XCTAssertEqual(Markdown.splitFrontMatter("---\na: 1\n---\n\n# b\n").front, "---\na: 1\n---\n\n")
        XCTAssertEqual(Markdown.splitFrontMatter("---\na: 1\n---\n\n# b\n").body, "# b\n")
        XCTAssertEqual(Markdown.splitFrontMatter("# b\n---\n").front, "")
        XCTAssertEqual(Markdown.splitFrontMatter("---\nkapanmadi").front, "")
    }
}

final class GoToPathTests: XCTestCase {
    func testPastedPathsAreCleaned() {
        let home = "/Users/x"
        XCTAssertEqual(GoToPath.clean(" /a/b/ \n", home: home), "/a/b")
        XCTAssertEqual(GoToPath.clean("\"/a b/c\"", home: home), "/a b/c")
        XCTAssertEqual(GoToPath.clean("'/a b'", home: home), "/a b")
        XCTAssertEqual(GoToPath.clean("/a\\ b/c", home: home), "/a b/c")
        XCTAssertEqual(GoToPath.clean("~/Belgeler", home: home), "/Users/x/Belgeler")
        XCTAssertEqual(GoToPath.clean("~", home: home), "/Users/x")
        XCTAssertEqual(GoToPath.clean("file:///a%20b/c", home: home), "/a b/c")
        XCTAssertEqual(GoToPath.clean("/", home: home), "/")
        XCTAssertEqual(GoToPath.clean("alt", home: home), "alt")
        XCTAssertNil(GoToPath.clean("   ", home: home))
    }
}

final class LineDiffTests: XCTestCase {
    private func rows(_ a: String, _ b: String, ignoringSpace: Bool = false) -> [DiffRow] {
        LineDiff.compare(LineDiff.lines(of: a), LineDiff.lines(of: b), ignoringSpace: ignoringSpace)
    }

    /// Both sides must come back whole and in order, whatever the path.
    private func assertComplete(_ a: [String], _ b: [String], file: StaticString = #filePath, line: UInt = #line) {
        let result = LineDiff.compare(a, b)
        XCTAssertEqual(result.compactMap(\.left), Array(a.indices), file: file, line: line)
        XCTAssertEqual(result.compactMap(\.right), Array(b.indices), file: file, line: line)
        for row in result where row.kind == .same {
            XCTAssertEqual(a[row.left!], b[row.right!], file: file, line: line)
        }
    }

    func testSameFilesHaveNoChanges() {
        XCTAssertEqual(rows("a\nb\n", "a\nb\n").map(\.kind), [.same, .same])
        XCTAssertTrue(LineDiff.changeStarts(rows("a\nb", "a\nb")).isEmpty)
        XCTAssertEqual(rows("", ""), [])
    }

    func testAddedRemovedChanged() {
        XCTAssertEqual(rows("a\nc", "a\nb\nc").map(\.kind), [.same, .added, .same])
        XCTAssertEqual(rows("a\nb\nc", "a\nc").map(\.kind), [.same, .removed, .same])
        XCTAssertEqual(rows("a\nb\nc", "a\nx\nc").map(\.kind), [.same, .changed, .same])
        XCTAssertEqual(rows("", "a").map(\.kind), [.added])
        XCTAssertEqual(rows("a", "").map(\.kind), [.removed])
        XCTAssertEqual(rows("a\nb\nc", "a\nx\ny\nz\nc").map(\.kind), [.same, .changed, .added, .added, .same])
    }

    func testChangesKeepEachSidesLineNumbers() {
        let result = rows("a\nb\nc", "z\na\nc")
        XCTAssertEqual(result.first?.kind, .added)
        XCTAssertEqual(result.last, DiffRow(kind: .same, left: 2, right: 2))
    }

    func testMovedAndRandomInputsStayComplete() {
        assertComplete(["a", "b", "c", "d"], ["d", "c", "b", "a"])
        assertComplete(["x"], ["y", "x", "y"])
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let a = (0..<Int.random(in: 0..<25, using: &generator)).map { _ in String(Int.random(in: 0..<5, using: &generator)) }
            let b = (0..<Int.random(in: 0..<25, using: &generator)).map { _ in String(Int.random(in: 0..<5, using: &generator)) }
            assertComplete(a, b)
        }
    }

    func testVeryDifferentFilesStillFinish() {
        let a = (0..<30000).map { "a\($0)" }, b = (0..<30000).map { "b\($0)" }
        assertComplete(a, b)
    }

    func testIgnoringSpace() {
        XCTAssertEqual(rows("a b\n  c", "ab\nc", ignoringSpace: true).map(\.kind), [.same, .same])
        XCTAssertEqual(rows("a b", "ab").map(\.kind), [.changed])
    }

    func testChangeStartsAndChangedPart() {
        XCTAssertEqual(LineDiff.changeStarts(rows("a\nb\nc\nd\ne", "a\nx\nc\ny\nz")), [1, 3])
        let parts = LineDiff.changedRanges("merhaba dünya", "merhaba güzel dünya")
        XCTAssertEqual(parts.left, NSRange(location: 8, length: 0))
        XCTAssertEqual(parts.right, NSRange(location: 8, length: 6))
        XCTAssertEqual(LineDiff.lines(of: "a\r\nb\r\n"), ["a", "b"])
        XCTAssertEqual(LineDiff.lines(of: "a\n\n"), ["a", ""])
    }
}
