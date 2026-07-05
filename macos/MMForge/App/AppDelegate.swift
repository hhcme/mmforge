import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // DocumentGroup sets up NSDocumentController automatically.
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
}
