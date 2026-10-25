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
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TVLibraryView(navigationPath: $navigationPath)
                .navigationDestination(for: Book.self) { book in
                    TVReaderView(book: book)
                }
        }
        #if DEBUG
        .task { TVDebugLaunch.run(navigationPath: $navigationPath, modelContext: modelContext) }
        #endif
    }
}

#if DEBUG
/// Launch arguments that put the app in a known state, so the reader can be inspected in
/// the simulator without a remote:
/// `-LBImport /path/book.epub -LBOpen "title fragment" -LBTurns 3 -LBControls YES -LBPanel aa`
/// (or `-LBPanel ask`, or `-LBAsk 0` to ask Ask's first ready-made question).
enum TVDebugLaunch {
    private static var defaults: UserDefaults { .standard }

    static var pageTurns: Int { defaults.integer(forKey: "LBTurns") }
    static var showsControls: Bool { defaults.bool(forKey: "LBControls") }
    /// "aa" or "contents".
    static var panel: String? { defaults.string(forKey: "LBPanel") }
    /// Holds a hand-turned page this far over, for a screenshot; `-LBCurlBack YES` turns back.
    static var curlFreeze: CGFloat? {
        guard defaults.object(forKey: "LBCurlFreeze") != nil else { return nil }
        let amount = CGFloat(defaults.double(forKey: "LBCurlFreeze"))
        return defaults.bool(forKey: "LBCurlBack") ? -amount : amount
    }
    /// Opens on the last page of the chapter, for testing a turn into the next one.
    static var opensOnLastPage: Bool { defaults.bool(forKey: "LBLastPage") }
    /// Turns this many pages forward, one every 1.5 seconds, the way a swipe would.
    static var autoTurns: Int { defaults.integer(forKey: "LBAutoTurns") }
    /// A text size to read at.
    static var fontSize: CGFloat? {
        defaults.object(forKey: "LBFont") == nil ? nil : CGFloat(defaults.double(forKey: "LBFont"))
    }
    /// A `LayoutMode` raw value to read in ("Interleaved", "Side by Side", "Original").
    static var layout: String? { defaults.string(forKey: "LBLayout") }
    /// A `Translator` raw value to translate with ("apple", "claude").
    static var translator: String? { defaults.string(forKey: "LBTranslator") }
    /// A `BookTheme` raw value to read in.
    static var theme: String? { defaults.string(forKey: "LBTheme") }
    /// Scrolls the settings panel to its foot.
    static var scrollsPanel: Bool { defaults.bool(forKey: "LBPanelEnd") }
    /// Opens the book at this chapter (zero-based), before any `-LBTurns`.
    static var chapter: Int? {
        defaults.object(forKey: "LBChapter") == nil ? nil : defaults.integer(forKey: "LBChapter")
    }
    /// Asks these in turn, each once the last has been answered: `-LBQuestions "#0|Qui est Fantine ?"`.
    /// `#n` is Ask's ready-made question n. Answers go to Caches/ask-log.jsonl.
    static var questions: [String] {
        defaults.string(forKey: "LBQuestions")?.split(separator: "|").map(String.init) ?? []
    }
    /// Opens Ask and asks one of its ready-made questions, by index: `-LBAsk 0`.
    static var askSuggestion: Int? {
        defaults.object(forKey: "LBAsk") == nil ? nil : defaults.integer(forKey: "LBAsk")
    }

    @MainActor
    static func run(navigationPath: Binding<NavigationPath>, modelContext: ModelContext) {
        if let path = defaults.string(forKey: "LBImport"),
           let data = FileManager.default.contents(atPath: path),
           let content = try? EPUBService().parse(epubData: data) {
            let existing = (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
            if !existing.contains(where: { $0.matches(title: content.title, author: content.author) }) {
                modelContext.insert(Book(
                    title: content.title,
                    author: content.author,
                    epubData: data,
                    coverData: content.coverData,
                    language: content.language
                ))
                try? modelContext.save()
            }
        }

        guard let fragment = defaults.string(forKey: "LBOpen") else { return }
        let books = (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
        if let book = books.first(where: { $0.title.localizedCaseInsensitiveContains(fragment) }) {
            navigationPath.wrappedValue.append(book)
        }
    }
}
#endif
