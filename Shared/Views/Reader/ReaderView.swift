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
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = ReaderViewModel()
    @State private var eventMonitor: Any?
    
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
                GeometryReader { geometry in
                    ZStack {
                        readingPage(geometry: geometry)

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
                    #if os(macOS)
                    .gesture(swipeGesture)
                    #endif
                    // One pipe for all geometry, `initial: true` included. The old shape —
                    // onAppear assigning viewSize directly, onChange diffing against it —
                    // is what let fullscreen render pages built for a 1200×800 window:
                    // the assignment made the later diff look like "no change".
                    .onChange(of: geometry.size, initial: true) { _, newSize in
                        viewModel.reconcileSize(newSize)
                    }
                    .onAppear {
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
            }
        }
        .preferredColorScheme(viewModel.currentTheme.colorScheme)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden)
        #if os(macOS)
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
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

            pageSpread(geometry: geometry)
                .id("\(viewModel.currentChapterIndex)-\(viewModel.currentPageIndex)")
                .transition(.asymmetric(
                    insertion: .move(edge: viewModel.navigatingForward ? .trailing : .leading),
                    removal: .move(edge: viewModel.navigatingForward ? .leading : .trailing)
                ))
                .allowsHitTesting(!viewModel.isResizing)
        }
        #if os(iOS)
        .contentShape(Rectangle())
        // Keep this on the page layer. Taps on the toolbar or arrows must never
        // toggle their own visibility or accidentally trigger another action.
        .simultaneousGesture(TapGesture().onEnded { viewModel.toggleReadingControls() })
        #endif
    }

    /// Toolbar on top, fading when the pointer settles; a quiet page count at the foot
    /// of the page that stays put.
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
                showThemeSettings: $viewModel.showThemeSettings
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
            .accessibilityHidden(!viewModel.isChromeVisible)

            Spacer(minLength: 0)

            #if os(iOS)
            HStack(spacing: 16) {
                pageButton("Previous page", symbol: "chevron.left", enabled: viewModel.canGoPrevious) {
                    viewModel.goToPreviousPage()
                }
                Spacer(minLength: 0)
                pageCount
                Spacer(minLength: 0)
                pageButton("Next page", symbol: "chevron.right", enabled: viewModel.canGoNext) {
                    viewModel.goToNextPage()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            #else
            pageCount.padding(.bottom, 14)
            #endif
        }
    }

    private var pageCount: some View {
        Text(
            viewModel.pagesLeftInChapter == 0
                ? "Last page in this chapter"
                : "^[\(viewModel.pagesLeftInChapter) page](inflect: true) left in this chapter"
        )
        .font(.footnote)
        .foregroundStyle(viewModel.currentTheme.textColor.opacity(0.45))
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

    @ViewBuilder
    private func pageSpread(geometry: GeometryProxy) -> some View {
        if viewModel.layoutMode != .sideBySide {
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
    
    
    #if os(macOS)
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                guard abs(horizontal) > abs(value.translation.height) * 1.5 else { return }
                if horizontal > 60 {
                    viewModel.goToPreviousPage()
                } else if horizontal < -60 {
                    viewModel.goToNextPage()
                }
            }
    }
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
