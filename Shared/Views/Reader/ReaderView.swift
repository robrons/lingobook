import SwiftUI
import SwiftData
import Translation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Main reader view - now a thin coordinator using extracted components
struct ReaderView: View {
    let book: Book
    @Binding var navigationPath: NavigationPath

    init(book: Book, navigationPath: Binding<NavigationPath>) {
        self.book = book
        _navigationPath = navigationPath
        // Open in the book's own theme, in the light or dark the appearance setting asks
        // for, from the very first frame — not a bright page that turns dark on load.
        let viewModel = ReaderViewModel()
        let saved = BookTheme(rawValue: book.savedThemeName) ?? .calm
        viewModel.currentTheme = ReaderAppearance.current.theme(saved)
        _viewModel = State(initialValue: viewModel)
    }

    /// Light, Dark, or following the device — for every book, as in Books.
    @AppStorage(ReaderAppearance.key) private var appearanceRaw = ReaderAppearance.automatic.rawValue
    private var appearance: ReaderAppearance { ReaderAppearance(rawValue: appearanceRaw) ?? .automatic }

    /// Puts the theme on the page in the light or dark the appearance setting calls for.
    private func applyAppearance() {
        let themed = appearance.theme(viewModel.currentTheme)
        if themed != viewModel.currentTheme { viewModel.currentTheme = themed }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: ReaderViewModel
    @State private var eventMonitor: Any?
    /// Ask's conversation about the chapter. Kept while the panel is closed, so a question
    /// can be picked up again after reading on.
    @State private var conversation = AskConversation()
    @State private var showAsk = false
    /// A page being turned by hand, as on Apple TV — and as Books turned them on iPad.
    @State private var curl = PageCurl()
    @State private var turner = PageTurner()
    /// Pictures of pages, kept for the page on show so a turn starts without a wait.
    @State private var pageImages: [String: CGImage] = [:]
    /// The page area's size: the curl's pictures are taken at it.
    @State private var pageSize: CGSize = .zero
    #if os(macOS)
    @State private var scrollMonitor: Any?
    #endif
    
    var body: some View {
        readerSurface
    }

    private var readerSurface: some View {
        ZStack {
            viewModel.currentTheme.pageColor
                .ignoresSafeArea()

            if let message = viewModel.loadError {
                loadFailure(message: message)
            } else {
                // The page area is now the whole window. Chrome floats on top of it as
                // overlays rather than sitting in a VStack beside it — if it took part in
                // layout, every fade in and out would resize the page and repaginate the
                // chapter under the reader's eyes.
                //
                // Ask is the exception: it sits beside the page, not over it, so opening it
                // narrows the page once — like resizing the window — and hides nothing.
                HStack(spacing: 0) {
                    GeometryReader { geometry in
                        ZStack {
                            readingPage(geometry: geometry)

                            // Frosted glass overlay during resize/translation. Decorative only —
                            // left hit-testable it would swallow every page tap for as long as
                            // a translation is in flight.
                            if viewModel.isResizing || viewModel.isTranslatingPage {
                                Rectangle()
                                    .fill(.ultraThinMaterial)
                                    .ignoresSafeArea()
                                    .allowsHitTesting(false)
                                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
                            }

                            panels

                            chrome

                            // Also floats: anything taking up layout space here would shift the
                            // text the paginator already measured and clip the tail of the page.
                            if let message = viewModel.translationErrorMessage {
                                VStack {
                                    Spacer()
                                    TranslationErrorNotice(
                                        message: message,
                                        theme: viewModel.currentTheme,
                                        onRetry: { viewModel.retryTranslation() }
                                    )
                                    .padding(.bottom, ReaderLayout.chromeBottomInset + 16)
                                }
                                .transition(.opacity)
                            }
                        }
                        .gesture(handTurn)
                        // One pipe for all geometry, `initial: true` included. The old shape —
                        // onAppear assigning viewSize directly, onChange diffing against it —
                        // is what let fullscreen render pages built for a 1200×800 window:
                        // the assignment made the later diff look like "no change".
                        .onChange(of: geometry.size, initial: true) { _, newSize in
                            pageSize = newSize
                            viewModel.reconcileSize(newSize)
                        }
                        .onAppear {
                            CurlRenderer.warmUp()
                            DisplaySleepPreventer.shared.preventSleep()
                            // iPad controls stay until the reader taps the page to hide them.
                            viewModel.noteChromeActivity()
                        }
                        // Mac has a pointer, so it can tell "reading" from "reaching for a
                        // control" without being asked. Any movement brings the chrome back.
                        .onContinuousHover { phase in
                            if case .active = phase { viewModel.noteChromeActivity() }
                        }
                        // A pointer parked over a paragraph is the one piece of chrome that
                        // never faded. It goes when the rest of the chrome does and comes
                        // back the instant the mouse moves — AppKit restores it itself, so
                        // there is no state here to get out of step with the real cursor.
                        .onChange(of: viewModel.isChromeVisible) { _, visible in
                            #if os(macOS)
                            NSCursor.setHiddenUntilMouseMoves(!visible)
                            #endif
                        }
                    }

                    if showAsk {
                        AskPanel(
                            conversation: conversation,
                            theme: viewModel.currentTheme,
                            context: { viewModel.pageContext(for: book) },
                            onClose: { showAsk = false }
                        )
                        .transition(.move(edge: .trailing))
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: viewModel.showTOC)
        .animation(.easeOut(duration: 0.25), value: viewModel.showThemeSettings)
        .preferredColorScheme(viewModel.currentTheme.colorScheme)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden)
        #if os(macOS)
        .onAppear {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard !viewModel.showTOC, !viewModel.showThemeSettings else {
                    // Escape puts a panel away, as Back does on the TV.
                    if event.keyCode == 53 {
                        closePanels()
                        return nil
                    }
                    return event
                }
                // Typing in Ask: the arrows move the caret, not the page.
                if NSApp.keyWindow?.firstResponder is NSText {
                    return event
                }

                if event.keyCode == 123 { // Left Arrow
                    playTurn(forward: false)
                    return nil
                } else if event.keyCode == 124 { // Right Arrow
                    playTurn(forward: true)
                    return nil
                }
                return event
            }
            // Two fingers across the trackpad lift the page and carry it over.
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                handleScroll(event)
            }
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }
        #endif
        .translationPresentation(isPresented: $viewModel.showSystemTranslation, text: viewModel.textToTranslate)
        .translationTask(viewModel.translationService.configuration) { session in
            await viewModel.translationService.performTranslation(using: session)
            viewModel.handleTranslationComplete()
        }
        .task {
            await viewModel.loadBook(book: book)
            applyAppearance()
        }
        .task(id: imageToken) { await preparePageImages() }
        // Voice commands and reading aloud turn pages with the curl too.
        .onAppear { viewModel.turnsByRequest = true }
        .onChange(of: viewModel.turnRequest) { _, request in
            guard let request else { return }
            playTurn(forward: request.forward, isAutoTurn: request.isAutoTurn)
        }
        #if DEBUG
        // `-LBAutoTurns n` turns n pages forward with the curl, one every 1.5 seconds;
        // `-LBPanel aa|contents` opens a panel. As on Apple TV, for checking the reader.
        .task {
            let defaults = UserDefaults.standard
            try? await Task.sleep(for: .seconds(2))
            switch defaults.string(forKey: "LBPanel") {
            case "aa": viewModel.showThemeSettings = true
            case "contents": viewModel.showTOC = true
            default: break
            }
            for _ in 0..<defaults.integer(forKey: "LBAutoTurns") {
                try? await Task.sleep(for: .seconds(1.5))
                playTurn(forward: true)
            }
        }
        #endif
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
        .onChange(of: viewModel.themeStyles) { _, _ in
            viewModel.saveProgress(book: book, modelContext: modelContext)
        }
        .onChange(of: appearanceRaw) { _, _ in applyAppearance() }
        // Automatic follows the device, which can switch at sunset with the book open.
        .task(id: appearanceRaw) {
            guard appearance == .automatic else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                applyAppearance()
            }
        }
        #if os(macOS)
        // The Mac says when it switches, so Automatic needn't wait for the next check.
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name("AppleInterfaceThemeChangedNotification")
        )) { _ in
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                applyAppearance()
            }
        }
        #endif
        .onChange(of: viewModel.layoutMode) { _, _ in
            viewModel.saveProgress(book: book, modelContext: modelContext)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                applyAppearance()
                DisplaySleepPreventer.shared.preventSleep()
            } else {
                viewModel.saveProgress(book: book, modelContext: modelContext)
                viewModel.ttsService.stop()
                viewModel.speechService.stopListening()
                DisplaySleepPreventer.shared.allowSleep()
            }
        }
        .onDisappear {
            #if os(macOS)
            NSCursor.setHiddenUntilMouseMoves(false)
            #endif
            viewModel.cancelChromeHide()
            conversation.stop()
            viewModel.ttsService.stop()
            viewModel.speechService.stopListening()
            viewModel.saveProgress(book: book, modelContext: modelContext)
            DisplaySleepPreventer.shared.allowSleep()
        }
    }
    
    // MARK: - Chrome

    private func readingPage(geometry: GeometryProxy) -> some View {
        ZStack {
            #if os(macOS)
            tapZones(size: geometry.size)
            #else
            Color.clear
            #endif

            if let spread = viewModel.spreadContent(at: viewModel.currentPageIndex) {
                spreadView(spread, width: geometry.size.width, live: true)
                    .allowsHitTesting(!viewModel.isResizing)
            }

            // The whole page area: the page being turned is the whole page. Kept in place
            // between turns rather than built for each one, so a swipe lifts the page the
            // instant the fingers move.
            PageCurlView(curl: curl, paper: viewModel.currentTheme.pageColor)
                .opacity(curl.isActive ? 1 : 0)
                .allowsHitTesting(false)
        }
        #if os(iOS)
        .contentShape(Rectangle())
        // Keep this on the page layer. Taps on the toolbar or arrows must never
        // toggle their own visibility or accidentally trigger another action.
        .simultaneousGesture(TapGesture().onEnded { viewModel.toggleReadingControls() })
        #endif
    }

    /// The TV's chrome: the bar along the top, fading when the pointer settles; at the
    /// foot, how much of the chapter is left while reading, and where you are while the
    /// bar is up.
    private var chrome: some View {
        VStack(spacing: 0) {
            ReaderToolbar(
                bookTitle: book.title,
                theme: viewModel.currentTheme,
                onBack: {
                    viewModel.ttsService.stop()
                    viewModel.saveProgress(book: book, modelContext: modelContext)
                    goBack()
                },
                isContentsOpen: viewModel.showTOC,
                onToggleContents: {
                    let open = !viewModel.showTOC
                    closePanels()
                    viewModel.showTOC = open
                },
                isReading: viewModel.ttsService.isPlaying,
                onToggleRead: {
                    #if os(iOS)
                    viewModel.speechService.stopListening()
                    #endif
                    viewModel.toggleReading()
                },
                isListening: viewModel.speechService.isListening,
                onToggleListening: {
                    #if os(iOS)
                    viewModel.ttsService.stop()
                    viewModel.isAutoReading = false
                    #endif
                    viewModel.speechService.toggleListening()
                },
                isAskOpen: showAsk,
                onToggleAsk: { showAsk.toggle() },
                isSettingsOpen: viewModel.showThemeSettings,
                onToggleSettings: {
                    let open = !viewModel.showThemeSettings
                    closePanels()
                    viewModel.showThemeSettings = open
                }
            )
            // A view at opacity 0 still catches clicks, so hidden chrome would quietly
            // eat every tap along the top and bottom edges.
            .opacity(viewModel.isChromeVisible ? 1 : 0)
            .allowsHitTesting(viewModel.isChromeVisible)
            .accessibilityHidden(!viewModel.isChromeVisible)

            Spacer(minLength: 0)

            #if os(iOS)
            HStack(spacing: 16) {
                pageButton("Previous page", symbol: "chevron.left", enabled: viewModel.canGoPrevious) {
                    playTurn(forward: false)
                }
                Spacer(minLength: 0)
                footer
                Spacer(minLength: 0)
                pageButton("Next page", symbol: "chevron.right", enabled: viewModel.canGoNext) {
                    playTurn(forward: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            #else
            footer
                .frame(height: ReaderLayout.chromeBottomInset)
            #endif
        }
    }

    /// Books' only furniture while you read: how much of the chapter is left, small, under
    /// the right-hand page. With the bar up, where you are instead.
    private var footer: some View {
        ZStack {
            Text(
                viewModel.pagesLeftInChapter == 0
                    ? "Last page in chapter"
                    : "^[\(viewModel.pagesLeftInChapter) page](inflect: true) left in chapter"
            )
            .monospacedDigit()
            #if os(macOS)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, ReaderLayout.horizontalPadding + viewModel.renderStyle.extraMargin)
            #endif
            .opacity(viewModel.isChromeVisible ? 0 : 1)

            Text(pagePosition)
                .lineLimit(1)
                .monospacedDigit()
                .padding(.horizontal, ReaderLayout.horizontalPadding)
                .opacity(viewModel.isChromeVisible ? 1 : 0)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(viewModel.currentTheme.textColor.opacity(0.45))
        // While a page is in the air the footer would float over it.
        .opacity(curl.isActive ? 0 : 1)
        .allowsHitTesting(false)
    }

    private var pagePosition: String {
        let title = viewModel.currentChapterTitle
        let page = "Page \(viewModel.currentPageIndex + 1) of \(max(1, viewModel.pages.count))"
        return title.isEmpty ? page : "\(page)  ·  \(title)"
    }

    // MARK: - Panels

    /// Contents down the left, Themes & Settings down the right, as on Apple TV — over
    /// the page, below the bar, the text still in view beside them.
    @ViewBuilder
    private var panels: some View {
        if viewModel.showTOC || viewModel.showThemeSettings {
            // A click anywhere else puts the panel away.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { closePanels() }
        }
        if viewModel.showTOC {
            HStack {
                TOCSheet(
                    book: book,
                    titles: viewModel.chapters.indices.map { index in
                        let title = viewModel.chapterTitle(at: index)
                        return title.isEmpty ? "Chapter \(index + 1)" : title
                    },
                    currentIndex: viewModel.currentChapterIndex,
                    theme: viewModel.currentTheme
                ) { index in
                    closePanels()
                    guard index != viewModel.currentChapterIndex else { return }
                    viewModel.navigatingForward = index > viewModel.currentChapterIndex
                    viewModel.currentChapterIndex = index
                    Task {
                        await viewModel.loadChapter(at: index, start: .beginning)
                        viewModel.saveProgress(book: book, modelContext: modelContext)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, ReaderLayout.topContentInset)
            .padding(.bottom, 20)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
        if viewModel.showThemeSettings {
            HStack(alignment: .top) {
                Spacer(minLength: 0)
                ThemeSettings(
                    fontSize: $viewModel.fontSize,
                    currentTheme: $viewModel.currentTheme,
                    layoutMode: $viewModel.layoutMode,
                    readingStyle: $viewModel.readingStyle,
                    themeStyles: viewModel.themeStyles,
                    isThemeCustomized: viewModel.isThemeCustomized,
                    onResetTheme: { viewModel.resetTheme() },
                    needsTranslation: book.needsTranslation
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, ReaderLayout.topContentInset)
            .padding(.bottom, 20)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func closePanels() {
        viewModel.showTOC = false
        viewModel.showThemeSettings = false
        viewModel.noteChromeActivity()
    }

    #if os(iOS)
    private func pageButton(_ label: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 44)
                .foregroundStyle(viewModel.currentTheme.textColor)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || viewModel.isLoadingChapter || viewModel.isResizing)
        .opacity(viewModel.isChromeVisible ? (enabled ? 1 : 0.3) : 0)
        .allowsHitTesting(viewModel.isChromeVisible)
        .accessibilityHidden(!viewModel.isChromeVisible)
        .accessibilityLabel(label)
        .accessibilityIdentifier(label == "Next page" ? "reader.nextPage" : "reader.previousPage")
    }
    #endif

    /// Three invisible regions: page back, toggle/nothing, page forward.
    ///
    /// Sits *below* the text in the ZStack so `textSelection` on a paragraph wins; only
    /// clicks in the margins land here.
    #if os(macOS)
    private func tapZones(size: CGSize) -> some View {
        HStack(spacing: 0) {
            // .contentShape *after* .frame — applied before, it would describe the hit
            // area of an unsized view.
            Color.clear
                .frame(width: size.width * 0.15)
                .contentShape(Rectangle())
                .onTapGesture { playTurn(forward: false) }
                .accessibilityLabel("Previous page")
                .accessibilityAddTraits(.isButton)

            // Mac reveals chrome by moving the pointer, so the middle has nothing to do
            // there — and a no-op tap target is just something else to hit.
            Color.clear

            Color.clear
                .frame(width: size.width * 0.15)
                .contentShape(Rectangle())
                .onTapGesture { playTurn(forward: true) }
                .accessibilityLabel("Next page")
                .accessibilityAddTraits(.isButton)
        }
    }
    #endif

    // MARK: - Failure State

    /// Shown instead of the spread when the EPUB can't be opened at all.
    private func loadFailure(message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't Open This Book", systemImage: "book.closed")
        } description: {
            Text(message)
        } actions: {
            Button("Back to Library") { goBack() }
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(viewModel.currentTheme.textColor)
    }

    private func goBack() {
        guard !navigationPath.isEmpty else { return }
        navigationPath.removeLast()
    }

    // MARK: - Page Spread

    /// One spread — the page on show, or one a turn is about to reveal, for its picture.
    /// The same view either way, so the curl lifts exactly the page that was on screen.
    @ViewBuilder
    private func spreadView(_ spread: ReaderViewModel.SpreadContent, width: CGFloat, live: Bool) -> some View {
        if viewModel.layoutMode == .sideBySide {
            HStack(spacing: 0) {
                pageView(
                    columns: [spread.columns.first ?? []],
                    paragraphs: [spread.paragraphs.first ?? []],
                    translated: nil,
                    isOriginal: true,
                    spread: spread,
                    live: live
                )
                .frame(width: width / 2)

                pageView(
                    columns: [spread.translatedPage],
                    paragraphs: [spread.translatedParagraphs],
                    translated: nil,
                    isOriginal: false,
                    spread: spread,
                    live: live
                )
                .frame(width: width / 2)
            }
        } else {
            pageView(
                columns: spread.columns,
                paragraphs: spread.paragraphs,
                translated: spread.translatedColumns,
                isOriginal: true,
                spread: spread,
                live: live
            )
            .frame(width: width)
        }
    }

    private func pageView(
        columns: [[String]],
        paragraphs: [[ReaderParagraph]],
        translated: [[String]]?,
        isOriginal: Bool,
        spread: ReaderViewModel.SpreadContent,
        live: Bool
    ) -> some View {
        PageView(
            columns: columns,
            paragraphs: paragraphs,
            translatedColumns: translated,
            layoutMode: viewModel.layoutMode,
            isOriginal: isOriginal,
            chapterTitle: spread.chapterTitle,
            translatedChapterTitle: spread.translatedChapterTitle,
            isFirstPage: spread.isFirstPage,
            fontSize: viewModel.fontSize,
            theme: viewModel.currentTheme,
            style: viewModel.renderStyle,
            isTranslating: live && viewModel.isTranslatingPage,
            onTranslate: { text in
                guard isOriginal else { return }
                viewModel.textToTranslate = text
                viewModel.showSystemTranslation = true
            },
            onCopy: { Clipboard.copy($0) }
        )
    }

    // MARK: - Turning pages

    /// Which spread is on screen, and everything its picture depends on.
    private var imageToken: String {
        let style = viewModel.renderStyle
        return [
            "\(viewModel.paginatedChapterIndex)-\(viewModel.currentPageIndex)-\(viewModel.layoutVersion)",
            viewModel.currentTheme.rawValue, style.cacheKey, "\(style.margins)",
            "\(Int(pageSize.width))x\(Int(pageSize.height))",
            // Translations arrive after the page does, and its picture must carry them.
            "\(viewModel.translatedPage.hashValue)|\(viewModel.translatedChapterTitle.hashValue)|\(viewModel.translationsVersion)"
        ].joined(separator: "|")
    }

    /// How far a hand travels to carry a page all the way over.
    private var fullTurn: CGFloat {
        #if os(macOS)
        // Trackpad travel, in points: a comfortable two-finger sweep, not the whole pad.
        450
        #else
        max(200, pageSize.width / 2)
        #endif
    }

    /// The hand has moved this far since it went down, in the direction the fingers went:
    /// leftward brings the next page in, as a page moves under a finger.
    private func dragTurn(by travel: CGSize) {
        if turner.swipe == nil {
            // Wait until it's clearly sideways, so a resting finger or a scroll is nothing.
            guard abs(travel.width) > 8, abs(travel.width) > abs(travel.height) * 1.2,
                  !curl.isActive, !viewModel.isResizing, !viewModel.isLoadingChapter else { return }
            let forward = travel.width < 0
            turner.swipe = .init(forward: forward, byHand: beginCurl(forward: forward))
        }
        guard let swipe = turner.swipe else { return }
        let along = swipe.forward ? -travel.width : travel.width
        if swipe.byHand {
            curl.drag(to: along / fullTurn)
        } else if !swipe.turned, along > 80 {
            // At a chapter's edge with the next one not yet laid out: turn once it's meant.
            turner.swipe?.turned = true
            swipe.forward ? viewModel.goToNextPage() : viewModel.goToPreviousPage()
        }
    }

    /// The hand has lifted, moving at `speed` points a second in the fingers' direction.
    private func endTurn(travel: CGSize, speed: CGFloat) {
        defer { turner.swipe = nil }
        guard let swipe = turner.swipe, swipe.byHand else { return }
        let along = swipe.forward ? -travel.width : travel.width
        let toward = swipe.forward ? -speed : speed
        // Over halfway, or flicked the right way: it goes. Otherwise it settles back.
        // Judged by where the hand put it, not where the drawn page has caught up to.
        let completes = along / fullTurn > 0.5 || (toward > 350 && along > 30)
        curl.release(completing: completes) { turned in
            if turned { landTurn(forward: swipe.forward) }
        }
    }

    /// A click, a tap, an arrow key, a voice command or reading aloud turns the page with
    /// the same curl, run by itself.
    private func playTurn(forward: Bool, isAutoTurn: Bool = false) {
        guard !curl.isActive, turner.swipe == nil else { return }
        guard forward ? viewModel.canGoNext : viewModel.canGoPrevious else { return }
        guard !viewModel.isResizing, let pages = curlPages(forward: forward) else {
            forward ? viewModel.goToNextPage(isAutoTurn: isAutoTurn) : viewModel.goToPreviousPage()
            return
        }
        curl.play(pages, forward: forward) { landTurn(forward: forward, isAutoTurn: isAutoTurn) }
    }

    private func beginCurl(forward: Bool) -> Bool {
        guard forward ? viewModel.canGoNext : viewModel.canGoPrevious,
              let pages = curlPages(forward: forward) else { return false }
        curl.begin(pages, forward: forward)
        return true
    }

    /// The curl has carried the page over: show that spread underneath, then lift the
    /// curl off it once it's drawn.
    private func landTurn(forward: Bool, isAutoTurn: Bool = false) {
        forward ? viewModel.goToNextPage(isAutoTurn: isAutoTurn) : viewModel.goToPreviousPage()
        Task {
            // Into another chapter the page underneath changes once that chapter is in
            // place; lifting the curl before then showed the old chapter for a moment.
            for _ in 0..<50 where viewModel.paginatedChapterIndex != viewModel.currentChapterIndex {
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(60))
            curl.end()
        }
    }

    /// The four pages a turn needs — what stays put under it, and both sides of the page
    /// in the air — whether the turn stays in this chapter or crosses into the next. The
    /// page area is a spread cut at its middle, where two columns meet.
    private func curlPages(forward: Bool) -> PageCurl.Pages? {
        guard let here = viewModel.spreadContent(at: viewModel.currentPageIndex),
              let there = viewModel.spreadContent(turning: forward),
              let current = pageImage(of: here),
              let next = pageImage(of: there),
              let currentLeft = PageSnapshotter.half(current, right: false),
              let currentRight = PageSnapshotter.half(current, right: true),
              let nextLeft = PageSnapshotter.half(next, right: false),
              let nextRight = PageSnapshotter.half(next, right: true)
        else { return nil }

        return forward
            ? PageCurl.Pages(left: currentLeft, right: nextRight, front: currentRight, back: nextLeft)
            : PageCurl.Pages(left: nextLeft, right: currentRight, front: currentLeft, back: nextRight)
    }

    /// A picture is good for as long as what's on its page and how it's set are the same.
    /// Keyed by those, not by the page on show — so a translation arriving for one page
    /// doesn't throw away the pictures of the others, to be taken again mid-swipe.
    private func imageKey(of spread: ReaderViewModel.SpreadContent) -> String {
        let style = viewModel.renderStyle
        var hasher = Hasher()
        hasher.combine(spread.columns)
        hasher.combine(spread.translatedColumns)
        hasher.combine(spread.translatedPage)
        hasher.combine(spread.translatedChapterTitle)
        hasher.combine(spread.paragraphs.map { $0.map { "\($0.lineLimit ?? 0)|\($0.indented)" } })
        return [
            spread.chapterTitle, "\(spread.pageIndex)", "\(hasher.finalize())",
            viewModel.layoutMode.rawValue, "\(viewModel.fontSize)",
            viewModel.currentTheme.rawValue, style.cacheKey, "\(style.margins)",
            "\(Int(pageSize.width))x\(Int(pageSize.height))"
        ].joined(separator: "|")
    }

    private func pageImage(of spread: ReaderViewModel.SpreadContent) -> CGImage? {
        let key = imageKey(of: spread)
        if let cached = pageImages[key] { return cached }
        guard pageSize.width > 0, pageSize.height > 0,
              let image = PageSnapshotter.image(
                of: spreadView(spread, width: pageSize.width, live: false),
                size: pageSize,
                background: viewModel.currentTheme.pageColor
              )
        else { return nil }
        pageImages[key] = image
        #if DEBUG && os(macOS)
        // `-LBDumpCurl YES`: each picture a turn is made from, in the app's temp folder.
        if UserDefaults.standard.bool(forKey: "LBDumpCurl") {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "curl-\(spread.pageIndex).png")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
        #endif
        return image
    }

    /// Photographs the pages either side of this one ahead of time — laying out the next
    /// chapter first, at a chapter's edge — so the first touch of a swipe lifts the page
    /// at once rather than after a pause.
    private func preparePageImages() async {
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, !curl.isActive, viewModel.isInitialLoadComplete else { return }
        viewModel.prepareNeighborChapter()
        await Task.yield()
        let spreads = [
            viewModel.spreadContent(at: viewModel.currentPageIndex),
            viewModel.spreadContent(turning: true),
            viewModel.spreadContent(turning: false)
        ].compactMap { $0 }
        // Keep only what a turn from here could use.
        let wanted = Set(spreads.map(imageKey))
        pageImages = pageImages.filter { wanted.contains($0.key) }
        for spread in spreads {
            guard !Task.isCancelled, !curl.isActive else { return }
            _ = pageImage(of: spread)
            await Task.yield()
        }
    }

    /// A finger on iPad, or a click-and-drag on the Mac, carries the page over too.
    private var handTurn: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in dragTurn(by: value.translation) }
            .onEnded { value in endTurn(travel: value.translation, speed: value.velocity.width) }
    }

    #if os(macOS)
    /// Two-finger swipes on the trackpad, read as they happen so the page follows them.
    ///
    /// A trackpad says almost nothing about speed as the fingers lift — a flick arrives
    /// afterwards, as momentum. So the page rides the momentum, as content would: a
    /// flick carries it over, a slow drag that stops short lets it settle back. Anything
    /// over the Ask panel, or mostly vertical, is left for whatever is under the pointer.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard event.hasPreciseScrollingDeltas else { return event }
        // Fingers' own direction, whatever the scrolling preference.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let delta = CGSize(width: event.scrollingDeltaX * sign, height: event.scrollingDeltaY * sign)

        if !event.momentumPhase.isEmpty {
            guard turner.isCoasting else { return turner.swallowsMomentum ? nil : event }
            turner.sawMomentum = true
            turner.travel.width += delta.width
            dragTurn(by: turner.travel)
            let along = (turner.swipe?.forward ?? true) ? -turner.travel.width : turner.travel.width
            if along / fullTurn > 0.6 || event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                finishCoasting()
            }
            return nil
        }

        switch event.phase {
        case .began:
            if turner.isCoasting { finishCoasting() }
            turner.swallowsMomentum = false
            guard !viewModel.showTOC, !viewModel.showThemeSettings,
                  event.window === NSApp.mainWindow,
                  event.locationInWindow.x < pageSize.width else {
                turner.isTracking = false
                return event
            }
            turner.isTracking = true
            turner.travel = delta
            return event
        case .changed:
            guard turner.isTracking else { return event }
            turner.travel.width += delta.width
            turner.travel.height += delta.height
            dragTurn(by: turner.travel)
            if turner.swipe == nil, abs(turner.travel.height) > 16 {
                // A vertical scroll: not ours.
                turner.isTracking = false
            }
            return turner.swipe == nil ? event : nil
        case .ended, .cancelled:
            guard turner.isTracking else { return event }
            turner.isTracking = false
            guard turner.swipe != nil else { return event }
            turner.swallowsMomentum = true
            guard turner.swipe?.byHand == true else {
                turner.swipe = nil
                return nil
            }
            // Wait a moment for momentum; if none comes, the fingers simply stopped.
            turner.isCoasting = true
            turner.sawMomentum = false
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                if turner.isCoasting, !turner.sawMomentum { finishCoasting() }
            }
            return nil
        default:
            return event
        }
    }

    private func finishCoasting() {
        guard turner.isCoasting else { return }
        turner.isCoasting = false
        endTurn(travel: turner.travel, speed: 0)
    }
    #endif
}

/// Where a turn by hand has got to. A class, so the trackpad monitor's closure and the
/// view see the same one.
@MainActor
private final class PageTurner {
    struct Swipe {
        var forward: Bool
        /// Whether the curl follows the hand, or the turn just happens once it's meant.
        var byHand: Bool
        var turned = false
    }

    var swipe: Swipe?
    #if os(macOS)
    var isTracking = false
    /// The fingers have lifted and the page is riding the trackpad's momentum.
    var isCoasting = false
    var sawMomentum = false
    var swallowsMomentum = false
    var travel: CGSize = .zero
    #endif
}

/// Inline notice for a translation failure.
///
/// Deliberately unobtrusive: the source text is still perfectly readable when the
/// translation isn't, so this reports and offers a retry without taking over the page.
private struct TranslationErrorNotice: View {
    let message: String
    let theme: BookTheme
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Translation unavailable")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.textColor)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(theme.textColor.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.textColor.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 24)
    }
}

#Preview {
    ReaderView(
        book: Book(title: "Le Comte de Monte-Cristo", author: "Alexandre Dumas", epubData: Data()),
        navigationPath: .constant(NavigationPath())
    )
    .modelContainer(for: Book.self, inMemory: true)
}
