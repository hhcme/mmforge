import AppKit
import Foundation

/// Stores recently opened document URLs in UserDefaults.
///
/// The in-memory ``urls`` array is the single source of truth for the current
/// session.  It is persisted to `UserDefaults` asynchronously on each mutation.
/// On init, ``urls`` is restored from the persisted list.
///
/// Integration with the built-in File > Open Recent menu is handled by
/// ``AppDelegate``, which calls ``NSDocumentController/n noteNewRecentDocumentURL(_:)``
/// whenever a document is opened.
final class RecentDocumentStore: ObservableObject {
    /// Shared singleton for app-wide access.
    static let shared = RecentDocumentStore()

    /// The current list of recent document URLs, published for SwiftUI observation.
    @Published private(set) var urls: [URL] = []

    // MARK: - Storage constants

    private enum Storage {
        static let key = "MMForgeRecentDocuments"
        static let maxEntries = 10
        static let queue = DispatchQueue(label: "com.mmforge.recentDocuments")
    }

    // MARK: - Lifecycle

    init() {
        urls = Self.loadFromDefaults()
        // Only sync from system menu in app context (not during unit testing).
        if NSClassFromString("XCTestCase") == nil {
            syncFromSystemMenu()
        }
    }

    // MARK: - Public API

    /// Add a URL to the front of the recent-documents list.
    func add(url: URL) {
        var list = urls
        list.removeAll { $0 == url }
        list.insert(url, at: 0)
        if list.count > Storage.maxEntries {
            list = Array(list.prefix(Storage.maxEntries))
        }
        urls = list
        persist(list)
    }

    /// Remove a URL from the recent-documents list and persist.
    func remove(url: URL) {
        var list = urls
        list.removeAll { $0 == url }
        urls = list
        persist(list)
    }

    /// Return the list of recent document URLs, filtered to only those that
    /// still exist on disk. Callers that need the complete persisted list
    /// should use ``urls`` instead.
    func recentURLs() -> [URL] {
        urls.filter { url in
            (try? url.checkResourceIsReachable()) ?? false
        }
    }

    /// Remove all entries from the recent-documents list and persist.
    func clear() {
        urls = []
        Storage.queue.async {
            UserDefaults.standard.removeObject(forKey: Storage.key)
        }
    }

    /// Synchronously drain the background persistence queue (for testing).
    func waitForQueue() {
        Storage.queue.sync {}
    }

    /// Sync local `urls` from NSDocumentController's built-in recent documents.
    func syncFromSystemMenu() {
        let systemURLs = NSDocumentController.shared.recentDocumentURLs
        let valid = systemURLs.filter { url in
            (try? url.checkResourceIsReachable()) ?? false
        }
        urls = valid
        persist(valid)
    }

    // MARK: - Private

    private func persist(_ list: [URL]) {
        let strings = list.map { $0.path }
        Storage.queue.async {
            UserDefaults.standard.set(strings, forKey: Storage.key)
        }
    }

    private static func loadFromDefaults() -> [URL] {
        guard let strings = UserDefaults.standard.stringArray(forKey: Storage.key) else {
            return []
        }
        return strings.map { URL(fileURLWithPath: $0) }
    }
}
