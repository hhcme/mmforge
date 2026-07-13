import AppKit
import Foundation

// MARK: - Dependency abstractions

/// Abstract system recent-document menu operations so tests can verify
/// without probing `NSClassFromString("XCTestCase")`.
protocol SystemRecentMenu {
    func recentDocumentURLs() -> [URL]
    func clearRecentDocuments(_ sender: Any?)
    func noteNewRecentDocumentURL(_ url: URL)
}

/// Default implementation backed by NSDocumentController.
struct NSDocumentControllerMenu: SystemRecentMenu {
    private var controller: NSDocumentController { NSDocumentController.shared }
    func recentDocumentURLs() -> [URL] {
        controller.recentDocumentURLs
    }
    func clearRecentDocuments(_ sender: Any?) {
        controller.clearRecentDocuments(sender)
    }
    func noteNewRecentDocumentURL(_ url: URL) {
        controller.noteNewRecentDocumentURL(url)
    }
}

/// No-op menu for testing.
struct NoOpSystemMenu: SystemRecentMenu {
    func recentDocumentURLs() -> [URL] { [] }
    func clearRecentDocuments(_ sender: Any?) {}
    func noteNewRecentDocumentURL(_ url: URL) {}
}

// MARK: - Store

/// Stores recently opened document URLs in UserDefaults.
///
/// Dependencies are injected so tests can verify behaviour without
/// `NSClassFromString("XCTestCase")` probes:
/// - `userDefaults`: isolated suite for restart-persistence testing.
/// - `reachability`: `(URL) -> Bool` — tests inject a predictable closure.
/// - `systemMenu`: `SystemRecentMenu` — tests inject a no-op or spy.
///
/// In production, ``shared`` uses `.standard`, `checkResourceIsReachable`,
/// and `NSDocumentControllerMenu()`.
@MainActor
final class RecentDocumentStore: ObservableObject {
    static let shared = RecentDocumentStore()

    @Published private(set) var urls: [URL] = []

    private let defaults: UserDefaults
    private let maxEntries = 10
    private let storageKey = "MMForgeRecentDocuments"
    private let reachability: (URL) -> Bool
    private let systemMenu: SystemRecentMenu

    // MARK: - Lifecycle

    init(
        userDefaults: UserDefaults = .standard,
        reachability: @escaping (URL) -> Bool = { (try? $0.checkResourceIsReachable()) ?? false },
        systemMenu: SystemRecentMenu = NSDocumentControllerMenu()
    ) {
        self.defaults = userDefaults
        self.reachability = reachability
        self.systemMenu = systemMenu

        let persisted = Self.load(from: defaults)
        let valid = persisted.filter(reachability)
        if valid.count != persisted.count {
            Self.save(valid, to: defaults)
        }
        self.urls = valid

        // Defer system menu cleaning — NSDocumentController may not be
        // ready during static initialization. AppDelegate calls
        // cleanSystemMenuIfNeeded() from applicationDidFinishLaunching.
    }

    /// Must be called from AppDelegate.applicationDidFinishLaunching
    /// to clean the system Open Recent menu after the app is fully booted.
    func cleanSystemMenuIfNeeded() {
        cleanSystemMenu()
    }

    // MARK: - Public API

    func add(url: URL) {
        // Reject unreachable URLs.
        guard reachability(url) else { return }

        var list = urls
        list.removeAll { $0 == url }
        list.insert(url, at: 0)
        if list.count > maxEntries {
            list = Array(list.prefix(maxEntries))
        }

        // Clean stale entries from memory + persistence + system menu.
        let valid = list.filter(reachability)
        urls = valid
        Self.save(valid, to: defaults)
        cleanSystemMenu()
    }

    func remove(url: URL) {
        var list = urls
        list.removeAll { $0 == url }
        urls = list
        Self.save(list, to: defaults)
    }

    /// Return reachable URLs.  If any stale entries are discovered,
    /// they are synchronously cleaned from memory, UserDefaults, and
    /// the system Open Recent menu.
    func recentURLs() -> [URL] {
        let valid = urls.filter(reachability)
        if valid.count != urls.count {
            // Stale entries found — clean everything.
            urls = valid
            Self.save(valid, to: defaults)
            cleanSystemMenu()
        }
        return valid
    }

    func clear() {
        urls = []
        defaults.removeObject(forKey: storageKey)
    }

    func syncFromSystemMenu() {
        let systemURLs = systemMenu.recentDocumentURLs()
        let valid = systemURLs.filter(reachability)
        urls = valid
        Self.save(valid, to: defaults)
        if valid.count != systemURLs.count {
            cleanSystemMenu()
        }
    }

    // MARK: - Private

    private func cleanSystemMenu() {
        let systemURLs = systemMenu.recentDocumentURLs()
        let valid = systemURLs.filter(reachability)
        if valid.count != systemURLs.count {
            systemMenu.clearRecentDocuments(self)
            for url in valid {
                systemMenu.noteNewRecentDocumentURL(url)
            }
        }
    }

    // MARK: - Persistence (nonisolated — no mutable instance state)

    nonisolated private static func load(from defaults: UserDefaults) -> [URL] {
        guard let strings = defaults.stringArray(forKey: "MMForgeRecentDocuments") else {
            return []
        }
        return strings.map { URL(fileURLWithPath: $0) }
    }

    nonisolated private static func save(_ urls: [URL], to defaults: UserDefaults) {
        let strings = urls.map { $0.path }
        defaults.set(strings, forKey: "MMForgeRecentDocuments")
    }
}
