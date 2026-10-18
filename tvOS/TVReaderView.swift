import SwiftUI
import SwiftData

/// The reader, driven by the Siri Remote.
///
/// Left and right turn pages, Play/Pause reads aloud, clicking the touch surface brings
/// up the controls, and Back closes them — or the book, when they're already closed.
/// Translations come only from what the Mac sent; nothing here can make new ones.
struct TVReaderView: View {
    let book: Book

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = ReaderViewModel()
    @State private var showControls = false
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case page
        case control(Control)
    }

    private enum Control: Hashable {
        case contents, readAloud, smaller, larger, theme, layout
    }

    private static let fontRange: ClosedRange<CGFloat> = 24...56

    var body: some View {
        ZStack {
            viewModel.currentTheme.pageColor
                .ignoresSafeArea()

            if let message = viewModel.loadError {
                ContentUnavailableView {
                    Label("Couldn't Open This Book", systemImage: "book.closed")
                } description: {
                    Text(message)
                }
                .foregroundStyle(viewModel.currentTheme.textColor)
            } else {
                page
                footer
                if showControls {
                    controls
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(viewModel.currentTheme.colorScheme)
        .toolbar(.hidden, for: .navigationBar)
        // Back closes the controls first; with them closed, nil hands Back to the
        // navigation stack, which returns to the library.
        .onExitCommand(perform: showControls ? { hideControls() } : nil)
        .sheet(isPresented: $viewModel.showTOC) { contentsList }
        .task {
            await viewModel.loadBook(book: book)
            focus = .page
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                DisplaySleepPreventer.shared.preventSleep()
            } else {
                viewModel.saveProgress(book: book, modelContext: modelContext)
                viewModel.ttsService.stop()
                DisplaySleepPreventer.shared.allowSleep()
            }
        }
        .onDisappear {
            viewModel.ttsService.stop()
            viewModel.saveProgress(book: book, modelContext: modelContext)
            DisplaySleepPreventer.shared.allowSleep()
        }
    }

    // MARK: - Page

    private var page: some View {
        GeometryReader { geometry in
            spread(width: geometry.size.width)
                .id("\(viewModel.currentChapterIndex)-\(viewModel.currentPageIndex)")
                .transition(.asymmetric(
                    insertion: .move(edge: viewModel.navigatingForward ? .trailing : .leading),
                    removal: .move(edge: viewModel.navigatingForward ? .leading : .trailing)
                ))
                .opacity(viewModel.isResizing ? 0.4 : 1)
                .onChange(of: geometry.size, initial: true) { _, newSize in
                    viewModel.reconcileSize(newSize)
                }
        }
        // The page itself holds focus while reading, so the remote talks to it.
        .focusable(!showControls)
        .focused($focus, equals: .page)
        .focusEffectDisabled()
        // Swipe the way you would on a touchscreen: swiping left pulls the next page in.
        .onMoveCommand { direction in
            switch direction {
            case .right where viewModel.canGoPrevious:
                withAnimation(.easeInOut(duration: 0.3)) { viewModel.goToPreviousPage() }
            case .left where viewModel.canGoNext:
                withAnimation(.easeInOut(duration: 0.3)) { viewModel.goToNextPage() }
            default:
                break
            }
        }
        .onPlayPauseCommand { viewModel.toggleReading() }
        .onTapGesture { showControlsPanel() }
    }

    @ViewBuilder
    private func spread(width: CGFloat) -> some View {
        if viewModel.layoutMode == .interleaved {
            pageView(
                columns: viewModel.currentPageColumns,
                translated: viewModel.translatedColumns,
                isOriginal: true
            )
            .frame(width: width)
        } else {
            HStack(spacing: 0) {
                pageView(columns: [viewModel.currentPageContent], translated: nil, isOriginal: true)
                    .frame(width: width / 2)
                pageView(columns: [viewModel.translatedPage], translated: nil, isOriginal: false)
                    .frame(width: width / 2)
            }
        }
    }

    private func pageView(columns: [[String]], translated: [[String]]?, isOriginal: Bool) -> some View {
        PageView(
            columns: columns,
            translatedColumns: translated,
            layoutMode: viewModel.layoutMode,
            isOriginal: isOriginal,
            chapterTitle: viewModel.currentChapterTitle,
            translatedChapterTitle: viewModel.translatedChapterTitle,
            isFirstPage: viewModel.currentPageIndex == 0,
            fontSize: viewModel.fontSize,
            theme: viewModel.currentTheme,
            isTranslating: false,
            onTranslate: { _ in },
            onCopy: { _ in }
        )
    }

    /// Where you are, and a hint at the remote. Stays put so it never moves the text.
    private var footer: some View {
        VStack {
            Spacer()
            HStack(spacing: 24) {
                Text(viewModel.currentChapterTitle)
                    .lineLimit(1)
                Spacer()
                if viewModel.isMissingTranslations {
                    Label("Part of this page wasn't translated", systemImage: "exclamationmark.triangle")
                }
                if viewModel.ttsService.isPlaying {
                    Label("Reading aloud", systemImage: "speaker.wave.2.fill")
                }
                Text(
                    viewModel.pagesLeftInChapter == 0
                        ? "Last page in this chapter"
                        : "^[\(viewModel.pagesLeftInChapter) page](inflect: true) left in this chapter"
                )
                .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(viewModel.currentTheme.textColor.opacity(0.45))
            .padding(.horizontal, ReaderLayout.horizontalPadding)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Controls

    private func showControlsPanel() {
        withAnimation(.easeOut(duration: 0.2)) { showControls = true }
        focus = .control(.readAloud)
    }

    private func hideControls() {
        withAnimation(.easeOut(duration: 0.2)) { showControls = false }
        focus = .page
    }

    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: 32) {
                controlButton(.contents, "Contents", "list.bullet") {
                    viewModel.showTOC = true
                }
                controlButton(
                    .readAloud,
                    viewModel.ttsService.isPlaying ? "Stop Reading" : "Read Aloud",
                    viewModel.ttsService.isPlaying ? "stop.fill" : "play.fill"
                ) {
                    viewModel.toggleReading()
                    hideControls()
                }
                controlButton(.smaller, "Smaller", "textformat.size.smaller") {
                    viewModel.fontSize = max(Self.fontRange.lowerBound, viewModel.fontSize - 2)
                }
                .disabled(viewModel.fontSize <= Self.fontRange.lowerBound)
                controlButton(.larger, "Larger", "textformat.size.larger") {
                    viewModel.fontSize = min(Self.fontRange.upperBound, viewModel.fontSize + 2)
                }
                .disabled(viewModel.fontSize >= Self.fontRange.upperBound)
                controlButton(.theme, viewModel.currentTheme.name, "paintpalette") {
                    let themes = BookTheme.allCases
                    let next = (themes.firstIndex(of: viewModel.currentTheme).map { $0 + 1 } ?? 0) % themes.count
                    viewModel.currentTheme = themes[next]
                }
                controlButton(
                    .layout,
                    viewModel.layoutMode == .interleaved ? "Side by Side" : "Interleaved",
                    viewModel.layoutMode == .interleaved ? "rectangle.split.2x1" : "text.alignleft"
                ) {
                    viewModel.layoutMode = viewModel.layoutMode == .interleaved ? .sideBySide : .interleaved
                }
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .focusSection()
            .padding(.bottom, 40)
        }
    }

    private func controlButton(
        _ control: Control,
        _ title: String,
        _ systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .focused($focus, equals: .control(control))
    }

    // MARK: - Contents

    private var contentsList: some View {
        NavigationStack {
            List(viewModel.chapters.indices, id: \.self) { index in
                Button {
                    viewModel.showTOC = false
                    hideControls()
                    guard index != viewModel.currentChapterIndex else { return }
                    viewModel.currentChapterIndex = index
                    Task { await viewModel.loadChapter(at: index, start: .beginning) }
                    viewModel.saveProgress(book: book, modelContext: modelContext)
                } label: {
                    HStack {
                        Text(viewModel.chapterTitle(at: index).isEmpty
                             ? "Chapter \(index + 1)"
                             : viewModel.chapterTitle(at: index))
                        Spacer()
                        if index == viewModel.currentChapterIndex {
                            Image(systemName: "bookmark.fill")
                        }
                    }
                }
            }
            .navigationTitle(book.title)
        }
    }
}
