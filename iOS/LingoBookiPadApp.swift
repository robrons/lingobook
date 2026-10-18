import SwiftUI
import SwiftData

@main
struct LingoBookiPadApp: App {
    private let modelContainer = ModelContainerFactory.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
