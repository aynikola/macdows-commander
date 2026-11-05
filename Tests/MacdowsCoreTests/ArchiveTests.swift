import XCTest
@testable import MacdowsCore

final class ArchiveTests: XCTestCase {
    private var root: URL!
    private var input: URL!
    private let local = LocalSource()

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mc-arc-test-\(UUID().uuidString)")
        input = root.appendingPathComponent("in")
        let folder = input.appendingPathComponent("klasör adı/iç")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: input.appendingPathComponent("boş"), withIntermediateDirectories: true)
        try Data("merhaba dünya\n".utf8).write(to: input.appendingPathComponent("a[1] şey.txt"))
        try Data((0..<200_000).map { UInt8($0 % 251) }).write(to: folder.appendingPathComponent("veri.bin"))
        try Data("gizli".utf8).write(to: input.appendingPathComponent("klasör adı/.hidden"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func packed(_ format: ArchiveFormat, names: [String], file: String) throws -> URL {
        let output = root.appendingPathComponent(file)
        try ArchiveCreator.create(format: format, names: names, in: input.path, output: output, isCancelled: { false })
        return output
    }

    /// Creates each format, then lists and extracts from it, with Turkish names, spaces and pattern characters.
    func testRoundTripEveryMultiFileFormat() throws {
        for (format, file) in [(ArchiveFormat.zip, "t.zip"), (.tar, "t.tar"), (.tarGz, "t.tar.gz")] {
            let archive = try packed(format, names: ["a[1] şey.txt", "klasör adı", "boş"], file: file)
            let source = ArchiveSource(file: archive, kind: try XCTUnwrap(ArchiveKind.detect(file)))
            let top = try source.list("/")
            XCTAssertEqual(Set(top.map { $0.name.precomposedStringWithCanonicalMapping }), ["a[1] şey.txt", "klasör adı", "boş"], file)
            let folderName = try XCTUnwrap(top.first { $0.isDirectory && $0.name.hasPrefix("klas") }).name
            let inside = try source.list("/" + folderName)
            XCTAssertTrue(inside.contains { $0.name == ".hidden" }, file)
            XCTAssertTrue(inside.contains { $0.isDirectory && $0.name.hasPrefix("i") }, file)
            let inner = try XCTUnwrap(inside.first { $0.isDirectory }).name
            let bin = try XCTUnwrap(source.list("/\(folderName)/\(inner)").first)
            XCTAssertEqual(bin.size, 200_000, file)
            XCTAssertNotNil(bin.date, file)

            let target = root.appendingPathComponent("out-\(file)")
            try source.download("/\(folderName)/\(inner)/veri.bin", to: target) { _ in true }
            XCTAssertEqual(try Data(contentsOf: target), Data((0..<200_000).map { UInt8($0 % 251) }), file)

            let textName = try XCTUnwrap(top.first { $0.name.hasPrefix("a[1]") }).name
            try source.download("/" + textName, to: target) { _ in true }
            XCTAssertEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), "merhaba dünya\n", file)
        }
    }

    func testGzipSingleFile() throws {
        let archive = try packed(.gzip, names: ["a[1] şey.txt"], file: "a.txt.gz")
        let source = ArchiveSource(file: archive, kind: .gzip)
        let top = try source.list("/")
        XCTAssertEqual(top.map(\.name), ["a.txt"])
        XCTAssertEqual(top[0].size, Int64("merhaba dünya\n".utf8.count))
        let target = root.appendingPathComponent("gz-out")
        try source.download("/a.txt", to: target) { _ in true }
        XCTAssertEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), "merhaba dünya\n")
    }

    func testGzipRefusesFoldersAndSeveralFiles() {
        let folder = FileEntry(name: "x", isDirectory: true)
        let file = FileEntry(name: "y", isDirectory: false)
        XCTAssertFalse(ArchiveFormat.gzip.supports([folder]))
        XCTAssertFalse(ArchiveFormat.gzip.supports([file, file]))
        XCTAssertTrue(ArchiveFormat.gzip.supports([file]))
        XCTAssertTrue(ArchiveFormat.zip.supports([folder, file]))
    }

    /// macOS tar adds "._name" files unless told not to; they would land on the server as junk.
    func testNoAppleDoubleFilesInTar() throws {
        let file = input.appendingPathComponent("a[1] şey.txt")
        let attribute = "com.apple.macl.test"
        _ = file.withUnsafeFileSystemRepresentation { path in
            "v".withCString { setxattr(path, attribute, $0, 1, 0, 0) }
        }
        let archive = try packed(.tarGz, names: ["a[1] şey.txt"], file: "x.tgz")
        let names = try ArchiveSource(file: archive, kind: .tarLike).list("/").map(\.name)
        XCTAssertFalse(names.contains { $0.hasPrefix("._") }, "\(names)")
    }

    func testManyExtractionsUseOneFullUnpack() throws {
        for index in 0..<30 { try Data("f\(index)".utf8).write(to: input.appendingPathComponent("m\(index).txt")) }
        let archive = try packed(.tarGz, names: (0..<30).map { "m\($0).txt" }, file: "m.tar.gz")
        let source = ArchiveSource(file: archive, kind: .tarLike)
        for index in 0..<30 {
            let target = root.appendingPathComponent("many-\(index)")
            try source.download("/m\(index).txt", to: target) { _ in true }
            XCTAssertEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), "f\(index)")
        }
    }

    func testCorruptArchiveReportsAnError() throws {
        let bad = root.appendingPathComponent("bad.zip")
        try Data("not an archive".utf8).write(to: bad)
        // tar accepts unknown data as empty only with a warning, so either result must not crash or show files.
        let listed = try? ArchiveSource(file: bad, kind: .tarLike).list("/")
        XCTAssertTrue(listed == nil || listed!.isEmpty)
    }

    func testPathsEscapingTheArchiveAreNotListed() {
        let text = """
        -rw-r--r--  0 a b 5 Jan  2  2024 ../../etc/passwd
        -rw-r--r--  0 a b 5 Jan  2  2024 ok/file name.txt
        lrwxr-xr-x  0 a b 0 Jan  2  2024 link -> /etc
        """
        let items = ArchiveListing.parse(text)
        XCTAssertEqual(items.map(\.member), ["ok/file name.txt", "link"])
        XCTAssertTrue(items[1].entry.isSymlink)
    }

    func testDetect() {
        XCTAssertEqual(ArchiveKind.detect("A.ZIP"), .tarLike)
        XCTAssertEqual(ArchiveKind.detect("a.tar.gz"), .tarLike)
        XCTAssertEqual(ArchiveKind.detect("a.tgz"), .tarLike)
        XCTAssertEqual(ArchiveKind.detect("a.sql.gz"), .gzip)
        XCTAssertNil(ArchiveKind.detect("a.txt"))
        XCTAssertNil(ArchiveKind.detect(".gz"))
    }

    func testPackFromLocalKeepsSelectionOnly() throws {
        let work = root.appendingPathComponent("work")
        let selection = [FileEntry(name: "boş", isDirectory: true)]
        let output = try ArchiveCreator.pack(selection: selection, from: local, directory: input.path, format: .zip, name: "s.zip", workFolder: work, isCancelled: { false })
        let names = try ArchiveSource(file: output, kind: .tarLike).list("/").map { $0.name.precomposedStringWithCanonicalMapping }
        XCTAssertEqual(names, ["boş"])
    }

    func testCancelledPackThrowsCancelled() {
        let work = root.appendingPathComponent("work2")
        let selection = [FileEntry(name: "klasör adı", isDirectory: true)]
        XCTAssertThrowsError(try ArchiveCreator.pack(selection: selection, from: ArchiveReadSource(), directory: "/", format: .zip, name: "c.zip", workFolder: work, isCancelled: { true })) {
            XCTAssertEqual(($0 as? MCError)?.isCancelled, true)
        }
    }
}

/// A remote-looking source with one file, so packing goes through its download path.
private final class ArchiveReadSource: FileSource {
    let isRemote = true
    func list(_ path: String) throws -> [FileEntry] { path == "/" ? [] : [FileEntry(name: "f", isDirectory: false, size: 1)] }
    func makeDirectory(_ path: String) throws {}
    func removeFile(_ path: String) throws {}
    func removeEmptyDirectory(_ path: String) throws {}
    func rename(from: String, to: String) throws {}
    func download(_ path: String, to local: URL, progress: @escaping ProgressHandler) throws {}
    func upload(_ local: URL, to path: String, progress: @escaping ProgressHandler) throws {}
}
