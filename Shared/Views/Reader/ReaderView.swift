import SwiftUI
import SwiftData
import Translation
import AppKit

/// Main reader view - now a thin coordinator using extracted components
struct ReaderView: View {
    let book: Book
    @Binding var navigationPath: NavigationPath
    
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ReaderViewModel()
    // The tutor keeps its own conversation, deliberately outside ReaderViewModel —
    // asking a question must never be able to move the reader's place in the book.
    @State private var tutor = TutorPanelModel()
    @State private var showTutor = false
    @State private var dictation = DictationService()
    @State private var pushToTalkMonitor: Any?
    
    @State private var eventMonitor: Any?
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            readerSurface

            if showTutor {
                // Floats over the page rather than taking layout space. Taking space
                // would narrow the column and repaginate — dropping a two-column spread
                // to one — so the book would rearrange itself every time a question was
                // asked. The page stays exactly where it was; only this card appears.
                TutorPanel(
                    model: tutor,
                    theme: viewModel.currentTheme,
                    context: tutorContext,
                    briefing: tutorBriefing,
                    onClose: { withAnimation(.easeOut(duration: 0.2)) { showTutor = false } },
                    listeningStatus: dictationStatus,
                    onSpeak: { viewModel.ttsService.speak($0) },
                    isSpeaking: viewModel.ttsService.isPlaying,
                    onStopSpeaking: { viewModel.ttsService.stop() },
                    onChooseModelFolder: modelFolderPicker
                )
                .onAppear {
                    installPushToTalk()
                    // Warm the speech model now rather than at the moment the key is
                    // held: the first load downloads a few hundred megabytes, and
                    // discovering that mid-sentence would lose the sentence.
                    Task { await dictation.prepare() }
                    // Checked on open so "Ollama isn't running" is on screen before a
                    // question is wasted on finding it out.
                    Task { await tutor.refreshEngineState() }
                }
                // One model serves the tutor and the chapter summariser, and the reader
                // is the one waiting. Background work stands aside for a live question.
                .onChange(of: tutor.isResponding) { _, isResponding in
                    viewModel.storySummarizer.isPaused = isResponding
                    // An answer just loaded the weights, or just failed to; either way
                    // the previous reading is now stale.
                    if !isResponding { Task { await tutor.refreshEngineState() } }
                }
                .onDisappear {
                    removePushToTalk()
                    // Closing the panel mid-answer would otherwise leave the summariser
                    // paused for the rest of the session.
                    viewModel.storySummarizer.isPaused = false
                }
                // Height is the panel's own business — it collapses to a title bar
                // when minimised.
                .frame(width: 380)
                .padding(24)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
    }

    /// Only offered while a download is actually pending — pointing at a folder is
    /// pointless once the weights are loaded.
    private var modelFolderPicker: (() -> Void)? {
        guard dictation.state == .preparing, dictation.willDownload else { return nil }
        return chooseModelFolder
    }

    private var dictationStatus: String? {
        switch dictation.state {
        case .listening: "Listening — release space to send"
        case .transcribing: "Transcribing…"
        // The first run fetches a few hundred megabytes with no progress to report,
        // which looks identical to a hang unless the wait is named. Every run after
        // that just reads the same files off disk, and saying "460 MB" there would
        // promise a wait that isn't coming.
        case .preparing: dictation.willDownload
            ? "Fetching the speech model — one time, ~460 MB…"
            : "Warming up the speech model…"
        case .idle: nil
        }
    }

