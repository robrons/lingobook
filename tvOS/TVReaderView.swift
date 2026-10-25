import SwiftUI
import SwiftData

/// The reader, driven by the Siri Remote and laid out the way Books lays out a book.
///
/// Reading, there is nothing on screen but the spread and two quiet running heads. Left
/// and right turn pages. Clicking brings up Books' chrome: a bar along the top (Library,
/// Contents and Aa on the left, the title, Ask on its own at the right) and the page
/// number below. Back peels those away one layer at a time, then returns to the library.
///
/// Translations come from what the Mac sent — Apple's translator can't run here — or, if
/// it's chosen, from Claude, a page at a time as it's read, each page kept with the book.
struct TVReaderView: View {
    let book: Book

    init(book: Book) {
        self.book = book
        // Open in the book's own theme from the very first frame. Starting from the
        // default and switching once the book had loaded flashed a bright cream page
        // before a dark theme took over.
        let viewModel = ReaderViewModel()
        let saved = BookTheme(rawValue: book.savedThemeName) ?? .calm
        viewModel.currentTheme = ReaderAppearance.current.theme(saved)
        _viewModel = State(initialValue: viewModel)
    }

    /// Light, Dark, or following the Apple TV — for every book, as in Books.
    @AppStorage(ReaderAppearance.key) private var appearanceRaw = ReaderAppearance.automatic.rawValue
    private var appearance: ReaderAppearance { ReaderAppearance(rawValue: appearanceRaw) ?? .automatic }

