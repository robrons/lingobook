import SwiftUI
import SwiftData

/// Main entry view with navigation stack
struct ContentView: View {
    @State private var navigationPath = NavigationPath()
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            LibraryView(navigationPath: $navigationPath)
                .navigationDestination(for: Book.self) { book in
                    ReaderView(book: book, navigationPath: $navigationPath)
                }
        }
        .background(TransparentWindowBackground())
    }
}

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

#Preview {
    ContentView()
        .modelContainer(for: Book.self, inMemory: true)
}
