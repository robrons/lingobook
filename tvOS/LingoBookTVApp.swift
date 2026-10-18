import SwiftUI
import SwiftData

@main
struct LingoBookTVApp: App {
    private let modelContainer = ModelContainerFactory.makeContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TVContentView()
                // tvOS suspends the app in the background, which can tear the listener
                // down. Coming back to the front is when the Mac is most likely waiting.
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active {
                        BookReceiver.shared.start(modelContext: modelContainer.mainContext)
                    }
                }
        }
        .modelContainer(modelContainer)
    }
}

struct TVContentView: View {
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TVLibraryView(navigationPath: $navigationPath)
                .navigationDestination(for: Book.self) { book in
                    TVReaderView(book: book)
                }
        }
    }
}