    /// Puts the theme on the page in the light or dark the appearance setting calls for.
    private func applyAppearance() {
        let themed = appearance.theme(viewModel.currentTheme)
        if themed != viewModel.currentTheme { viewModel.currentTheme = themed }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ReaderViewModel
    @State private var chrome: Chrome = .hidden
    @FocusState private var focus: Focus?
    /// Set by a turn the reader asked for, so the spread it brings curls over rather than
    /// simply appearing — unlike a jump from Contents, or a reflow after a font change.
    @State private var curlsNextSpread = false
    @State private var curl = PageCurl()
    /// The open book's size: one page is half of it.
    @State private var bookSize: CGSize = .zero
    /// The swipe in progress: which way, and whether it's driving the curl by hand.
    @State private var swipe: (forward: Bool, byHand: Bool, turned: Bool)?
    /// Pictures of pages, kept for the spread on show so a turn starts without a wait.
    @State private var pageImages: [String: CGImage] = [:]
    /// Ask's conversation about the chapter. Kept while the panel is closed, so a question
    /// can be picked up again after reading on.
    @State private var conversation = AskConversation()
    /// While Ask's answers are being read, a swipe scrolls them, so the top bar is kept
    /// out of focus's reach.
    @State private var isReadingAnswers = false

    /// What's layered over the page. Each Back press removes one layer.
    private enum Chrome {
        case hidden
        case controls
        case appearance
        case contents
        case ask
    }

    private enum Focus: Hashable {
        case page
        case library, contents, appearance, ask
        case panel
    }

    /// Books' size ladder, scaled for reading from the sofa: fine steps where most people
    /// read, bigger ones at the top where a couple of points barely shows.
    private static let fontSizes: [CGFloat] = [24, 26, 28, 30, 32, 34, 36, 40, 44, 48, 52, 56]

    private var theme: BookTheme { viewModel.currentTheme }

    var body: some View {
        ZStack {
            theme.pageColor
                .ignoresSafeArea()

            if let message = viewModel.loadError {
                ContentUnavailableView {
                    Label("Couldn't Open This Book", systemImage: "book.closed")
                } description: {
                    Text(message)
                }
                .foregroundStyle(theme.textColor)
            } else {
                page
                // Full screen, not the text area: the page being turned is the whole
                // page, out to the edges of the television. Kept in place between turns,
                // so a swipe lifts the page the instant the thumb moves.
                PageCurlView(curl: curl, paper: theme.pageColor)
                    .ignoresSafeArea()
                    .opacity(curl.isActive ? 1 : 0)
                    .allowsHitTesting(false)
                runningHeads
                    // While a page is in the air its footer is part of the page, turning with it.
                    .opacity(chrome == .hidden && !curl.isActive ? 1 : 0)
                if chrome != .hidden {
                    controls
                        .transition(.opacity)
                }
                if chrome == .appearance {
                    appearancePanel
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if chrome == .contents {
                    contentsPanel
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if chrome == .ask {
                    askPanel
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: chrome)
        .preferredColorScheme(theme.colorScheme)
        .toolbar(.hidden, for: .navigationBar)
        // Back closes one layer of chrome at a time; with none open, nil hands Back to
        // the navigation stack, which returns to the library.
        .onExitCommand(perform: chrome == .hidden ? nil : { stepBack() })
        .task {
            await viewModel.loadBook(book: book)
            applyAppearance()
            focus = .page
            #if DEBUG
            if let index = TVDebugLaunch.chapter, viewModel.chapters.indices.contains(index) {
                viewModel.currentChapterIndex = index
                await viewModel.loadChapter(at: index, start: .beginning)
            }
            for _ in 0..<TVDebugLaunch.pageTurns {
                viewModel.goToNextPage()
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let size = TVDebugLaunch.fontSize {
                viewModel.fontSize = size
                try? await Task.sleep(for: .milliseconds(800))
            }
            if let raw = TVDebugLaunch.translator, let translator = Translator(rawValue: raw) {
                viewModel.translator = translator
            }
            if let raw = TVDebugLaunch.layout, let mode = LayoutMode(rawValue: raw) {
                viewModel.layoutMode = mode
                try? await Task.sleep(for: .milliseconds(800))
            }
            if let raw = TVDebugLaunch.theme, let debugTheme = BookTheme(rawValue: raw) {
                viewModel.currentTheme = debugTheme
            }
            if TVDebugLaunch.showsControls { showControls() }
            if TVDebugLaunch.opensOnLastPage {
                viewModel.goToPage(max(0, viewModel.pages.count - 1))
                try? await Task.sleep(for: .milliseconds(300))
            }
            for _ in 0..<TVDebugLaunch.autoTurns {
                try? await Task.sleep(for: .seconds(1.5))
                clickTurn(forward: true)
            }
            if let frozen = TVDebugLaunch.curlFreeze {
                try? await Task.sleep(for: .seconds(1))
                if beginCurl(forward: frozen > 0) { curl.drag(to: abs(frozen)) }
            }
            switch TVDebugLaunch.panel {
            case "aa": showAppearance()
            case "contents": chrome = .contents
            case "ask": chrome = .ask
            default: break
            }
            if let index = TVDebugLaunch.askSuggestion,
               AskConversation.suggestions.indices.contains(index),
               let context = viewModel.pageContext(for: book) {
                chrome = .ask
                conversation.ask(AskConversation.suggestions[index], about: context)
            }
            if !TVDebugLaunch.questions.isEmpty { chrome = .ask }
            for question in TVDebugLaunch.questions {
                while conversation.isAnswering { try? await Task.sleep(for: .milliseconds(200)) }
                guard let context = viewModel.pageContext(for: book) else { break }
                if question.hasPrefix("#"), let index = Int(question.dropFirst()),
                   AskConversation.suggestions.indices.contains(index) {
                    conversation.ask(AskConversation.suggestions[index], about: context)
                } else {
                    conversation.ask(question, about: context)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            #endif
        }
        .onAppear { DisplaySleepPreventer.shared.preventSleep() }
        .onChange(of: viewModel.currentPageIndex) { _, _ in
            viewModel.translateCurrentPage()
            viewModel.saveProgress(book: book, modelContext: modelContext)
        }
        .onChange(of: viewModel.fontSize) { _, _ in
            viewModel.handleFontSizeChange()
            viewModel.saveProgress(book: book, modelContext: modelContext)
        }
        .onChange(of: viewModel.currentTheme) { _, _ in
            viewModel.saveProgress(book: book, modelContext: modelContext)
        }
        .onChange(of: viewModel.layoutMode) { _, _ in
            viewModel.saveProgress(book: book, modelContext: modelContext)
        }
        .onChange(of: viewModel.translator) { _, _ in
            viewModel.saveProgress(book: book, modelContext: modelContext)
        }
        // Each page Claude translates is written down at once, so it's never paid for twice.
        .onChange(of: viewModel.translationsVersion) { _, _ in
            viewModel.saveProgress(book: book, modelContext: modelContext)
        }
        .onChange(of: appearanceRaw) { _, _ in applyAppearance() }
        // Automatic follows the Apple TV, which can switch at sunset with the book open.
        .task(id: appearanceRaw) {
            guard appearance == .automatic else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                applyAppearance()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { applyAppearance() }
            if phase == .active {
                DisplaySleepPreventer.shared.preventSleep()
            } else {
                viewModel.saveProgress(book: book, modelContext: modelContext)
                viewModel.ttsService.stop()
                DisplaySleepPreventer.shared.allowSleep()
            }
        }
        .onDisappear {
            conversation.stop()
            viewModel.ttsService.stop()
            viewModel.saveProgress(book: book, modelContext: modelContext)
            DisplaySleepPreventer.shared.allowSleep()
        }
    }

    // MARK: - Page

    private var page: some View {
        GeometryReader { geometry in
            CurlPager(
                spread: spreadToken,
                forward: viewModel.navigatingForward,
                curls: curlsNextSpread,
                pageColor: theme.pageColor,
                left: AnyView(halfPage(.left, of: currentSpread)),
                right: AnyView(halfPage(.right, of: currentSpread))
            )
            .opacity(viewModel.isResizing ? 0.4 : 1)
            .onChange(of: geometry.size, initial: true) { _, newSize in
                bookSize = newSize
                viewModel.reconcileSize(newSize)
            }
        }
        .onChange(of: spreadToken) { _, _ in curlsNextSpread = false }
        .task(id: "\(spreadToken)|\(theme.rawValue)|\(viewModel.renderStyle.cacheKey)|\(viewModel.renderStyle.margins)|\(viewModel.translationsVersion)|\(chrome == .hidden)") {
            guard chrome == .hidden else { return }
            await preparePageImages()
        }
        .background {
            // The Siri Remote's touch surface, read directly — see `RemoteTouchSurface`.
            RemoteTouchSurface(isEnabled: chrome == .hidden) { event in
                handleSwipe(event)
            }
        }
        // The page itself holds focus while reading, so the remote talks to it.
        .focusable(chrome == .hidden)
        .focused($focus, equals: .page)
        .focusEffectDisabled()
        // Clicks — the centre for the controls, the edges to turn — are read straight
        // from the remote by `RemoteTouchSurface`, like swipes. Through SwiftUI, a click
        // only counts once the page holds focus, and on the television the first click
        // after opening a book went to giving it focus — so it took two to do anything.
    }

    /// Which spread is on screen. Changes when the page does, when a new chapter has
    /// finished laying out, and when a reflow changes what a page holds.
    private var spreadToken: String {
        "\(viewModel.paginatedChapterIndex)-\(viewModel.currentPageIndex)-\(viewModel.layoutVersion)"
    }

    private func turnForward() {
        guard viewModel.canGoNext else { return }
        curlsNextSpread = true
        viewModel.goToNextPage()
    }

    private func turnBack() {
        guard viewModel.canGoPrevious else { return }
        curlsNextSpread = true
        viewModel.goToPreviousPage()
    }

    // MARK: - Turning by hand

    /// How far a thumb travels on the touch surface to carry a page all the way over.
    ///
    /// The remote reports travel in large units — about half the surface's width carries
    /// a page over, so an ordinary swipe shows the whole curl rather than skipping it.
    private static let fullTurn: CGFloat = 1100

    private func handleSwipe(_ event: RemoteTouchSurface.Event) {
        switch event {
        case .moved(let travel):
            if swipe == nil {
                // Wait until it's clearly sideways, so a click or a resting thumb is nothing.
                guard abs(travel.x) > 14, abs(travel.x) > abs(travel.y) * 1.2, !curl.isActive else { return }
                let forward = travel.x < 0
                let byHand = beginCurl(forward: forward)
                swipe = (forward, byHand, false)
            }
            guard let current = swipe else { return }
            let along = current.forward ? -travel.x : travel.x
            if current.byHand {
                curl.drag(to: along / Self.fullTurn)
            } else if !current.turned, along > 160 {
                // Into another chapter: the next spread isn't laid out yet to curl by
                // hand, so the turn plays once the swipe is clearly meant.
                swipe?.turned = true
                current.forward ? turnForward() : turnBack()
            }

        case .pressed(let press):
            guard swipe == nil, !curl.isActive else { return }
            switch press {
            case .select: showControls()
            case .left: clickTurn(forward: false)
            case .right: clickTurn(forward: true)
            }

        case .ended(let travel, let velocity):
            defer { swipe = nil }
            guard let current = swipe, current.byHand else { return }
            let along = current.forward ? -travel.x : travel.x
            let speed = current.forward ? -velocity : velocity
            // Over halfway, or flicked the right way: it goes. Otherwise it settles back.
            let completes = curl.progress > 0.5 || (speed > 700 && along > 120)
            curl.release(completing: completes) { turned in
                if turned { landTurn(forward: current.forward) }
            }
        }
    }

    /// An edge click turns the page with the same curl, run by itself.
    private func clickTurn(forward: Bool) {
        guard !curl.isActive else { return }
        guard let pages = curlPages(forward: forward) else {
            forward ? turnForward() : turnBack()
            return
        }
        curl.play(pages, forward: forward) { landTurn(forward: forward) }
    }

    /// Starts a hand-held curl if the page being turned to is in this chapter.
    private func beginCurl(forward: Bool) -> Bool {
        guard let pages = curlPages(forward: forward) else { return false }
        curl.begin(pages, forward: forward)
        return true
    }

    /// The curl has carried the page over: show that spread underneath, then lift the
    /// curl off it once it's drawn.
    private func landTurn(forward: Bool) {
        curlsNextSpread = false
        forward ? viewModel.goToNextPage() : viewModel.goToPreviousPage()
        Task {
            // Into another chapter the book underneath changes once that chapter is in
            // place; lifting the curl before then showed the old chapter for a moment.
            for _ in 0..<50 where viewModel.paginatedChapterIndex != viewModel.currentChapterIndex {
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(60))
            curl.end()
        }
    }

    /// The four pages a turn needs — what stays put under it, and both sides of the page
    /// in the air — whether the turn stays in this chapter or crosses into the next.
    private func curlPages(forward: Bool) -> PageCurl.Pages? {
        guard let here = viewModel.spreadContent(at: viewModel.currentPageIndex),
              let there = viewModel.spreadContent(turning: forward),
              let currentLeft = pageImage(.left, of: here),
              let currentRight = pageImage(.right, of: here),
              let nextLeft = pageImage(.left, of: there),
              let nextRight = pageImage(.right, of: there)
        else { return nil }

        return forward
            ? PageCurl.Pages(left: currentLeft, right: nextRight, front: currentRight, back: nextLeft)
            : PageCurl.Pages(left: nextLeft, right: currentRight, front: currentLeft, back: nextRight)
    }

    private func pageImage(_ side: Side, of spread: ReaderViewModel.SpreadContent) -> CGImage? {
        // With the translations' version: a picture taken before Claude's English came
        // back would turn over a page with none.
        let key = "\(spreadToken)|\(theme.rawValue)|\(viewModel.renderStyle.cacheKey)|\(viewModel.renderStyle.margins)|\(viewModel.translationsVersion)|\(spread.chapterTitle)|\(spread.pageIndex)|\(side)"
        if let cached = pageImages[key] { return cached }
        guard bookSize.width > 0,
              let screen = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.screen }).first
        else { return nil }
        // Half the screen, edge to edge, with the page's text where it sits on screen:
        // the book is centred, so the margins outside it split evenly.
        let full = screen.bounds.size
        let sideMargin = max(0, (full.width - bookSize.width) / 2)
        let topMargin = max(0, (full.height - bookSize.height) / 2)
        let content = halfPage(side, of: spread)
            .frame(width: bookSize.width / 2, height: bookSize.height)
            .overlay(alignment: .bottomTrailing) {
                // The footer belongs to the right-hand page, so it turns with it.
                if side == .right {
                    pagesLeft(spread.pagesLeft)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(theme.textColor.opacity(0.4))
                        .padding(.trailing, ReaderLayout.horizontalPadding + viewModel.renderStyle.extraMargin)
                        .frame(height: ReaderLayout.bottomContentInset)
                }
            }
            .padding(side == .left ? .leading : .trailing, sideMargin)
            .padding(.vertical, topMargin)
        let size = CGSize(width: full.width / 2, height: full.height)
        guard let image = PageSnapshotter.image(of: content, size: size, background: theme.pageColor) else {
            return nil
        }
        pageImages[key] = image
        return image
    }

    /// Photographs the pages either side of this spread ahead of time — laying out the
    /// next chapter first, at a chapter's edge — so the first touch of a swipe lifts the
    /// page at once rather than after a pause.
    private func preparePageImages() async {
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled, !curl.isActive else { return }
        pageImages = pageImages.filter { $0.key.hasPrefix(spreadToken + "|") }
        viewModel.prepareNeighborChapter()
        await Task.yield()
        let spreads = [
            viewModel.spreadContent(at: viewModel.currentPageIndex),
            viewModel.spreadContent(turning: true),
            viewModel.spreadContent(turning: false)
        ].compactMap { $0 }
        for spread in spreads {
            for side in [Side.left, .right] {
                guard !Task.isCancelled, !curl.isActive else { return }
                _ = pageImage(side, of: spread)
                await Task.yield()
            }
        }
    }

    enum Side { case left, right }

    private var currentSpread: ReaderViewModel.SpreadContent? {
        viewModel.spreadContent(at: viewModel.currentPageIndex)
    }

    /// One page of the open book — the pager curls the right one over the spine.
    ///
    /// Side by side, the left page is the book and the right its translation. Otherwise
    /// each page is one column of the spread, set at exactly the width and position the
    /// paginator measured it at: the column's edge sits half a gutter from the spine.
    @ViewBuilder
    func halfPage(_ side: Side, of spread: ReaderViewModel.SpreadContent?) -> some View {
        if let spread {
            if viewModel.layoutMode == .sideBySide {
                if side == .left {
                    pageView(
                        columns: [spread.columns.first ?? []],
                        translated: nil,
                        isOriginal: true,
                        paragraphs: spread.paragraphs,
                        isFirstPage: spread.isFirstPage,
                        chapterTitle: spread.chapterTitle,
                        translatedChapterTitle: spread.translatedChapterTitle
                    )
                } else {
                    pageView(
                        columns: [spread.translatedPage],
                        translated: nil,
                        isOriginal: false,
                        paragraphs: [spread.translatedParagraphs],
                        isFirstPage: spread.isFirstPage,
                        chapterTitle: spread.chapterTitle,
                        translatedChapterTitle: spread.translatedChapterTitle
                    )
                }
            } else {
                let index = side == .left ? 0 : 1
                // PageView insets its column by the layout's padding and the style's margin;
                // sized like this, what's left is exactly the measured column.
                let inset = ReaderLayout.horizontalPadding + viewModel.renderStyle.extraMargin
                let pageWidth = viewModel.availableContentWidth + inset * 2
                let shift = inset - ReaderLayout.columnGutter / 2

                pageView(
                    columns: [spread.columns.indices.contains(index) ? spread.columns[index] : []],
                    translated: viewModel.layoutMode == .interleaved
                        ? [spread.translatedColumns.indices.contains(index) ? spread.translatedColumns[index] : []]
                        : nil,
                    isOriginal: true,
                    // Interleaved pages carry them too: a sentence split across columns
                    // draws its French clipped to the lines that fit.
                    paragraphs: [spread.paragraphs.indices.contains(index) ? spread.paragraphs[index] : []],
                    isFirstPage: spread.isFirstPage && index == 0,
                    chapterTitle: spread.chapterTitle,
                    translatedChapterTitle: spread.translatedChapterTitle
                )
                .frame(width: pageWidth)
                .offset(x: side == .left ? shift : -shift)
                .frame(maxWidth: .infinity, alignment: side == .left ? .trailing : .leading)
            }
        } else {
            Color.clear
        }
    }

    private func pageView(
        columns: [[String]],
        translated: [[String]]?,
        isOriginal: Bool,
        paragraphs: [[ReaderParagraph]]? = nil,
        isFirstPage: Bool,
        chapterTitle: String,
        translatedChapterTitle: String
    ) -> some View {
        PageView(
            columns: columns,
            paragraphs: paragraphs,
            translatedColumns: translated,
            layoutMode: viewModel.layoutMode,
            isOriginal: isOriginal,
            chapterTitle: chapterTitle,
            translatedChapterTitle: translatedChapterTitle,
            isFirstPage: isFirstPage,
            fontSize: viewModel.fontSize,
            theme: theme,
            style: viewModel.renderStyle,
            isTranslating: viewModel.isTranslatingPage,
            onTranslate: { _ in },
            onCopy: { _ in }
        )
    }

    // MARK: - Footer

    /// Books' only furniture while you read: how much of the chapter is left, small, under
    /// the right-hand page. Nothing above the text at all.
    private var runningHeads: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 28) {
                if viewModel.layoutMode.showsTranslation {
                    if let message = viewModel.translationErrorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .lineLimit(1)
                    } else if viewModel.isTranslatingPage {
                        Label("Translating with Claude…", systemImage: "sparkles")
                    } else if viewModel.isMissingTranslations {
                        Label("Part of this page wasn't translated", systemImage: "exclamationmark.triangle")
                    }
                }
                Spacer()
                pagesLeft(viewModel.pagesLeftInChapter)
            }
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(theme.textColor.opacity(0.4))
            .padding(.horizontal, ReaderLayout.horizontalPadding + viewModel.renderStyle.extraMargin)
            .frame(height: ReaderLayout.bottomContentInset)
        }
        .allowsHitTesting(false)
    }

    /// How much of the chapter is left after a page — on screen, and printed on the
    /// right-hand page in a turn's pictures so it travels with the page.
    private func pagesLeft(_ left: Int) -> some View {
        Text(left == 0 ? "Last page in chapter" : "^[\(left) page](inflect: true) left in chapter")
            .monospacedDigit()
    }

    // MARK: - Controls

    /// One click: the bar along the top — Library, Contents, Aa, and Ask — with Ask
    /// highlighted, so a second click is a question about the page. Aa is a swipe left.
    private func showControls() {
        chrome = .controls
        Task { focus = .ask }
    }

    private func showAppearance() {
        chrome = .appearance
        Task { focus = .panel }
    }

    /// Back peels one layer: a panel back to the bar, the bar back to the page.
    private func stepBack() {
        switch chrome {
        case .appearance:
            chrome = .controls
            Task { focus = .appearance }
        case .contents:
            chrome = .controls
            Task { focus = .contents }
        case .ask:
            chrome = .controls
            Task { focus = .ask }
        case .controls, .hidden:
            chrome = .hidden
            focus = .page
        }
    }

    private var controls: some View {
        // Each in the band the running heads give up, so the text stays fully readable
        // under the chrome — you can scrub and see exactly where you've landed.
        VStack(spacing: 0) {
            topBar
                .frame(height: ReaderLayout.topContentInset)
            Spacer()
            // Books puts nothing down here but where you are.
            Text("Page \(viewModel.currentPageIndex + 1) of \(max(1, viewModel.pages.count))  ·  \(viewModel.currentChapterTitle)")
                .lineLimit(1)
                .monospacedDigit()
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(theme.textColor.opacity(0.5))
                .frame(height: ReaderLayout.bottomContentInset)
        }
        .padding(.horizontal, ReaderLayout.horizontalPadding)
    }

    private var topBar: some View {
        HStack(spacing: 20) {
            chromeButton("Library", systemImage: "chevron.left", focus: .library) {
                dismiss()
            }
            chromeButton("Contents", systemImage: "list.bullet", iconOnly: true, focus: .contents) {
                chrome = .contents
            }
            chromeButton("Appearance", systemImage: "textformat.size", iconOnly: true, focus: .appearance) {
                showAppearance()
            }
            Spacer()
            // On its own at the right, across from the settings, where the bar opens.
            chromeButton("Ask", systemImage: "bubble.left.and.text.bubble.right", iconOnly: true, focus: .ask) {
                chrome = .ask
            }
        }
        // Centred on the screen, not between buttons of different widths — the same
        // centre line as the spread's gutter below it.
        .overlay {
            Text(book.title)
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(theme.textColor.opacity(0.8))
                .frame(maxWidth: 900)
                .allowsHitTesting(false)
        }
        .focusSection()
        .disabled(chrome == .hidden || isReadingAnswers)
    }

    private func chromeButton(
        _ title: String,
        systemImage: String,
        iconOnly: Bool = false,
        focus target: Focus,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if iconOnly {
                Image(systemName: systemImage)
                    .accessibilityLabel(title)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .buttonStyle(ChromeButtonStyle(theme: theme, isCircular: iconOnly))
        .focused($focus, equals: target)
    }

    // MARK: - Themes & Settings

    /// Books' Themes & Settings: size, light or dark, the six themes, then Customize —
    /// font, bold, spacing, margins, justification. Down the left under Aa, with the settings,
    /// leaving the right to Ask; the spread stays in view beside it, so every change shows
    /// on the page as you make it.
    private var appearancePanel: some View {
        HStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    Text("Themes & Settings")
                        .font(.system(size: 30, weight: .bold))
                    sizeRow
                    appearanceRow
                    themeGrid
                    customize
                    if book.needsTranslation || viewModel.hasAppleTranslations {
                        translationRows
                    }
                    Color.clear.frame(height: 1).id("panelEnd")
                }
                .padding(44)
            }
            #if DEBUG
            .task {
                guard TVDebugLaunch.scrollsPanel else { return }
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo("panelEnd", anchor: .bottom)
            }
            #endif
            }
            .frame(width: 760)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
            .focusSection()
            Spacer()
        }
        .padding(.horizontal, ReaderLayout.horizontalPadding)
        // Below the top bar, so Library and Contents stay in view and in reach.
        .padding(.top, ReaderLayout.topContentInset)
        .padding(.bottom, 20)
    }

    private var sizeIndex: Int {
        Self.fontSizes.lastIndex { $0 <= viewModel.fontSize } ?? 0
    }

    private var sizeRow: some View {
        HStack(spacing: 16) {
            Button {
                viewModel.fontSize = Self.fontSizes[max(0, sizeIndex - 1)]
            } label: {
                Text("A").font(.system(size: 28, design: .serif))
            }
            .disabled(sizeIndex == 0)
            .focused($focus, equals: .panel)
            .accessibilityLabel("Smaller text")

            // Where you are on the ladder, as Books marks it.
            HStack(spacing: 7) {
                ForEach(Self.fontSizes.indices, id: \.self) { index in
                    Circle()
                        .fill(Color.primary.opacity(index <= sizeIndex ? 0.75 : 0.18))
                        .frame(width: 9, height: 9)
                }
            }
            .fixedSize()
            .accessibilityHidden(true)

            Button {
                viewModel.fontSize = Self.fontSizes[min(Self.fontSizes.count - 1, sizeIndex + 1)]
            } label: {
                Text("A").font(.system(size: 44, design: .serif))
            }
            .disabled(sizeIndex == Self.fontSizes.count - 1)
            .accessibilityLabel("Larger text")
        }
        .buttonStyle(PanelButtonStyle(theme: theme))
    }

    /// Light, Dark, or Automatic — the Apple TV's own setting.
    private var appearanceRow: some View {
        HStack(spacing: 16) {
            ForEach(ReaderAppearance.allCases, id: \.self) { option in
                Button {
                    appearanceRaw = option.rawValue
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 30, weight: .medium))
                        Text(option.name)
                            .font(.system(size: 22, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .overlay(alignment: .topTrailing) {
                        if option == appearance {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22))
                                .padding(10)
                        }
                    }
                }
                .buttonStyle(PanelButtonStyle(theme: theme))
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(option == appearance ? .isSelected : [])
            }
        }
    }

    private var themeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 3), spacing: 20) {
            ForEach(BookTheme.families, id: \.self) { family in
                let option = family.appearance(dark: theme.isDark)
                Button {
                    viewModel.currentTheme = option
                } label: {
                    ThemeTile(theme: option, style: viewModel.themeStyles.style(for: option), isSelected: option == theme)
                }
                .buttonStyle(SwatchButtonStyle())
                .accessibilityLabel(family.name)
            }
        }
    }

    private var customize: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Customize")

            ForEach(ReaderFont.available, id: \.self) { font in
                Button {
                    viewModel.readingStyle.font = font
                } label: {
                    HStack {
                        Text(font.name)
                            .font(Font(font.platformFont(size: 28, weight: .regular, italic: false) as CTFont))
                        Spacer()
                        if viewModel.readingStyle.font == font {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(PanelButtonStyle(theme: theme, alignment: .leading))
            }

            toggleRow("Bold Text", isOn: viewModel.readingStyle.boldText) {
                viewModel.readingStyle.boldText.toggle()
            }

            stepRow("Line Spacing", value: \.lineSpacing)
            stepRow("Character Spacing", value: \.characterSpacing)
            stepRow("Word Spacing", value: \.wordSpacing)
            stepRow("Margins", value: \.margins)

            toggleRow("Justify Text", isOn: viewModel.readingStyle.justified) {
                viewModel.readingStyle.justified.toggle()
            }

            Button("Reset Theme") {
                viewModel.resetTheme()
            }
            .buttonStyle(PanelButtonStyle(theme: theme))
            .disabled(!viewModel.isThemeCustomized)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    private func toggleRow(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(isOn ? "On" : "Off")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(PanelButtonStyle(theme: theme, alignment: .leading))
    }

    /// Books uses a slider; on a remote, a slider is a row you click left and right on.
    private func stepRow(_ title: String, value: WritableKeyPath<ReadingStyle, Int>) -> some View {
        let current = viewModel.readingStyle[keyPath: value]
        return HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 28, weight: .medium))
            Spacer()
            Button {
                viewModel.readingStyle[keyPath: value] = max(0, current - 1)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(current == 0)
            .accessibilityLabel("Less \(title.lowercased())")

            HStack(spacing: 6) {
                ForEach(0..<ReadingStyle.steps, id: \.self) { step in
                    Capsule()
                        .fill(Color.primary.opacity(step <= current ? 0.75 : 0.18))
                        .frame(width: 18, height: 8)
                }
            }
            .fixedSize()
            .accessibilityHidden(true)

            Button {
                viewModel.readingStyle[keyPath: value] = min(ReadingStyle.steps - 1, current + 1)
            } label: {
                Image(systemName: "plus")
            }
            .disabled(current == ReadingStyle.steps - 1)
            .accessibilityLabel("More \(title.lowercased())")
        }
        .buttonStyle(PanelButtonStyle(theme: theme, compact: true))
        .padding(.leading, 28)
    }

    private var translationRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Translation")
            translationOption("Off", mode: .original)
            translationOption("Under Each Sentence", mode: .interleaved)
            translationOption("Side by Side", mode: .sideBySide)

            sectionHeader("Translated By")
            translatorOption(
                "Apple Translate",
                detail: viewModel.hasAppleTranslations ? "Sent from your Mac" : "Not sent from your Mac",
                translator: .apple
            )
            .disabled(!viewModel.hasAppleTranslations)
            translatorOption("Claude Haiku", detail: "Each page translated once, then kept", translator: .claude)
        }
    }

    private func translationOption(_ title: String, mode: LayoutMode) -> some View {
        Button {
            // Nothing came from the Mac, so a translation has to be Claude's.
            if mode.showsTranslation && !viewModel.hasAppleTranslations {
                viewModel.translator = .claude
            }
            viewModel.layoutMode = mode
        } label: {
            HStack {
                Text(title)
                Spacer()
                if viewModel.layoutMode == mode {
                    Image(systemName: "checkmark")
                }
            }
        }
        .buttonStyle(PanelButtonStyle(theme: theme, alignment: .leading))
    }

    /// Choosing who translates with translation off turns it on: that's what it's for.
    private func translatorOption(_ title: String, detail: String, translator: Translator) -> some View {
        Button {
            if !viewModel.layoutMode.showsTranslation { viewModel.layoutMode = .interleaved }
            viewModel.translator = translator
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text(detail)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
                Spacer()
                if viewModel.translator == translator && viewModel.layoutMode.showsTranslation {
                    Image(systemName: "checkmark")
                }
            }
        }
        .buttonStyle(PanelButtonStyle(theme: theme, alignment: .leading))
    }

    // MARK: - Ask

    private var askPanel: some View {
        HStack {
            Spacer()
            TVAskPanel(conversation: conversation, theme: theme, isReading: $isReadingAnswers) {
                viewModel.pageContext(for: book)
            }
        }
        .padding(.horizontal, ReaderLayout.horizontalPadding)
        // Below the top bar, as Themes & Settings sits.
        .padding(.top, ReaderLayout.topContentInset)
        .padding(.bottom, 20)
    }

    // MARK: - Contents

    /// Books' contents: a panel down the left, opened on the chapter you're in.
    private var contentsPanel: some View {
        HStack {
            TVContentsList(
                book: book,
                titles: viewModel.chapters.indices.map { index in
                    let title = viewModel.chapterTitle(at: index)
                    return title.isEmpty ? "Chapter \(index + 1)" : title
                },
                currentIndex: viewModel.currentChapterIndex,
                theme: theme
            ) { index in
                chrome = .hidden
                focus = .page
                guard index != viewModel.currentChapterIndex else { return }
                viewModel.navigatingForward = index > viewModel.currentChapterIndex
                viewModel.currentChapterIndex = index
                Task {
                    await viewModel.loadChapter(at: index, start: .beginning)
                    viewModel.saveProgress(book: book, modelContext: modelContext)
                }
            }
            .frame(width: 760)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
            .focusSection()
            Spacer()
        }
        .padding(.horizontal, ReaderLayout.horizontalPadding)
        .padding(.top, ReaderLayout.topContentInset)
        .padding(.bottom, 20)
    }
}

