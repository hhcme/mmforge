import XCTest
@testable import MMForge

@MainActor
final class RecentDocumentStoreTests: XCTestCase {
    private var store: RecentDocumentStore!
    private var suite: UserDefaults!
    private var suiteID: String!
    private var reachable: Set<URL> = []

    override func setUp() {
        super.setUp()
        suiteID = "com.mmforge.tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteID)
        suite.removePersistentDomain(forName: suiteID)
        reachable = []
        store = RecentDocumentStore(
            userDefaults: suite,
            reachability: { [weak self] url in
                self?.reachable.contains(url) ?? false
            },
            systemMenu: NoOpSystemMenu()
        )
    }

    override func tearDown() {
        store.clear()
        suite.removePersistentDomain(forName: suiteID)
        super.tearDown()
    }

    private func makeURL(_ name: String) -> URL {
        let url = URL(fileURLWithPath: "/tmp/mmforge_test_\(name)")
        reachable.insert(url)
        return url
    }

    // MARK: - Basic

    func testAddSingleURL() {
        let url = makeURL("test1")
        store.add(url: url)
        XCTAssertEqual(store.urls.first, url)
        XCTAssertEqual(store.urls.count, 1)
    }

    func testAddRejectsUnreachableURL() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent_xyz")
        store.add(url: url)
        XCTAssertTrue(store.urls.isEmpty)
    }

    func testDeduplicationMovesToFront() {
        let urlA = makeURL("a")
        let urlB = makeURL("b")
        store.add(url: urlA)
        store.add(url: urlB)
        store.add(url: urlA)
        XCTAssertEqual(store.urls.first, urlA)
        XCTAssertEqual(store.urls.count, 2)
    }

    func testMaxEntriesEnforced() {
        for i in 0..<15 {
            store.add(url: makeURL("file_\(i)"))
        }
        XCTAssertLessThanOrEqual(store.urls.count, 10)
    }

    func testClearRemovesAll() {
        store.add(url: makeURL("clear_test"))
        XCTAssertFalse(store.urls.isEmpty)
        store.clear()
        XCTAssertTrue(store.urls.isEmpty)
    }

    func testRemoveSingleURL() {
        let keep = makeURL("keep")
        let remove = makeURL("remove")
        store.add(url: keep)
        store.add(url: remove)
        store.remove(url: remove)
        XCTAssertEqual(store.urls.count, 1)
        XCTAssertEqual(store.urls.first, keep)
    }

    // MARK: - Stale cleanup

    func testStaleURLsCleanedOnAdd() {
        let real = makeURL("real")
        store.add(url: real)
        XCTAssertEqual(store.urls.count, 1)

        reachable.remove(real)
        let real2 = makeURL("real2")
        store.add(url: real2)
        XCTAssertEqual(store.urls.count, 1)
        XCTAssertEqual(store.urls.first, real2)
    }

    func testStaleURLsFilteredOnRead() {
        let real = makeURL("real")
        let stale = makeURL("stale")
        store.add(url: real)
        store.add(url: stale)
        XCTAssertEqual(store.urls.count, 2)

        reachable.remove(stale)
        let filtered = store.recentURLs()
        XCTAssertEqual(filtered.count, 1)
        XCTAssertTrue(filtered.contains(real))
        XCTAssertFalse(filtered.contains(stale))
    }

    // MARK: - Restart persistence

    func testRestartPersistence() {
        let urlA = makeURL("persist_a")
        let urlB = makeURL("persist_b")
        store.add(url: urlA)
        store.add(url: urlB)
        XCTAssertEqual(store.urls.count, 2)

        let storeB = RecentDocumentStore(
            userDefaults: suite,
            reachability: { [weak self] url in self?.reachable.contains(url) ?? false },
            systemMenu: NoOpSystemMenu()
        )
        XCTAssertEqual(storeB.urls.count, 2)
        XCTAssertEqual(storeB.urls, [urlB, urlA])
    }

    func testStaleCleanupOnRestart() {
        let real = makeURL("real")
        store.add(url: real)
        reachable.remove(real)

        let storeB = RecentDocumentStore(
            userDefaults: suite,
            reachability: { [weak self] url in self?.reachable.contains(url) ?? false },
            systemMenu: NoOpSystemMenu()
        )
        XCTAssertTrue(storeB.urls.isEmpty, "stale URL cleaned on init")
        let raw = suite.stringArray(forKey: "MMForgeRecentDocuments") ?? []
        XCTAssertTrue(raw.isEmpty, "persistence cleaned")
    }
}
