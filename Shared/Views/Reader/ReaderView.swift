import SwiftUI
import SwiftData
import Translation
#if os(macOS)
import AppKit
#endif

/// Main reader view - now a thin coordinator using extracted components
struct ReaderView: View {
    let book: Book
    @Binding var navigationPath: NavigationPath
    
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ReaderViewModel()
    #if os(macOS)
    // The tutor keeps its own conversation, deliberately outside ReaderViewModel —
    // asking a question must never be able to move the reader's place in the book.
    @State private var tutor = TutorPanelModel()
    @State private var showTutor = false
    #endif
    
    #if os(macOS)
    @State private var eventMonitor: Any?
    #endif
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            readerSurface

            #if os(macOS)
            if showTutor {
                // Floats over the page rather than taking layout space. Taking space
                // would narrow the column and repaginate — dropping a two-column spread
                // to one — so the book would rearrange itself every time a question was
                // asked. The page stays exactly where it was; only this card appears.
                TutorPanel(
                    model: tutor,
                    theme: viewModel.currentTheme,
                    context: TutorContext(
                        bookTitle: book.title,
                        chapterTitle: viewModel.currentChapterTitle,
                        pageText: viewModel.currentPageContent.joined(separator: "\n\n")
                    ),
                    onClose: { withAnimation(.easeOut(duration: 0.2)) { showTutor = false } }
                )
                .frame(width: 380, height: 480)
                .padding(24)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
            #endif
        }
    }

    /// Both are no-ops off the Mac, so the toolbar can pass them unconditionally.
    private var isTutorVisible: Bool {
        #if os(macOS)
        showTutor
        #else
        false
        #endif
    }

    private func toggleTutor() {
        #if os(macOS)
        withAnimation(.easeOut(duration: 0.2)) { showTutor.toggle() }
        #endif
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
                GeometryReader { geometry in
                    ZStack {
                        // Beneath the text, so selecting a paragraph still beats paging.
                        tapZones(size: geometry.size)

                        pageSpread(geometry: geometry)
                            .id("\(viewModel.currentChapterIndex)-\(viewModel.currentPageIndex)")
                            .transition(.asymmetric(
                                insertion: .move(edge: viewModel.navigatingForward ? .trailing : .leading),
                                removal: .move(edge: viewModel.navigatingForward ? .leading : .trailing)
                            ))
                            .allowsHitTesting(!viewModel.isResizing)

                        // Frosted glass overlay during resize/translation. Decorative only —
                        // left hit-testable it would swallow every page tap for as long as
                        // a translation is in flight.
                        if viewModel.isResizing || viewModel.translationService.isTranslating {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .ignoresSafeArea()
                                .allowsHitTesting(false)
                                .transition(.opacity.animation(.easeOut(duration: 0.2)))
                        }

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
                    .gesture(swipeGesture)
                    // One pipe for all geometry, `initial: true` included. The old shape —
                    // onAppear assigning viewSize directly, onChange diffing against it —
                    // is what let fullscreen render pages built for a 1200×800 window:
                    // the assignment made the later diff look like "no change".
                    .onChange(of: geometry.size, initial: true) { _, newSize in
                        viewModel.reconcileSize(newSize)
                    }
                    .onAppear {
                        DisplaySleepPreventer.shared.preventSleep()
                        // Show the controls on arrival, then get out of the way — Books
                        // settles to a bare page a moment after a book opens. Previously
                        // only the Mac did this, so on iPad the toolbar and scrubber sat
                        // over the text for the whole session.
                        viewModel.noteChromeActivity()
                    }
                    #if os(macOS)
                    // Mac has a pointer, so it can tell "reading" from "reaching for a
                    // control" without being asked. Any movement brings the chrome back.
                    .onContinuousHover { phase in
                        if case .active = phase { viewModel.noteChromeActivity() }
                    }
                    #endif
                }
            }
        }
        .preferredColorScheme(viewModel.currentTheme.colorScheme)
        #if os(macOS)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden)
        .onAppear {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard !viewModel.showTOC, !viewModel.showThemeSettings else {
                    return event
                }
                
                if event.keyCode == 123 { // Left Arrow
                    viewModel.goToPreviousPage()
                    return nil
                } else if event.keyCode == 124 { // Right Arrow
                    viewModel.goToNextPage()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
        #else
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(isPresented: $viewModel.showTOC) {
            TOCSheet(
                tableOfContents: viewModel.tableOfContents,
                chapters: viewModel.chapters,
                currentChapterIndex: viewModel.currentChapterIndex,
                onSelect: { idx in
                    if viewModel.currentChapterIndex != idx {
                        viewModel.currentChapterIndex = idx
                        Task { await viewModel.loadChapter(at: idx, start: .beginning) }
                        viewModel.saveProgress(book: book, modelContext: modelContext)
                    }
                    viewModel.showTOC = false
                },
                onDismiss: { viewModel.showTOC = false }
            )
        }
        .translationPresentation(isPresented: $viewModel.showSystemTranslation, text: viewModel.textToTranslate)
        .translationTask(viewModel.translationService.configuration) { session in
            await viewModel.translationService.performTranslation(using: session)
            viewModel.handleTranslationComplete()
        }
        .task { await viewModel.loadBook(book: book) }
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
        .onDisappear {
            viewModel.ttsService.stop()
            viewModel.speechService.stopListening()
            viewModel.saveProgress(book: book, modelContext: modelContext)
            DisplaySleepPreventer.shared.allowSleep()
        }
    }
    
    // MARK: - Chrome

    /// Toolbar on top, scrubber on the bottom, both fading together — and a hairline of
    /// progress left behind when they're gone.
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
                onShowTOC: { viewModel.showTOC = true },
                isReading: viewModel.ttsService.isPlaying,
                onToggleRead: { viewModel.toggleReading() },
                isListening: viewModel.speechService.isListening,
                onToggleListening: { viewModel.speechService.toggleListening() },
                showThemeSettings: $viewModel.showThemeSettings,
                isTutorVisible: isTutorVisible,
                onToggleTutor: toggleTutor
            )
            .popover(isPresented: $viewModel.showThemeSettings, arrowEdge: .top) {
                ThemeSettings(
                    fontSize: $viewModel.fontSize,
                    currentTheme: $viewModel.currentTheme,
                    layoutMode: $viewModel.layoutMode
                )
            }
            // A view at opacity 0 still catches clicks, so hidden chrome would quietly
            // eat every tap along the top and bottom edges.
            .opacity(viewModel.isChromeVisible ? 1 : 0)
            .allowsHitTesting(viewModel.isChromeVisible)

            Spacer(minLength: 0)

            ZStack(alignment: .bottom) {
                ReaderScrubber(
                    currentPage: viewModel.currentPageIndex,
                    totalPages: viewModel.pages.count,
                    bookProgress: viewModel.bookProgress,
                    pagesLeftInChapter: viewModel.pagesLeftInChapter,
                    theme: viewModel.currentTheme,
                    onScrub: { viewModel.goToPage($0) }
                )
                .background(viewModel.currentTheme.pageColor.opacity(0.9))
                .opacity(viewModel.isChromeVisible ? 1 : 0)
                .allowsHitTesting(viewModel.isChromeVisible)

                // Swaps in as the chrome leaves, so there's always *something* saying
                // where you are. Books shows a single quiet line at the foot of the page
                // — a count, not a progress bar — and nothing else.
                Text(
                    viewModel.pagesLeftInChapter == 0
                        ? "Last page in this chapter"
                        : "^[\(viewModel.pagesLeftInChapter) page](inflect: true) left in this chapter"
                )
                .font(.footnote)
                .foregroundStyle(viewModel.currentTheme.textColor.opacity(0.45))
                .padding(.bottom, 14)
                .opacity(viewModel.isChromeVisible ? 0 : 1)
            }
        }
    }

    /// Three invisible regions: page back, toggle/nothing, page forward.
    ///
    /// Sits *below* the text in the ZStack so `textSelection` on a paragraph wins; only
    /// clicks in the margins land here.
    private func tapZones(size: CGSize) -> some View {
        HStack(spacing: 0) {
            // .contentShape *after* .frame — applied before, it would describe the hit
            // area of an unsized view.
            Color.clear
                .frame(width: size.width * 0.15)
                .contentShape(Rectangle())
                .onTapGesture { viewModel.goToPreviousPage() }
                .accessibilityLabel("Previous page")
                .accessibilityAddTraits(.isButton)

            // Mac reveals chrome by moving the pointer, so the middle has nothing to do
            // there — and a no-op tap target is just something else to hit.
            #if os(iOS)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { viewModel.toggleChrome() }
                .accessibilityLabel("Show or hide controls")
            #else
            Color.clear
            #endif

            Color.clear
                .frame(width: size.width * 0.15)
                .contentShape(Rectangle())
                .onTapGesture { viewModel.goToNextPage() }
                .accessibilityLabel("Next page")
                .accessibilityAddTraits(.isButton)
        }
    }

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

    @ViewBuilder
    private func pageSpread(geometry: GeometryProxy) -> some View {
        if viewModel.layoutMode == .interleaved {
            interleavedSpread(width: geometry.size.width)
        } else {
            #if os(iOS)
            let isLandscape = geometry.size.width > geometry.size.height
            if isLandscape {
                horizontalSpread(width: geometry.size.width)
            } else {
                verticalSpread(height: geometry.size.height)
            }
            #else
            horizontalSpread(width: geometry.size.width)
            #endif
        }
    }
    
    private func interleavedSpread(width: CGFloat) -> some View {
        PageView(
            columns: viewModel.currentPageColumns,
            translatedColumns: viewModel.translatedColumns,
            layoutMode: viewModel.layoutMode,
            isOriginal: true,
            chapterTitle: viewModel.currentChapterTitle,
            translatedChapterTitle: viewModel.translatedChapterTitle,
            isFirstPage: viewModel.currentPageIndex == 0,
            fontSize: viewModel.fontSize,
            theme: viewModel.currentTheme,
            isTranslating: viewModel.translationService.isTranslating,
            onTranslate: { text in
                viewModel.textToTranslate = text
                viewModel.showSystemTranslation = true
            },
            onCopy: { Clipboard.copy($0) }
        )
        .frame(width: width)
    }
    
    private func horizontalSpread(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            PageView(
                columns: [viewModel.currentPageContent],
                isOriginal: true,
                chapterTitle: viewModel.currentChapterTitle,
                translatedChapterTitle: viewModel.translatedChapterTitle,
                isFirstPage: viewModel.currentPageIndex == 0,
                fontSize: viewModel.fontSize,
                theme: viewModel.currentTheme,
                isTranslating: viewModel.translationService.isTranslating,
                onTranslate: { text in
                    viewModel.textToTranslate = text
                    viewModel.showSystemTranslation = true
                },
                onCopy: { Clipboard.copy($0) }
            )
            .frame(width: width / 2)

            PageView(
                columns: [viewModel.translatedPage],
                isOriginal: false,
                chapterTitle: viewModel.currentChapterTitle,
                translatedChapterTitle: viewModel.translatedChapterTitle,
                isFirstPage: viewModel.currentPageIndex == 0,
                fontSize: viewModel.fontSize,
                theme: viewModel.currentTheme,
                isTranslating: viewModel.translationService.isTranslating,
                onTranslate: { _ in },
                onCopy: { Clipboard.copy($0) }
            )
            .frame(width: width / 2)
        }
    }
    
    #if os(iOS)
    private func verticalSpread(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            PageView(
                columns: [viewModel.currentPageContent],
                isOriginal: true,
                chapterTitle: viewModel.currentChapterTitle,
                translatedChapterTitle: viewModel.translatedChapterTitle,
                isFirstPage: viewModel.currentPageIndex == 0,
                fontSize: viewModel.fontSize,
                theme: viewModel.currentTheme,
                isTranslating: viewModel.translationService.isTranslating,
                onTranslate: { text in
                    viewModel.textToTranslate = text
                    viewModel.showSystemTranslation = true
                },
                onCopy: { Clipboard.copy($0) }
            )
            .frame(height: height / 2)

            Divider()

            PageView(
                columns: [viewModel.translatedPage],
                isOriginal: false,
                chapterTitle: viewModel.currentChapterTitle,
                translatedChapterTitle: viewModel.translatedChapterTitle,
                isFirstPage: viewModel.currentPageIndex == 0,
                fontSize: viewModel.fontSize,
                theme: viewModel.currentTheme,
                isTranslating: viewModel.translationService.isTranslating,
                onTranslate: { _ in },
                onCopy: { Clipboard.copy($0) }
            )
            .frame(height: height / 2)
        }
    }
    #endif
    
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                if horizontal > 60 {
                    viewModel.goToPreviousPage()
                } else if horizontal < -60 {
                    viewModel.goToNextPage()
                }
            }
    }
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

#if os(macOS)
import IOKit.pwr_mgt
#endif

/// A utility to prevent the display from sleeping while the app is actively reading.
@MainActor
final class DisplaySleepPreventer {
    static let shared = DisplaySleepPreventer()
    
    #if os(macOS)
    private var assertionID: IOPMAssertionID = 0
    private var isPreventing = false
    #endif
    
    func preventSleep() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #elseif os(macOS)
        guard !isPreventing else { return }
        
        let reasonForActivity = "Reading Book in LingoBook" as CFString
        var newAssertionID: IOPMAssertionID = 0
        
        let success = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonForActivity,
            &newAssertionID
        )
        
        if success == kIOReturnSuccess {
            assertionID = newAssertionID
            isPreventing = true
        }
        #endif
    }
    
    func allowSleep() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #elseif os(macOS)
        guard isPreventing else { return }
        
        IOPMAssertionRelease(assertionID)
        isPreventing = false
        #endif
    }
}
