import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up any AppKit-level configuration here.
        // e.g. main menu customization, recent documents support.
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // Show a new document on launch, per macOS document-based app convention.
        true
    }
}