// MARK: - Pieces

/// The open book, turned with Books' page curl.
///
/// Two pages either side of a spine, double-sided: turning forward lifts the right-hand
/// page and lays it over the left, the next spread's left page printed on its back. The
/// pager's own touch gestures are left off (it has no data source) — they're built for
/// fingers on glass; the remote drives every turn, and this only animates them.
private struct CurlPager: UIViewControllerRepresentable {
    /// Identifies the spread on show; a new value is a new spread.
    let spread: String
    let forward: Bool
    /// Whether a new spread curls in, or just appears (a jump, a reflow).
    let curls: Bool
    let pageColor: Color
    let left: AnyView
    let right: AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.mid.rawValue)]
        )
        pager.isDoubleSided = true
        pager.view.backgroundColor = .clear
        context.coordinator.spread = spread
        pager.setViewControllers(context.coordinator.pages(left, right, pageColor), direction: .forward, animated: false)
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        guard spread != coordinator.spread else {
            // Same spread, new look (a theme): redraw the pages in place.
            coordinator.refresh(left, right, pageColor)
            return
        }
        coordinator.spread = spread
        coordinator.show(coordinator.pages(left, right, pageColor), in: pager, forward: forward, animated: curls)
    }

    @MainActor
    final class Coordinator {
        var spread = ""
        private var current: [UIHostingController<AnyView>] = []
        private var isTurning = false
        /// A turn asked for while one is still curling: the newest wins, once it lands.
        private var queued: (pages: [UIViewController], forward: Bool)?

        func pages(_ left: AnyView, _ right: AnyView, _ color: Color) -> [UIViewController] {
            current = [left, right].map { content in
                let host = UIHostingController(rootView: AnyView(content.background(color)))
                host.view.backgroundColor = UIColor(color)
                host.safeAreaRegions = []
                return host
            }
            return current
        }

        func refresh(_ left: AnyView, _ right: AnyView, _ color: Color) {
            guard current.count == 2 else { return }
            for (host, content) in zip(current, [left, right]) {
                host.rootView = AnyView(content.background(color))
                host.view.backgroundColor = UIColor(color)
            }
        }

        func show(_ pages: [UIViewController], in pager: UIPageViewController, forward: Bool, animated: Bool) {
            guard animated else {
                if isTurning {
                    queued = (pages, forward)
                } else {
                    pager.setViewControllers(pages, direction: forward ? .forward : .reverse, animated: false)
                }
                return
            }
            guard !isTurning else {
                queued = (pages, forward)
                return
            }
            isTurning = true
            pager.setViewControllers(pages, direction: forward ? .forward : .reverse, animated: true) { [weak self, weak pager] _ in
                guard let self else { return }
                self.isTurning = false
                if let next = self.queued, let pager {
                    self.queued = nil
                    self.show(next.pages, in: pager, forward: next.forward, animated: true)
                }
            }
        }
    }
}

