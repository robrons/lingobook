import SwiftUI
import SwiftData

@main
struct LingoBookiPadApp: App {
    var sharedModelContainer: ModelContainer = ModelContainerFactory.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
