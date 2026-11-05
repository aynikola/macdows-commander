import XCTest
@testable import MacdowsCore

final class EditorCoreTests: XCTestCase {
    private func text(_ token: SyntaxToken, in source: String) -> String { (source as NSString).substring(with: token.range) }

    private func kinds(_ source: String, _ language: CodeLanguage) -> [(String, TokenKind)] {
        SyntaxHighlighter.analyze(source, language: language).tokens.map { (text($0, in: source), $0.kind) }
    }

    private func has(_ tokens: [(String, TokenKind)], _ word: String, _ kind: TokenKind) -> Bool {
        tokens.contains { $0.0 == word && $0.1 == kind }
    }

    func testJavaScriptColors() {
        let tokens = kinds("const a = /x\\/y/g; // note\nlet b = a / 2 / 3; run(`v${a + 1}w`, 'it\\'s');", .javascript)
        XCTAssertTrue(has(tokens, "const", .keyword))
        XCTAssertTrue(has(tokens, "/x\\/y/g", .regex))
        XCTAssertTrue(has(tokens, "// note", .comment))
        XCTAssertFalse(tokens.contains { $0.1 == .regex && $0.0.contains("2") }, "division is not a regex")
        XCTAssertTrue(has(tokens, "run", .function))
        XCTAssertTrue(has(tokens, "1", .number), "code inside a template is colored")
        XCTAssertTrue(has(tokens, "'it\\'s'", .string))
    }

    func testHTMLWithScriptAndStyle() {
        let source = "<!-- c --><div class=\"a\" hidden><script>var x = 1;</script><style>p { color: red; }</style></div>"
        let tokens = kinds(source, .html)
        XCTAssertTrue(has(tokens, "<!-- c -->", .comment))
        XCTAssertTrue(has(tokens, "<div", .tag))
        XCTAssertTrue(has(tokens, "class", .attribute))
        XCTAssertTrue(has(tokens, "\"a\"", .string))
        XCTAssertTrue(has(tokens, "var", .keyword))
        XCTAssertTrue(has(tokens, "color", .attribute))
        XCTAssertEqual(SyntaxHighlighter.analyze(source, language: .html).scripts.count, 1)
    }

    func testPHPInsideHTMLAttributeAndScript() {
        let source = "<a href=\"x<?= $url ?>y\">t</a><script>var a = <?php echo 1; ?>;</script><?php // done ?>\n<b>"
        let analysis = SyntaxHighlighter.analyze(source, language: .php)
        let tokens = analysis.tokens.map { (text($0, in: source), $0.kind) }
        XCTAssertTrue(has(tokens, "$url", .variable))
        XCTAssertTrue(has(tokens, "\"x", .string), "the attribute is split around the PHP")
        XCTAssertTrue(has(tokens, "y\"", .string))
        XCTAssertTrue(has(tokens, "echo", .keyword))
        XCTAssertTrue(has(tokens, "// done ", .comment), "?> ends a line comment")
        XCTAssertTrue(has(tokens, "<b", .tag), "HTML continues after PHP")
        XCTAssertEqual(analysis.scripts.first?.containsPHP, true)
        var end = 0
        for token in analysis.tokens {
            XCTAssertGreaterThanOrEqual(token.range.location, end, "tokens must not overlap")
            end = NSMaxRange(token.range)
        }
    }

    func testPHPHeredocAndInterpolation() {
        let source = "<?php\n$a = <<<EOT\nif while\nEOT;\n$b = \"hi $name\"; $c->list();"
        let tokens = kinds(source, .php)
        XCTAssertFalse(has(tokens, "while", .keyword), "heredoc text is not code")
        XCTAssertTrue(has(tokens, "$name", .variable))
        XCTAssertTrue(has(tokens, "list", .function), "a method named like a keyword")
        let lines = kinds("<?php\nfunction f($a) { return $a; }\nif ($a) {\n}\n", .php)
        XCTAssertTrue(has(lines, "function", .keyword), "\(lines)")
        XCTAssertTrue(has(lines, "if", .keyword), "\(lines)")
    }

    func testJavaScriptErrorsOnRightLine() {
        XCTAssertNil(SyntaxChecker.javaScriptIssue("const a = () => ({ b: 1 });\nclass X { #p = 1 }", startLine: 1, isModule: false))
        let issue = SyntaxChecker.javaScriptIssue("var a = 1;\nvar b = ;\n", startLine: 1, isModule: false)
        XCTAssertEqual(issue?.line, 2)
        XCTAssertEqual(SyntaxChecker.javaScriptIssue("\nif (", startLine: 10, isModule: false)?.line, 11)
    }

    func testJavaScriptModulesAreNotFalseAlarms() {
        let code = "import a, {\n  b } from './x.js';\nimport './y.js';\nexport const c = await a(import.meta.url);\nexport default function () {}\nexport { b };\n"
        XCTAssertNil(SyntaxChecker.javaScriptIssue(code, startLine: 1, isModule: false))
        let broken = "import a from './x.js';\n\nexport const c = ;\n"
        XCTAssertEqual(SyntaxChecker.javaScriptIssue(broken, startLine: 1, isModule: false)?.line, 3)
    }

