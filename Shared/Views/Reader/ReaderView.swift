import SwiftUI
import SwiftData
import Translation

/// Main reader view - now a thin coordinator using extracted components
struct ReaderView: View {
    let book: Book
    @Binding var navigationPath: NavigationPath
    
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ReaderViewModel()
    
    #if os(macOS)
    @FocusState private var isViewFocused: Bool
    #endif
    
    var body: some View {
        ZStack {
            viewModel.currentTheme.pageColor
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                ReaderToolbar(
                    bookTitle: book.title,
                    theme: viewModel.currentTheme,
                    onBack: {
                        viewModel.saveProgress(book: book, modelContext: modelContext)
                        navigationPath.removeLast()
                    },
                    onShowTOC: { viewModel.showTOC = true },
                    onShowSummary: { viewModel.showSummarySheet = true },
                    showThemeSettings: $viewModel.showThemeSettings
                )
                .popover(isPresented: $viewModel.showThemeSettings, arrowEdge: .top) {
                    ThemeSettings(
                        fontSize: $viewModel.fontSize,
                        currentTheme: $viewModel.currentTheme
                    )
                }
                
                // Two-page spread
                GeometryReader { geometry in
                    ZStack {
                        pageSpread(geometry: geometry)
                            .id("\(viewModel.currentChapterIndex)-\(viewModel.currentPageIndex)")
                            .transition(.asymmetric(
                                insertion: .move(edge: viewModel.navigatingForward ? .trailing : .leading),
                                removal: .move(edge: viewModel.navigatingForward ? .leading : .trailing)
                            ))
                        
                        // Frosted glass overlay during resize/translation
                        if viewModel.isResizing || viewModel.translationService.isTranslating {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .ignoresSafeArea()
                                .transition(.opacity.animation(.easeOut(duration: 0.2)))
                        }
                    }
                    .gesture(swipeGesture)
                    .onChange(of: geometry.size) { _, newSize in
                        viewModel.handleSizeChange(newSize: newSize)
                    }
                    .onAppear {
                        let contentHeight = geometry.size.height - 64
                        let contentWidth = (geometry.size.width / 2) - 96
                        viewModel.availableContentHeight = contentHeight
                        viewModel.availableContentWidth = contentWidth
                    }
                }
                
                PageNavigator(
                    currentPage: viewModel.currentPageIndex + 1,
                    totalPages: viewModel.pages.count,
                    chapterTitle: viewModel.currentChapterTitle,
                    hasChapters: !viewModel.chapters.isEmpty,
                    canGoPrevious: viewModel.canGoPrevious,
                    canGoNext: viewModel.canGoNext,
                    theme: viewModel.currentTheme,
                    onPrevious: { viewModel.goToPreviousPage() },
                    onNext: { viewModel.goToNextPage() }
                )
            }
        }
        .preferredColorScheme(viewModel.currentTheme.colorScheme)
        #if os(macOS)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden)
        .onKeyPress(.leftArrow) { viewModel.goToPreviousPage(); return .handled }
        .onKeyPress(.rightArrow) { viewModel.goToNextPage(); return .handled }
        .focusable()
        .focused($isViewFocused)
        .onAppear { isViewFocused = true }
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
                    viewModel.currentChapterIndex = idx
                    viewModel.currentPageIndex = 0
                    viewModel.showTOC = false
                },
                onDismiss: { viewModel.showTOC = false }
            )
        }
        .sheet(isPresented: $viewModel.showSummarySheet) {
            SummarySheet(
                chapterTitle: "Page \(viewModel.currentPageIndex + 1)",
                chapterText: viewModel.currentPageContent.joined(separator: "\n\n"),
                onDismiss: { viewModel.showSummarySheet = false }
            )
        }
        .translationPresentation(isPresented: $viewModel.showSystemTranslation, text: viewModel.textToTranslate)
        .translationTask(viewModel.translationService.configuration) { session in
            await viewModel.translationService.performTranslation(using: session)
            viewModel.handleTranslationComplete()
        }
        .task { await viewModel.loadBook(book: book) }
        .onChange(of: viewModel.currentChapterIndex) { _, _ in
            Task { await viewModel.loadChapter(at: viewModel.currentChapterIndex) }
            viewModel.saveProgress(book: book, modelContext: modelContext)
        }
        .onChange(of: viewModel.currentPageIndex) { _, _ in
            viewModel.translateCurrentPage()
            viewModel.saveProgress(book: book, modelContext: modelContext)
        }
        .onChange(of: viewModel.fontSize) { _, _ in
            viewModel.handleFontSizeChange()
        }
        .onDisappear {
            viewModel.saveProgress(book: book, modelContext: modelContext)
        }
    }
    
    // MARK: - Page Spread
    
    @ViewBuilder
    private func pageSpread(geometry: GeometryProxy) -> some View {
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
    
    private func horizontalSpread(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            PageView(
                paragraphs: viewModel.currentPageContent,
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
                paragraphs: viewModel.translatedPage,
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
                paragraphs: viewModel.currentPageContent,
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
                paragraphs: viewModel.translatedPage,
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

#Preview {
    ReaderView(
        book: Book(title: "Le Comte de Monte-Cristo", author: "Alexandre Dumas", epubData: Data()),
        navigationPath: .constant(NavigationPath())
    )
    .modelContainer(for: Book.self, inMemory: true)
}
