import Foundation

/// Stores recently opened document URLs in UserDefaults.
///
/// Thread-safe via a serial ``DispatchQueue``. Conforms to ``ObservableObject``
/// so SwiftUI views can observe changes to the recent-documents list.
///
/// Integration with the built-in File > Open Recent menu is handled by
/// ``AppDelegate``, which calls ``NSDocumentController/n noteNewRecentDocumentURL(_:)``
/// whenever a document is opened.
@MainActor
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
    }

    // MARK: - Public API

    /// Add a URL to the front of the recent-documents list.
    ///
    /// If the URL already exists in the list it is moved to the front.
    /// The list is capped at ``Storage/maxEntries`` entries.
    /// Changes are persisted to `UserDefaults` on a background queue.
    func add(url: URL) {
        Storage.queue.async { [weak self] in
            var urls = Self.loadFromDefaults()
            urls.removeAll { $0 == url }
            urls.insert(url, at: 0)
            if urls.count > Storage.maxEntries {
                urls = Array(urls.prefix(Storage.maxEntries))
            }
            Self.save(urls)
            Task { @MainActor [weak self] in
                self?.urls = urls
            }
        }
    }

    /// Remove a URL from the recent-documents list and persist.
    func remove(url: URL) {
        Storage.queue.async { [weak self] in
            var urls = Self.loadFromDefaults()
            urls.removeAll { $0 == url }
            Self.save(urls)
            Task { @MainActor [weak self] in
                self?.urls = urls
            }
        }
    }

    /// Return the list of recent document URLs, filtered to only those that
    /// still exist on disk. Callers that need the complete persisted list
    /// should use ``urls`` instead.
    func recentURLs() -> [URL] {
        Storage.queue.sync {
            Self.loadFromDefaults().filter { url in
                (try? url.checkResourceIsReachable()) ?? false
            }
        }
    }

    /// Remove all entries from the recent-documents list and persist.
    func clear() {
        Storage.queue.async { [weak self] in
            UserDefaults.standard.removeObject(forKey: Storage.key)
            Task { @MainActor [weak self] in
                self?.urls = []
            }
        }
    }

    // MARK: - Private persistence

    /// Must be `nonisolated` because it is called from ``Storage/queue``,
    /// which runs off the main actor.
    private nonisolated static func loadFromDefaults() -> [URL] {
        guard let strings = UserDefaults.standard.stringArray(forKey: Storage.key) else {
            return []
        }
        return strings.map { URL(fileURLWithPath: $0) }
    }

    /// Must be `nonisolated` because it is called from ``Storage/queue``,
    /// which runs off the main actor.
    private nonisolated static func save(_ urls: [URL]) {
        let strings = urls.map { $0.path }
        UserDefaults.standard.set(strings, forKey: Storage.key)
    }
}
