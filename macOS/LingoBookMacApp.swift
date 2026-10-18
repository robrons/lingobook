import SwiftUI
import SwiftData

@main
struct LingoBookMacApp: App {
    var sharedModelContainer: ModelContainer = ModelContainerFactory.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(AppleTVBridge())
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1200, height: 800)

        // Gets ⌘, and a place in the app menu for free.
        Settings {
            SettingsView()
        }
    }
}
