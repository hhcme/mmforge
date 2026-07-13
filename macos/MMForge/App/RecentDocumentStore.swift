import AppKit
import Foundation

/// Stores recently opened document URLs in UserDefaults.
///
/// The in-memory ``urls`` array is the single source of truth for the current
/// session. It is persisted to `UserDefaults` synchronously on each mutation.
/// On init, ``urls`` is restored from the persisted list and stale (unreachable)
/// entries are cleaned from both persistence and the system Open Recent menu.
///
/// Integration with the built-in File > Open Recent menu is handled by
/// ``AppDelegate``, which calls ``NSDocumentController/noteNewRecentDocumentURL(_:)``
/// whenever a document is opened.
final class RecentDocumentStore: ObservableObject {
    /// Shared singleton for app-wide access.
    static let shared = RecentDocumentStore()

    /// The current list of recent document URLs, published for SwiftUI observation.
    @Published private(set) var urls: [URL] = []

    // MARK: - Storage constants

    private let defaults: UserDefaults
    private let maxEntries = 10
    private let storageKey = "MMForgeRecentDocuments"

    // MARK: - Lifecycle

    /// Create a store backed by the given `UserDefaults` instance.
    ///
    /// - Parameter userDefaults: Defaults to `.standard`. In tests, pass an
    ///   isolated suite to verify persistence across simulated restarts.
    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults

        // Load persisted URLs and clean stale (unreachable) entries.
        let persisted = Self.load(from: defaults)
        let valid = persisted.filter { Self.isReachable($0) }
        if valid.count != persisted.count {
            // Stale entries existed — save the cleaned list back so they don't
            // survive the next launch.
            Self.save(valid, to: defaults)
        }
        self.urls = valid

        // In app context (not during unit testing), also clean stale entries
        // from NSDocumentController's built-in Open Recent menu.
        if NSClassFromString("XCTestCase") == nil {
            cleanSystemMenu()
        }
    }

    // MARK: - Public API

    /// Add a URL to the front of the recent-documents list.
    ///
    /// If the URL is already present it is moved to the front. The list is
    /// capped at `maxEntries` and persisted immediately.
    func add(url: URL) {
        var list = urls
        list.removeAll { $0 == url }
        list.insert(url, at: 0)
        if list.count > maxEntries {
            list = Array(list.prefix(maxEntries))
        }
        urls = list
        Self.save(list, to: defaults)
    }

    /// Remove a URL from the recent-documents list and persist.
    func remove(url: URL) {
        var list = urls
        list.removeAll { $0 == url }
        urls = list
        Self.save(list, to: defaults)
    }

    /// Return the list of recent document URLs, filtered to only those that
    /// still exist on disk. Callers that need the complete persisted list
    /// should use ``urls`` instead.
    func recentURLs() -> [URL] {
        urls.filter { Self.isReachable($0) }
    }

    /// Remove all entries from the recent-documents list and persistence.
    func clear() {
        urls = []
        defaults.removeObject(forKey: storageKey)
    }

    /// Sync local `urls` from NSDocumentController's built-in recent documents
    /// and clean stale entries from the system menu.
    func syncFromSystemMenu() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        let systemURLs = NSDocumentController.shared.recentDocumentURLs
        let valid = systemURLs.filter { Self.isReachable($0) }
        urls = valid
        Self.save(valid, to: defaults)

        // Clean stale entries from the system Open Recent menu.
        if valid.count != systemURLs.count {
            cleanSystemMenu()
        }
    }

    // MARK: - Private

    /// Remove stale entries from NSDocumentController's Open Recent menu.
    ///
    /// Clears all entries then re-adds only those that are reachable on disk.
    private func cleanSystemMenu() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        let systemURLs = NSDocumentController.shared.recentDocumentURLs
        let valid = systemURLs.filter { Self.isReachable($0) }
        if valid.count != systemURLs.count {
            NSDocumentController.shared.clearRecentDocuments(self)
            for url in valid {
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            }
        }
    }

    private static func isReachable(_ url: URL) -> Bool {
        (try? url.checkResourceIsReachable()) ?? false
    }

    private static func load(from defaults: UserDefaults) -> [URL] {
        guard let strings = defaults.stringArray(forKey: "MMForgeRecentDocuments") else {
            return []
        }
        return strings.map { URL(fileURLWithPath: $0) }
    }

    private static func save(_ urls: [URL], to defaults: UserDefaults) {
        let strings = urls.map { $0.path }
        defaults.set(strings, forKey: "MMForgeRecentDocuments")
    }
}