    func testNothingIsExecutedByTheChecker() {
        XCTAssertNil(SyntaxChecker.javaScriptIssue("globalThis.ran = 1; throw new Error('ran');", startLine: 1, isModule: false))
    }

    func testPHPLint() throws {
        let php = try XCTUnwrap(SyntaxChecker.phpExecutable, "needs a PHP on this Mac")
        XCTAssertNil(SyntaxChecker.phpIssue("<?php\necho 1;\n", executable: php))
        let issue = SyntaxChecker.phpIssue("<?php\n$a = 1;\n$b = ;\n", executable: php)
        XCTAssertEqual(issue?.line, 3)
        XCTAssertFalse(issue?.message.contains("code.php") ?? true, "the temporary path stays out of the message")
    }

    func testHTMLAndPHPReports() {
        let html = SyntaxChecker.check("<p>\n</p>\n<script>\nvar a = ;\n</script>", language: .html, fileName: "a.html")
        XCTAssertEqual(html.issues.map(\.line), [4])
        let php = SyntaxChecker.check("<script>var a = <?php echo 1; ?>;</script>", language: .php, fileName: "a.php")
        XCTAssertEqual(php.issues, [])
        XCTAssertEqual(php.skippedScripts, 1)
        let data = SyntaxChecker.check("<script type=\"application/ld+json\">{ bad</script>", language: .html, fileName: "a.html")
        XCTAssertEqual(data.issues, [], "data blocks are not JavaScript")
        XCTAssertFalse(SyntaxChecker.check("x", language: .css, fileName: "a.css").didCheck)
    }

    func testDocumentRoundTrips() throws {
        let cases: [Data] = [
            Data("düz\nmetin".utf8),
            Data("a\r\nb\r\n".utf8),
            Data("a\r\nb\nc".utf8),
            Data([0xEF, 0xBB, 0xBF]) + Data("şöyle\n".utf8),
            Data([0x73, 0xFE, 0x0A, 0x93, 0x94]), // Windows-1254 with curly quotes.
            Data(),
        ]
        for data in cases {
            let document = try XCTUnwrap(EditorDocument.decode(data))
            XCTAssertEqual(document.encode(document.text), data)
        }
        XCTAssertEqual(EditorDocument.decode(Data("a\r\nb\r\n".utf8))?.text, "a\nb\n")
        XCTAssertEqual(EditorDocument.decode(Data("a\r\nb\r\n".utf8))?.encode("a\nb\nc\n"), Data("a\r\nb\r\nc\r\n".utf8))
        XCTAssertNil(EditorDocument.decode(Data([0x50, 0x00, 0x4B])), "binary")
        let turkish = try XCTUnwrap(EditorDocument.decode(Data([0xFE])))
        XCTAssertEqual(turkish.text, "ş")
        XCTAssertNil(turkish.encode("日本"), "must ask, never write question marks")
    }

    func testLineEdits() {
        func run(_ edit: (NSString, NSRange) -> TextChange, _ text: String, _ selection: NSRange) -> (String, NSRange) {
            let change = edit(text as NSString, selection)
            return ((text as NSString).replacingCharacters(in: change.range, with: change.replacement), change.selection)
        }
        var result = run(LineEdits.duplicate, "ab\ncd\n", NSRange(location: 1, length: 0))
        XCTAssertEqual(result.0, "ab\nab\ncd\n")
        XCTAssertEqual(result.1.location, 4)
        result = run(LineEdits.duplicate, "ab\ncd", NSRange(location: 4, length: 0))
        XCTAssertEqual(result.0, "ab\ncd\ncd")
        XCTAssertEqual(result.1.location, 7)
        result = run(LineEdits.duplicate, "ab\ncd\nef\n", NSRange(location: 0, length: 3))
        XCTAssertEqual(result.0, "ab\nab\ncd\nef\n", "a selection ending at a line start leaves that line out")
        result = run(LineEdits.delete, "ab\ncd\nef\n", NSRange(location: 4, length: 0))
        XCTAssertEqual(result.0, "ab\nef\n")
        XCTAssertEqual(result.1.location, 3)
        result = run(LineEdits.delete, "ab\ncd", NSRange(location: 4, length: 0))
        XCTAssertEqual(result.0, "ab")
        XCTAssertEqual(result.1.location, 0)
        result = run(LineEdits.delete, "ab\r\ncd", NSRange(location: 5, length: 0))
        XCTAssertEqual(result.0, "ab")
        result = run(LineEdits.delete, "only", NSRange(location: 2, length: 0))
        XCTAssertEqual(result.0, "")
    }

    func testFinding() {
        XCTAssertEqual(TextMatcher.find("ab", in: "ab AB aB", caseSensitive: false).count, 3)
        XCTAssertEqual(TextMatcher.find("ab", in: "ab AB aB", caseSensitive: true).count, 1)
        XCTAssertEqual(TextMatcher.find("istanbul", in: "İSTANBUL ıstanbul Istanbul", caseSensitive: false).count, 3)
        XCTAssertEqual(TextMatcher.find("ŞİFRE", in: "şifre", caseSensitive: false), [NSRange(location: 0, length: 5)])
        XCTAssertEqual(TextMatcher.find("aa", in: "aaaa", caseSensitive: true).count, 2)
        XCTAssertEqual(TextMatcher.find("", in: "a", caseSensitive: true), [])
    }
}
