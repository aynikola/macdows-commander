import XCTest
@testable import MacdowsCore

final class ListingParserTests: XCTestCase {
    private let now: Date = {
        var comps = DateComponents(year: 2026, month: 11, day: 4, hour: 12)
        comps.calendar = Calendar(identifier: .gregorian)
        return comps.date!
    }()

    func testUnixFileWithSpacesAndOwner() throws {
        let entry = try XCTUnwrap(ListingParser.parseLine("-rw-r--r--   1 www-data www-data     1234 Oct 14 08:19 my file.html", now: now))
        XCTAssertEqual(entry.name, "my file.html")
        XCTAssertEqual(entry.size, 1234)
        XCTAssertEqual(entry.owner, "www-data")
        XCTAssertEqual(entry.permissions, "-rw-r--r--")
        XCTAssertFalse(entry.isDirectory)
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour], from: try XCTUnwrap(entry.date))
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 10)
    }

    func testTimeInTheFutureMeansLastYear() throws {
        let entry = try XCTUnwrap(ListingParser.parseLine("-rw-r--r-- 1 a b 1 Dec 20 10:00 x", now: now))
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: try XCTUnwrap(entry.date)), 2025)
    }

    func testDirectorySymlinkAndHidden() throws {
        let listing = """
        total 8
        drwxr-xr-x 2 a b 4096 Jan  3  2024 css
        drwxr-xr-x 2 a b 4096 Jan  3  2024 .
        drwxr-xr-x 2 a b 4096 Jan  3  2024 ..
        lrwxrwxrwx 1 a b    9 Jan  3  2024 link -> /etc/hosts
        -rw------- 1 a b  512 Jan  3  2024 .htaccess
        """
        let entries = ListingParser.parse(listing, now: now)
        XCTAssertEqual(entries.map(\.name), ["css", "link", ".htaccess"])
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertTrue(entries[1].isSymlink)
        XCTAssertTrue(entries[2].isHidden)
    }

    func testMissingGroupColumn() throws {
        let entry = try XCTUnwrap(ListingParser.parseLine("-rw-r--r-- 1 owner 99 Jan  3  2024 a.txt", now: now))
        XCTAssertEqual(entry.name, "a.txt")
        XCTAssertEqual(entry.size, 99)
        XCTAssertEqual(entry.owner, "owner")
    }

    func testDOSListing() throws {
        let folder = try XCTUnwrap(ListingParser.parseLine("11-04-26  02:30PM       <DIR>          my folder", now: now))
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(folder.name, "my folder")
        let file = try XCTUnwrap(ListingParser.parseLine("11-04-26  02:30PM              1024 a.txt", now: now))
        XCTAssertEqual(file.size, 1024)
    }
}
