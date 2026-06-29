import SwiftUI

@main
struct MMForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: MMForgeDocument()) { file in
            ContentView(document: file.document)
        }
        .commands {
            SidebarCommands()
            InspectorCommands()
        }

        #if DEBUG
        Window("Debug Console", id: "debug-console") {
            Text("Debug Console Placeholder")
                .frame(minWidth: 400, minHeight: 300)
        }
        #endif
    }
}
