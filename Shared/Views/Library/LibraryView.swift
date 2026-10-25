import SwiftUI
import SwiftData
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// How the shelf is ordered. Persisted, because a sort you have to re-pick every launch
/// isn't really a preference.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added"
    case recentlyRead = "Recently Read"
    case title = "Title"
    case author = "Author"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .recentlyAdded: return "clock.badge.plus"
        case .recentlyRead: return "book"
        case .title: return "textformat"
        case .author: return "person"
        }
    }
}

/// The library: books, and nothing else.
///
/// The old version opened on a logo, a tagline, and a permanent dashed drop target —
/// three things you'd read once. Books app opens on books, so this does too. Importing
/// moved to the toolbar (⌘O) and drag-and-drop, which only shows itself when you drag.
struct LibraryView: View {
    @Binding var navigationPath: NavigationPath

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]

    @AppStorage("librarySort") private var sortRaw = LibrarySort.recentlyAdded.rawValue

    @State private var searchText = ""
    @State private var isDragging = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showImporter = false
    @State private var showSettings = false
    /// Title of a book the reader tried to import twice. Not an error — just a nudge.
    @State private var duplicateTitle: String?

    private let epubService = EPUBService()

    private var sort: LibrarySort {
        LibrarySort(rawValue: sortRaw) ?? .recentlyAdded
    }

    // MARK: - Derived collections

    /// Search matches title or author. `localizedStandardContains` is what makes
    /// "monte cristo" find "Le Comte de Monte-Cristo" — it ignores case and accents,
    /// which matters when the whole shelf is French.
    private var visibleBooks: [Book] {
        let matched = searchText.isEmpty ? books : books.filter {
            $0.title.localizedStandardContains(searchText)
                || $0.author.localizedStandardContains(searchText)
        }

        switch sort {
        case .recentlyAdded:
            return matched.sorted { $0.dateAdded > $1.dateAdded }
        case .recentlyRead:
            return matched.sorted {
                ($0.lastReadDate ?? .distantPast) > ($1.lastReadDate ?? .distantPast)
            }
        case .title:
            return matched.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            return matched.sorted { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        }
    }

    /// Hidden while searching: a shelf of recents alongside search results would just be
    /// two answers to one question.
    private var continueReading: [Book] {
        guard searchText.isEmpty else { return [] }

        let recents = books
            .filter { $0.lastReadDate != nil }
            .sorted { ($0.lastReadDate ?? .distantPast) > ($1.lastReadDate ?? .distantPast) }
            .prefix(3)
            .map { $0 }

        // A shortcut to your recent books is only a shortcut if it saves you a look
        // further down. On a small shelf it just prints the same covers twice on one
        // screen, which reads as a bug rather than a convenience.
        guard recents.count < books.count else { return [] }

        return recents
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            #if os(macOS)
            VisualEffectBackground()
                .ignoresSafeArea()
            #else
            Color(.systemGroupedBackground).ignoresSafeArea()
            #endif

            if books.isEmpty {
                emptyLibrary
            } else if visibleBooks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                shelf
            }
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search by title or author")
        .toolbar { toolbarContent }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #else
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.epub]) { result in
            switch result {
            case .success(let url):
                Task { await loadBook(from: url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
                showError = true
            }
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "epub" else { return }
            Task { await loadBook(from: url) }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        #endif
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if isDragging { dropTarget }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
        .alert(
            "Already in Your Library",
            isPresented: Binding(get: { duplicateTitle != nil }, set: { if !$0 { duplicateTitle = nil } })
        ) {
            Button("OK") { duplicateTitle = nil }
        } message: {
            Text("“\(duplicateTitle ?? "")” is already on your shelf, so it wasn't imported again.")
        }
        .overlay {
            if isLoading { loadingOverlay }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(LibrarySort.allCases) { option in
                        Label(option.rawValue, systemImage: option.systemImage)
                            .tag(option.rawValue)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort your library")
        }

        ToolbarItem(placement: .primaryAction) {
            Button(action: startImport) {
                Label("Import EPUB", systemImage: "plus")
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Import an EPUB (⌘O)")
        }
    }

    // MARK: - Shelf

    private var shelf: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !continueReading.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Continue Reading")

                        HStack(alignment: .top, spacing: 20) {
                            ForEach(continueReading) { book in
                                Button { navigationPath.append(book) } label: {
                                    ContinueReadingCard(book: book)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens the book")
                                .contextMenu { bookMenu(for: book) }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    if !continueReading.isEmpty {
                        sectionHeader("All Books")
                    }
                    bookGrid
                }
            }
            .padding(28)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
    }

    private var bookGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 20)], spacing: 24) {
            ForEach(visibleBooks) { book in
                Button { navigationPath.append(book) } label: {
                    BookCard(book: book)
                        #if os(macOS)
                        .overlay(alignment: .topLeading) { AppleTVBadge(book: book) }
                        #endif
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the book")
                .contextMenu { bookMenu(for: book) }
            }
        }
    }

    /// The same menu on every cover, Continue Reading included — a book you've started
    /// is exactly the one you'd want to send to the TV.
    @ViewBuilder
    private func bookMenu(for book: Book) -> some View {
        #if os(macOS)
        sendToAppleTVButton(for: book)
        Divider()
        #endif
        deleteButton(for: book)
    }

    #if os(macOS)
    /// Translates the whole book, then sends it to the Apple TV — which can't translate.
    @ViewBuilder
    private func sendToAppleTVButton(for book: Book) -> some View {
        let preparer = BookPreparer.shared
        Button {
            preparer.sendToAppleTV(book)
        } label: {
            Label(
                book.appleTVStatus == .sent ? "Send to Apple TV Again" : "Send to Apple TV",
                systemImage: "appletv"
            )
        }
        .disabled(preparer.isPreparing(book) || book.appleTVStatus == .waiting)
    }
    #endif

    private func deleteButton(for book: Book) -> some View {
        Button(role: .destructive) {
            withAnimation { modelContext.delete(book) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No Books Yet", systemImage: "books.vertical")
        } description: {
            Text("Import an EPUB to get started.")
        } actions: {
            Button("Import EPUB", action: startImport)
                .buttonStyle(.borderedProminent)
        }
    }

    /// Only appears mid-drag. The rest of the time the shelf speaks for itself.
    private var dropTarget: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [10]))
                .padding(16)

            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                Text("Drop to import")
                    .font(.title3.weight(.medium))
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: isDragging)
        .allowsHitTesting(false)
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

    private func startImport() {
        #if os(macOS)
        openFilePicker()
        #else
        showImporter = true
        #endif
    }

    #if os(macOS)
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            Task { await loadBook(from: url) }
        }
    }
    #endif

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

    private func loadBook(from url: URL) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let content = try epubService.parse(epubData: data)

            // Re-importing a book you already have is a mistake, not a request for a second
            // copy — and a duplicate would carry its own separate reading position.
            if books.contains(where: { $0.matches(title: content.title, author: content.author) }) {
                duplicateTitle = content.title
                return
            }

            let book = Book(
                title: content.title,
                author: content.author,
                epubData: data,
                coverData: content.coverData,
                language: content.language
            )

            modelContext.insert(book)
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Continue Reading

/// A book you're partway through — Books' Continue strip: a compact tinted pill with a
/// thumbnail cover, not a second full-size cover competing with the shelf below it.
private struct ContinueReadingCard: View {
    let book: Book

    private let coverHeight: CGFloat = 84
    private var coverWidth: CGFloat { coverHeight * 2 / 3 }

    var body: some View {
        HStack(spacing: 14) {
            BookCover(book: book)
                .frame(width: coverWidth, height: coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Text(book.author)
                    .font(.caption)
                    .opacity(0.8)
                    .lineLimit(1)

                Text("Book · \(book.progressPercent)%")
                    .font(.caption)
                    .opacity(0.65)
                    .monospacedDigit()
                    .padding(.top, 6)
            }

            Spacer(minLength: 12)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: 340)
        .background(
            // The pill takes its colour from the book so the strip reads as "your
            // books", not a row of identical grey buttons.
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.generatedCoverTint(for: book.title).gradient)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.accessibilityDescription)
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
    NavigationStack {
        LibraryView(navigationPath: .constant(NavigationPath()))
    }
    .modelContainer(for: Book.self, inMemory: true)
}