/// Reads the Siri Remote's touch surface directly, so a page turns the way it would
/// under a finger.
///
/// The focus engine also reads swipes, but only reports one once the thumb has travelled
/// most of the surface and lifted — which is what made turning feel finicky. A pan
/// recognizer sees the thumb move from the first point, so a short, deliberate flick
/// turns the page the moment it's clearly a flick. Attached to the window, because the
/// remote's touches go to whatever holds focus and that's a SwiftUI view, not this one.
private struct RemoteTouchSurface: UIViewRepresentable {
    enum Press { case select, left, right }

    enum Event {
        /// A click: the centre of the clickpad, or its left or right edge.
        case pressed(Press)
        /// The thumb has moved this far from where it touched down, in the surface's points.
        case moved(CGPoint)
        /// It lifted: how far it went, and how fast it was moving sideways.
        case ended(CGPoint, velocity: CGFloat)
    }

    var isEnabled: Bool
    var onEvent: (Event) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        context.coordinator.onEvent = onEvent
        for recognizer in context.coordinator.recognizers {
            recognizer.isEnabled = isEnabled
        }
    }

    static func dismantleUIView(_ view: SurfaceView, coordinator: Coordinator) {
        for recognizer in coordinator.recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
    }

    final class SurfaceView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let coordinator else { return }
            for recognizer in coordinator.recognizers {
                recognizer.view?.removeGestureRecognizer(recognizer)
                window?.addGestureRecognizer(recognizer)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onEvent: (Event) -> Void = { _ in }
        private(set) lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            // Watch, don't take: focus, clicks and the menu button carry on as normal.
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delegate = self
            return pan
        }()

        private(set) lazy var clicks: [UITapGestureRecognizer] = [
            (UIPress.PressType.select, #selector(selected)),
            (.leftArrow, #selector(clickedLeft)),
            (.rightArrow, #selector(clickedRight))
        ].map { type, action in
            let tap = UITapGestureRecognizer(target: self, action: action)
            tap.allowedPressTypes = [NSNumber(value: type.rawValue)]
            tap.allowedTouchTypes = []
            tap.delegate = self
            return tap
        }

        var recognizers: [UIGestureRecognizer] { [pan] + clicks }

        @objc private func selected() { onEvent(.pressed(.select)) }
        @objc private func clickedLeft() { onEvent(.pressed(.left)) }
        @objc private func clickedRight() { onEvent(.pressed(.right)) }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            let travel = pan.translation(in: pan.view)
            switch pan.state {
            case .changed:
                onEvent(.moved(travel))
            case .ended, .cancelled, .failed:
                onEvent(.ended(travel, velocity: pan.velocity(in: pan.view).x))
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// A theme as Books shows it: a card in the theme's page colour, "Aa" set on it in the
/// reading font, and the theme's name beneath.
private struct ThemeTile: View {
    let theme: BookTheme
    let style: ReadingStyle
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text("Aa")
                .font(Font(style.font.platformFont(
                    size: 44,
                    weight: style.boldText ? .bold : .regular,
                    italic: false
                ) as CTFont))
            // Books names a theme the same in light and dark.
            Text(theme.family.name)
                .font(.system(size: 20, weight: .medium))
        }
        .foregroundStyle(theme.textColor)
        .frame(maxWidth: .infinity)
        .frame(height: 130)
        .background(theme.pageColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                              lineWidth: isSelected ? 5 : 1.5)
        }
    }
}

/// Reader chrome: quiet until focused, then lifted and filled in the theme's ink, so the
/// controls belong to the page rather than sitting on it as white system pills.
private struct ChromeButtonStyle: ButtonStyle {
    let theme: BookTheme
    var isCircular = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, theme: theme, isCircular: isCircular)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let theme: BookTheme
        let isCircular: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(isFocused ? theme.pageColor : theme.textColor.opacity(0.85))
                .padding(.horizontal, isCircular ? 0 : 30)
                .frame(width: isCircular ? 76 : nil, height: 76)
                .background {
                    Capsule().fill(isFocused ? theme.textColor : theme.textColor.opacity(0.08))
                }
                .scaleEffect(configuration.isPressed ? 0.96 : isFocused ? 1.08 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.25 : 0), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

/// Rows and keys inside the Aa panel.
struct PanelButtonStyle: ButtonStyle {
    let theme: BookTheme
    var alignment: Alignment = .center
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, alignment: alignment, compact: compact)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let alignment: Alignment
        let compact: Bool
        @Environment(\.isFocused) private var isFocused
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(isFocused ? Color.black : Color.primary)
                .padding(.horizontal, compact ? 0 : 28)
                .frame(width: compact ? 72 : nil, height: compact ? 64 : nil)
                .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 64 : 84, alignment: alignment)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(isFocused ? Color.white : Color.primary.opacity(0.08))
                }
                .opacity(isEnabled ? 1 : 0.35)
                .scaleEffect(configuration.isPressed ? 0.97 : isFocused ? 1.04 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.2 : 0), radius: 12, y: 6)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

private struct SwatchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.95 : isFocused ? 1.12 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

/// The table of contents, opened on the chapter you're reading.
private struct TVContentsList: View {
    let book: Book
    let titles: [String]
    let currentIndex: Int
    let theme: BookTheme
    let onSelect: (Int) -> Void

    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 24) {
                BookCover(book: book)
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(width: 84, height: 126)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(2)
                    Text(book.author)
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding([.top, .horizontal], 44)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(titles.indices, id: \.self) { index in
                            Button {
                                onSelect(index)
                            } label: {
                                HStack(spacing: 24) {
                                    Text(titles[index])
                                        .lineLimit(2)
                                    Spacer()
                                    if index == currentIndex {
                                        Text("Reading")
                                            .font(.system(size: 22, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(PanelButtonStyle(theme: theme, alignment: .leading))
                            .focused($focused, equals: index)
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 44)
                    .padding(.bottom, 44)
                }
                .onAppear {
                    proxy.scrollTo(currentIndex, anchor: .center)
                    focused = currentIndex
                }
            }
        }
    }
}
