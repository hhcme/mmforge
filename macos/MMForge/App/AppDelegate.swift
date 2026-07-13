import AppKit

/// Application delegate for MMForge.
///
/// Runs on the main actor because all ``NSApplicationDelegate`` callbacks
/// are delivered on the main thread and it interacts with ``RecentDocumentStore``
/// which is also ``@MainActor``-isolated.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared recent-document store that tracks opened files.
    let recentDocumentStore = RecentDocumentStore.shared

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Observe windows becoming main to capture opened documents and
        // register them with NSDocumentController's built-in Open Recent menu.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )

        // Observe document saves to catch first-time saves of new documents
        // (where the window was already main and didBecomeMain already fired).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(documentDidSave(_:)),
            name: Notification.Name("NSDocumentDidSaveNotification"),
            object: nil
        )
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // DocumentGroup(newDocument:) manages document creation.
        // Returning true here would create a conflicting untitled window.
        false
    }

    /// Re-open handler: create a new document when the Dock icon is clicked
    /// with no open windows (standard macOS document-app behavior).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSDocumentController.shared.newDocument(nil)
        }
        return true
    }

    // MARK: - Recent documents

    /// Called when any window becomes main. If the window hosts a document
    /// with a known file URL, record it in both the system Open Recent menu
    /// and our local ``RecentDocumentStore``.
    @objc private func windowDidBecomeMain(_ notification: Notification) {
        noteDocument(from: notification.object)
    }

    /// Called when a document is saved. Handles first-time saves where the
    /// window was already main but the URL was not yet known.
    @objc private func documentDidSave(_ notification: Notification) {
        noteDocument(from: notification.object)
    }

    /// Extract the document URL from a notification payload and register it.
    private func noteDocument(from object: Any?) {
        let url: URL? = {
            if let window = object as? NSWindow {
                return (window.windowController?.document as? NSDocument)?.fileURL
            }
            if let document = object as? NSDocument {
                return document.fileURL
            }
            return nil
        }()

        guard let url else { return }

        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentDocumentStore.add(url: url)
    }

    /// Open a document URL from a menu item whose ``NSMenuItem/representedObject``
    /// is the `URL` to open.
    @objc func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(
            withContentsOf: url,
            display: true
        ) { _, _, error in
            if let error {
                NSApp.presentError(error)
            }
        }
    }

    /// Clear both the system Open Recent menu and the local recent-document store.
    @objc func clearRecentDocuments(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
        recentDocumentStore.clear()
    }
}
