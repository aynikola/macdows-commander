import XCTest
@testable import MacdowsCore

final class SearchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mc-search-test-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("alt/klasör")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("birinci satır\nikinci SATIR İstanbul burada\nson\n".utf8).write(to: root.appendingPathComponent("index.php"))
        try Data("<p>hello WORLD</p>".utf8).write(to: sub.appendingPathComponent("sayfa.html"))
        try Data("x".utf8).write(to: sub.appendingPathComponent("şablon.txt"))
        try Data("gizli istanbul".utf8).write(to: root.appendingPathComponent(".env"))
        try Data([0x69, 0x73, 0x74, 0x61, 0x6E, 0x00, 0x62, 0x75, 0x6C]).write(to: root.appendingPathComponent("ikili.dat"))
        // "şehir" in the old Turkish encoding
        try Data([0xFE, 0x65, 0x68, 0x69, 0x72]).write(to: sub.appendingPathComponent("eski.txt"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func search(_ options: SearchOptions, cancel: @escaping () -> Bool = { false }) -> (hits: [SearchHit], summary: SearchSummary) {
        var hits: [SearchHit] = []
        let summary = FileSearcher.run(source: LocalSource(), root: root.path, options: options, isCancelled: cancel) { hits.append($0) }
        return (hits, summary)
    }

    func testNamePatterns() {
        XCTAssertEqual(Set(search(SearchOptions(namePattern: "*.php;*.html")).hits.map(\.entry.name)), ["index.php", "sayfa.html"])
        XCTAssertEqual(search(SearchOptions(namePattern: "SAYFA")).hits.map(\.entry.name), ["sayfa.html"])
        XCTAssertTrue(search(SearchOptions(namePattern: "SAYFA", caseSensitive: true)).hits.isEmpty)
    }

    func testTurkishNameTypedWithDifferentUnicodeForm() {
        XCTAssertEqual(search(SearchOptions(namePattern: "ŞABLON".precomposedStringWithCanonicalMapping)).hits.count, 1)
        XCTAssertEqual(search(SearchOptions(namePattern: "şablon".decomposedStringWithCanonicalMapping)).hits.count, 1)
    }

    func testFoldersMatchByName() {
        XCTAssertTrue(search(SearchOptions(namePattern: "klasör")).hits.contains { $0.entry.isDirectory })
    }

    func testContentGivesLineAndText() throws {
        let hits = search(SearchOptions(namePattern: "*.php", content: "istanbul")).hits
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.line, 2)
        XCTAssertEqual(hit.snippet, "ikinci SATIR İstanbul burada")
    }

    func testContentCaseSensitive() {
        XCTAssertEqual(search(SearchOptions(content: "world")).hits.map(\.entry.name), ["sayfa.html"])
        XCTAssertTrue(search(SearchOptions(content: "world", caseSensitive: true)).hits.isEmpty)
    }

    func testOldTurkishEncodingIsFound() {
        XCTAssertEqual(search(SearchOptions(content: "şehir")).hits.map(\.entry.name), ["eski.txt"])
    }

    func testBinaryFilesAreSkippedAndCounted() {
        let result = search(SearchOptions(content: "bul"))
        XCTAssertFalse(result.hits.map(\.entry.name).contains("ikili.dat"))
        XCTAssertEqual(result.summary.skippedBinary, 1)
    }

    func testHiddenOption() {
        XCTAssertEqual(Set(search(SearchOptions(content: "istanbul")).hits.map(\.entry.name)), ["index.php", ".env"])
        XCTAssertEqual(search(SearchOptions(content: "istanbul", includeHidden: false)).hits.map(\.entry.name), ["index.php"])
    }

    func testSymlinkLoopEnds() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alt/geri"), withDestinationURL: root)
        XCTAssertEqual(search(SearchOptions(namePattern: "index.php")).hits.count, 1)
    }

    func testCancel() {
        let result = search(SearchOptions(), cancel: { true })
        XCTAssertTrue(result.summary.cancelled)
        XCTAssertTrue(result.hits.isEmpty)
    }

    func testMatcherAtEdgesOfData() {
        let matcher = ContentMatcher("abc", caseSensitive: true)
        XCTAssertEqual(matcher.firstMatch(in: Data("abc".utf8))?.line, 1)
        XCTAssertEqual(matcher.firstMatch(in: Data("\n\nxabc".utf8))?.line, 3)
        XCTAssertNil(matcher.firstMatch(in: Data("ab".utf8)))
        XCTAssertNil(matcher.firstMatch(in: Data()))
    }

    /// Searching inside an archive goes through the same path as a server.
    func testSearchInsideArchive() throws {
        let output = root.appendingPathComponent("p.tar.gz")
        try ArchiveCreator.create(format: .tarGz, names: ["index.php", "alt"], in: root.path, output: output, isCancelled: { false })
        var hits: [SearchHit] = []
        FileSearcher.run(source: ArchiveSource(file: output, kind: .tarLike), root: "/", options: SearchOptions(content: "world"), isCancelled: { false }) { hits.append($0) }
        XCTAssertEqual(hits.map(\.entry.name), ["sayfa.html"])
    }
}
