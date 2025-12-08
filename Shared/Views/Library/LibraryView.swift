import SwiftUI
import SwiftData
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// Library view showing user's book collection
struct LibraryView: View {
    @Binding var navigationPath: NavigationPath
    
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    
    @State private var isDragging = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    
    #if os(iOS)
    @State private var showFilePicker = false
    #endif
    
    private let epubService = EPUBService()
    
    var body: some View {
        ZStack {
            // Background
            #if os(iOS)
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
            #else
            VisualEffectBackground()
                .ignoresSafeArea()
            #endif
            
            ScrollView {
                VStack(spacing: 32) {
                    headerSection
                    uploadSection
                    librarySection
                }
                .padding(32)
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
        }
        #endif
        #if os(iOS)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "epub")!],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result: result)
        }
        #endif
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
        .overlay {
            if isLoading {
                loadingOverlay
            }
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 50))
                .foregroundStyle(.orange)
            
            Text("LingoBook")
                .font(.system(size: 42, weight: .bold, design: .serif))
            
            Text("Read your favorite books with AI-powered bilingual support")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .padding(.top, 20)
    }
    
    // MARK: - Upload Section
    
    private var uploadSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    isDragging ? Color.orange : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [10])
                )
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isDragging ? Color.orange.opacity(0.1) : Color.secondary.opacity(0.05))
                )
                .animation(.easeInOut(duration: 0.2), value: isDragging)
            
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isDragging ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.title)
                        .foregroundStyle(isDragging ? .orange : .secondary)
                }
                
                VStack(spacing: 4) {
                    #if os(iOS)
                    Text("Tap to import EPUB files")
                        .font(.headline)
                        .foregroundStyle(isDragging ? .orange : .primary)
                    #else
                    Text("Drop EPUB files here or click to browse")
                        .font(.headline)
                        .foregroundStyle(isDragging ? .orange : .primary)
                    #endif
                    
                    Text("EPUB files only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
        }
        .frame(height: 160)
        .contentShape(Rectangle())
        .onTapGesture {
            #if os(iOS)
            showFilePicker = true
            #else
            openFilePicker()
            #endif
        }
    }
    
    // MARK: - Library Section
    
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "books.vertical.fill")
                    .foregroundStyle(.secondary)
                Text(books.isEmpty ? "Library Empty" : "Library (\(books.count))")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            
            if books.isEmpty {
                emptyLibraryPlaceholder
            } else {
                bookGrid
            }
        }
    }
    
    private var emptyLibraryPlaceholder: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 20) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .aspectRatio(2/3, contentMode: .fit)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 3)
                            .frame(width: 50, height: 50)
                    }
            }
        }
        .opacity(0.5)
    }
    
    private var bookGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 20) {
            ForEach(books) { book in
                BookCard(book: book)
                    .onTapGesture {
                        navigationPath.append(book)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            withAnimation {
                                modelContext.delete(book)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }
    
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Loading book...")
                    .font(.headline)
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
    
    // MARK: - Actions
    
    #if os(macOS)
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK, let url = panel.url {
            Task { await loadBook(from: url) }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil),
               url.pathExtension.lowercased() == "epub" {
                Task { @MainActor in await loadBook(from: url) }
            }
        }
        return true
    }
    #endif
    
    #if os(iOS)
    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                guard url.startAccessingSecurityScopedResource() else {
                    errorMessage = "Unable to access the selected file"
                    showError = true
                    return
                }
                Task {
                    await loadBook(from: url)
                    url.stopAccessingSecurityScopedResource()
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    #endif
    
    private func loadBook(from url: URL) async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let data = try Data(contentsOf: url)
            let content = try epubService.parse(epubData: data)
            
            let book = Book(
                title: content.title,
                author: content.author,
                epubData: data,
                coverData: content.coverData
            )
            
            modelContext.insert(book)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Visual Effect Background (macOS only)

#if os(macOS)
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#endif

#Preview {
    LibraryView(navigationPath: .constant(NavigationPath()))
        .modelContainer(for: Book.self, inMemory: true)
}