    /// Lets the reader point at weights another app already downloaded.
    ///
    /// The sandbox hides the shared Application Support folder from this app, so the
    /// same 460MB would otherwise be fetched a second time. An open panel runs outside
    /// the sandbox and hands back a folder the app is then allowed to read.
    private func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the “parakeet-tdt-0.6b-v3-coreml” folder to reuse those weights."
        panel.prompt = "Use This Folder"
        // Sandboxed, NSHomeDirectory() is the container — the panel needs the real one.
        panel.directoryURL = URL(
            fileURLWithPath: "/Users/\(NSUserName())/Library/Application Support/FluidAudio/Models"
        )

        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await dictation.useModelFolder(folder) }
    }

    /// Hold-to-talk on the space bar.
    ///
    /// A local event monitor rather than SwiftUI's `onKeyPress`, because the panel
    /// would have to hold keyboard focus for that — and focus belongs to the text
    /// field, which needs the space bar for spaces. The monitor sees the key first and
    /// steps aside whenever a text view is editing, so typing is never intercepted.
    private func installPushToTalk() {
        guard pushToTalkMonitor == nil else { return }

        pushToTalkMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            let space = 49
            // Space talks when there is nothing typed, and types a space once there
            // is. Stepping aside for *any* focused text field — the first version —
            // meant it never fired at all, because the composer normally holds focus.
            let composerIsBusy = isEditingText && !tutor.draft.isEmpty
            guard event.keyCode == space, showTutor, !composerIsBusy else { return event }

            if event.type == .keyDown {
                // Held keys repeat; only the first press starts recording.
                guard !event.isARepeat else { return nil }
                dictation.startListening()
            } else {
                Task {
                    let heard = await dictation.stopListeningAndTranscribe()
                    guard !heard.isEmpty else { return }
                    tutor.draft = heard
                    tutor.send(context: tutorContext)
                }
            }
            return nil
        }
    }

    private func removePushToTalk() {
        if let pushToTalkMonitor { NSEvent.removeMonitor(pushToTalkMonitor) }
        pushToTalkMonitor = nil
        dictation.cancel()
    }

    /// True while a text field has the keyboard, so space means "space".
    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    private var tutorContext: TutorContext {
        TutorContext(
            bookTitle: book.title,
            bookAuthor: book.author,
            chapterTitle: viewModel.currentChapterTitle,
            pageText: viewModel.currentPageContent.joined(separator: "\n\n"),
            pageID: "\(viewModel.currentChapterIndex)-\(viewModel.currentPageIndex)",
            position: readingPosition,
            outline: chapterOutline,
            language: book.language,
            about: book.aboutBlock,
            // Only the chapters behind the reader. A recap is worthless if it spoils the
            // book, and this is where that guarantee is made.
            storySoFar: viewModel.storySummarizer.storySoFar(before: viewModel.currentChapterIndex)
        )
    }

    /// Everything that has to be in place before the tutor is at its best, itemised.
    private var tutorBriefing: TutorBriefing {
        TutorBriefing(items: [engineItem, backgroundItem, storyItem, dictationItem])
    }

    /// The one that matters most: without Ollama there are no answers at all.
    private var engineItem: TutorBriefing.Item {
        let (state, detail): (TutorBriefing.Item.State, String) = switch tutor.engineState {
        case .checking:   (.working, "Checking…")
        case .notRunning: (.blocked, "Ollama isn't running — start it with “brew services start ollama”")
        case .modelMissing: (.blocked, "Run “ollama pull \(Ollama.defaultModel)”")
        case .cold:       (.ready, "\(Ollama.defaultModel) installed — first answer loads it into memory")
        case .warm:       (.ready, "\(Ollama.defaultModel) loaded and ready")
        }
        return .init(id: "engine", title: "Local model", detail: detail, state: state)
    }

    private var backgroundItem: TutorBriefing.Item {
        let (state, detail): (TutorBriefing.Item.State, String)
        if !TutorSettings.wikipediaLookupEnabled {
            (state, detail) = (.off, "Wikipedia lookup is off in Settings")
        } else if book.aboutBlock != nil {
            let both = book.aboutBook != nil && book.aboutAuthor != nil
            (state, detail) = (.ready, both
                ? "Wikipedia on this book and on \(book.author)"
                : "Wikipedia on \(book.aboutBook != nil ? "this book" : book.author)")
        } else if GroundingMonitor.shared.isFetching(book.id) {
            (state, detail) = (.working, "Reading up on this book…")
        } else if GroundingMonitor.shared.couldNotReachWikipedia(book.id) {
            (state, detail) = (.blocked, "Couldn't reach Wikipedia — reopening the book retries")
        } else if book.groundingAttemptedAt != nil {
            // Final, and it has to say so, or the reader waits for something that is
            // never coming.
            (state, detail) = (.blocked, "No article matched this book — nothing more is loading")
        } else {
            (state, detail) = (.working, "Starting…")
        }
        return .init(id: "background", title: "Book background", detail: detail, state: state)
    }

    private var storyItem: TutorBriefing.Item {
        let summarizer = viewModel.storySummarizer
        let remembered = summarizer.rememberedChapters
        let finished = viewModel.currentChapterIndex

        let (state, detail): (TutorBriefing.Item.State, String)
        if let writing = summarizer.writingChapter {
            (state, detail) = (.working, "Writing up chapter \(writing + 1)…"
                + (summarizer.queuedChapters > 0 ? " \(summarizer.queuedChapters) queued" : ""))
        } else if remembered > 0 {
            (state, detail) = (.ready, "Notes on \(remembered) of \(max(finished, remembered)) finished chapters")
        } else if finished == 0 {
            (state, detail) = (.ready, "Nothing to recap yet — notes start after your first chapter")
        } else {
            (state, detail) = (.blocked, "No chapter notes yet — “what's happened so far?” has only this page")
        }
        return .init(id: "story", title: "Story so far", detail: detail, state: state)
    }

    private var dictationItem: TutorBriefing.Item {
        let (state, detail): (TutorBriefing.Item.State, String) = switch dictation.state {
        case .preparing: (.working, dictation.willDownload
            ? "Fetching the speech model — one time, ~460 MB"
            : "Warming up the speech model")
        case .listening, .transcribing: (.ready, "Listening")
        case .idle: (.ready, "Hold space to speak")
        }
        return .init(id: "dictation", title: "Dictation", detail: detail, state: state)
    }

    private var readingPosition: String {
        let total = viewModel.chapters.count
        guard total > 0 else { return "position unknown" }
        let current = viewModel.currentChapterIndex + 1
        let percent = Int((Double(current) / Double(total) * 100).rounded())
        return "chapter \(current) of \(total), about \(percent)% through the book"
    }

    /// A window of the table of contents around the reader.
    ///
    /// Windowed rather than complete because this book has hundreds of chapters, and
    /// the whole list would crowd out the page itself in the model's context. What is
    /// just behind and a good way ahead is enough to answer "where do I skip to?",
    /// which is the question the full list would have been for.
    private var chapterOutline: String {
        let titles: [String] = viewModel.tableOfContents.isEmpty
            ? viewModel.chapters.map(\.title)
            : viewModel.tableOfContents.map(\.label)

        guard !titles.isEmpty else { return "(not available for this book)" }

        let current = min(viewModel.currentChapterIndex, titles.count - 1)
        let start = max(0, current - 2)
        let end = min(titles.count - 1, current + 25)

        var lines: [String] = []
        if start > 0 { lines.append("  … \(start) earlier chapter\(start == 1 ? "" : "s")") }

        for index in start...end {
            let marker = index == current ? "▸" : " "
            lines.append("\(marker) \(index + 1). \(titles[index])")
        }

        let remaining = titles.count - 1 - end
        if remaining > 0 { lines.append("  … \(remaining) more chapter\(remaining == 1 ? "" : "s") after this") }

        return lines.joined(separator: "\n")
    }

    private func toggleTutor() {
        withAnimation(.easeOut(duration: 0.2)) { showTutor.toggle() }
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
                        // settles to a bare page a moment after a book opens.
                        viewModel.noteChromeActivity()
                    }
                    // Mac has a pointer, so it can tell "reading" from "reaching for a
                    // control" without being asked. Any movement brings the chrome back.
                    .onContinuousHover { phase in
                        if case .active = phase { viewModel.noteChromeActivity() }
                    }
                }
            }
        }
        .preferredColorScheme(viewModel.currentTheme.colorScheme)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden)
        .onAppear {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard !viewModel.showTOC, !viewModel.showThemeSettings else {
                    return event
                }

                // The shortcut the toolbar button has advertised in its tooltip all
                // along, and which nothing had ever actually implemented.
                if event.modifierFlags.contains([.command, .shift]),
                   event.charactersIgnoringModifiers?.lowercased() == "t" {
                    toggleTutor()
                    return nil
                }

                // Arrows move the caret when there's a question being typed. Without
                // this, reaching back to fix a word in the composer turns the page.
                guard !isEditingText else { return event }

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
        .task {
            await viewModel.loadBook(book: book, modelContext: modelContext)
            // Covers the whole existing library: a book imported before any of this
            // simply grounds itself the first time it's opened.
            BookGrounding.groundIfNeeded(book, modelContext: modelContext)
        }
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
            viewModel.storySummarizer.stop()
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
                isTutorVisible: showTutor,
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
            Color.clear

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
            horizontalSpread(width: geometry.size.width)
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

import IOKit.pwr_mgt

/// A utility to prevent the display from sleeping while the app is actively reading.
@MainActor
final class DisplaySleepPreventer {
    static let shared = DisplaySleepPreventer()
    
    private var assertionID: IOPMAssertionID = 0
    private var isPreventing = false
    
    func preventSleep() {
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
    }
    
    func allowSleep() {
        guard isPreventing else { return }
        
        IOPMAssertionRelease(assertionID)
        isPreventing = false
    }
}
