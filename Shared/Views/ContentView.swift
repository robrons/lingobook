import SwiftUI
import SwiftData

/// Main entry view with navigation stack
struct ContentView: View {
    @State private var navigationPath = NavigationPath()
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            LibraryView(navigationPath: $navigationPath)
                .navigationDestination(for: Book.self) { book in
                    ReaderView(book: book, navigationPath: $navigationPath)
                }
        }
        #if os(macOS)
        .background(TransparentWindowBackground())
        #endif
        #if DEBUG
        // `-LBOpen "title fragment"` opens that book, as on Apple TV, for checking the
        // reader without clicking through the library.
        .task {
            guard let fragment = UserDefaults.standard.string(forKey: "LBOpen") else { return }
            let books = (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
            if let book = books.first(where: { $0.title.localizedCaseInsensitiveContains(fragment) }) {
                navigationPath.append(book)
            }
        }
        #endif
    }
}

#if os(macOS)
import AppKit

/// Makes the window background transparent for vibrancy effect
struct TransparentWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.isOpaque = false
                window.backgroundColor = .clear
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

#Preview {
    ContentView()
        .modelContainer(for: Book.self, inMemory: true)
}
