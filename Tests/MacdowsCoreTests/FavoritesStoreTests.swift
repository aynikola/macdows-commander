import XCTest
@testable import MacdowsCore

final class FavoritesStoreTests: XCTestCase {
    private let suite = "mc-favorites-tests"
    private var store: FavoritesStore!

    override func setUp() {
        UserDefaults().removePersistentDomain(forName: suite)
        store = FavoritesStore(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testAddKeepsOrderNamesAfterFolderAndSkipsDuplicates() {
        let site = UUID()
        store.add(path: "/Users/me/projects", siteID: nil)
        store.add(path: "/var/www", siteID: site)
        store.add(path: "/Users/me/projects", siteID: nil)
        XCTAssertEqual(store.load().map(\.name), ["projects", "www"])
    }

    func testSamePathOnAnotherServerIsADifferentFavorite() {
        store.add(path: "/var/www", siteID: UUID())
        store.add(path: "/var/www", siteID: UUID())
        store.add(path: "/var/www", siteID: nil)
        XCTAssertEqual(store.load().count, 3)
    }

    func testRootKeepsAName() {
        XCTAssertEqual(store.add(path: "/", siteID: nil).name, "/")
    }

    func testRemove() {
        let favorite = store.add(path: "/a", siteID: nil)
        store.add(path: "/b", siteID: nil)
        store.remove(id: favorite.id)
        XCTAssertEqual(store.load().map(\.path), ["/b"])
        XCTAssertNil(store.find(path: "/a", siteID: nil))
    }
}
