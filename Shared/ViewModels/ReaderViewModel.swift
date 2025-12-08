import SwiftUI
import SwiftData
@preconcurrency import Translation

/// ViewModel for the Reader view, managing all reading state and logic
@MainActor
@Observable
final class ReaderViewModel {
    // MARK: - Reading State
    var chapters: [EPUBService.Chapter] = []
    var tableOfContents: [EPUBService.TOCItem] = []
    var currentChapterIndex: Int = 0
    var isLoadingChapter = false
    
    // MARK: - Pagination State
    var allParagraphs: [String] = []
    var pages: [[String]] = []
    var currentPageIndex: Int = 0
    var translatedPage: [String] = []
    var translatedChapterTitle: String = ""
    
    // MARK: - UI State
    var fontSize: CGFloat = 17
    var showTOC = false
    var showThemeSettings = false
    var currentTheme: BookTheme = .paper
    var availableContentHeight: CGFloat = 500
    var availableContentWidth: CGFloat = 400
    var navigatingForward: Bool = true
    
    // MARK: - Translation State
    var showSystemTranslation = false
    var textToTranslate = ""
    var translationService = TranslationService()
    
    // MARK: - Resize State
    var isResizing = false
    var resizeDebounceTask: Task<Void, Never>?
    
    // MARK: - Summarization
    var showSummarySheet = false
    
    // MARK: - Services
    private let epubService = EPUBService()
    
    // MARK: - Computed Properties
    
    var currentPageContent: [String] {
        guard currentPageIndex >= 0 && currentPageIndex < pages.count else { return [] }
        return pages[currentPageIndex]
    }
    
    var canGoPrevious: Bool {
        currentPageIndex > 0 || currentChapterIndex > 0
    }
    
    var canGoNext: Bool {
        currentPageIndex < pages.count - 1 || currentChapterIndex < chapters.count - 1
    }
    
    var currentChapterTitle: String {
        guard currentChapterIndex >= 0 && currentChapterIndex < chapters.count else {
            return ""
        }
        
        let currentChapter = chapters[currentChapterIndex]
        
        // Try to find matching TOC item by href
        if let tocItem = tableOfContents.first(where: { tocItem in
            currentChapter.href.contains(tocItem.href) || tocItem.href.contains(currentChapter.href)
        }) {
            return tocItem.label
        }
        
        return currentChapter.title
    }
    
    // MARK: - Navigation
    
    func goToPreviousPage() {
        navigatingForward = false
        if currentPageIndex > 0 {
            currentPageIndex -= 1
        } else if currentChapterIndex > 0 {
            currentChapterIndex -= 1
            // Will trigger loadChapter which sets currentPageIndex to last page
        }
    }
    
    func goToNextPage() {
        navigatingForward = true
        if currentPageIndex < pages.count - 1 {
            currentPageIndex += 1
        } else if currentChapterIndex < chapters.count - 1 {
            currentChapterIndex += 1
            currentPageIndex = 0
        }
    }
    
    // MARK: - Data Loading
    
    func loadBook(book: Book) async {
        do {
            let content = try epubService.parse(epubData: book.epubData)
            chapters = content.chapters
            tableOfContents = content.tableOfContents
            currentChapterIndex = book.currentChapterIndex
            if !chapters.isEmpty {
                await loadChapter(at: currentChapterIndex, restoringPageIndex: book.currentPageIndex)
            }
        } catch {
            print("Error loading book: \(error)")
        }
    }
    
    func loadChapter(at index: Int, restoringPageIndex: Int? = nil) async {
        guard index >= 0 && index < chapters.count else { return }
        translatedPage = []
        translationService.reset()
        
        allParagraphs = epubService.extractParagraphs(from: chapters[index].htmlContent)
        paginateContent()
        
        if let savedPageIndex = restoringPageIndex {
            currentPageIndex = min(savedPageIndex, max(0, pages.count - 1))
        } else if currentPageIndex >= pages.count {
            currentPageIndex = 0
        }
        translateCurrentPage()
    }
    
    // MARK: - Pagination
    
    func paginateContent() {
        var result: [[String]] = []
        var currentPage: [String] = []
        var currentHeight: CGFloat = 0
        
        let lineHeight = fontSize + 6
        let paragraphSpacing: CGFloat = 16
        let charWidth = fontSize * 0.45
        let charsPerLine = max(35, Int(availableContentWidth / charWidth))
        let effectiveHeight = availableContentHeight
        
        for para in allParagraphs {
            let textLines = max(1, (para.count + charsPerLine - 1) / charsPerLine)
            let spacing = currentPage.isEmpty ? 0 : paragraphSpacing
            let paragraphHeight = (CGFloat(textLines) * lineHeight) + spacing
            
            if currentHeight + paragraphHeight > effectiveHeight && !currentPage.isEmpty {
                result.append(currentPage)
                currentPage = [para]
                currentHeight = CGFloat(textLines) * lineHeight
            } else {
                currentPage.append(para)
                currentHeight += paragraphHeight
            }
        }
        if !currentPage.isEmpty { result.append(currentPage) }
        pages = result.isEmpty ? [[]] : result
    }
    
    // MARK: - Translation
    
    func translateCurrentPage() {
        guard !currentPageContent.isEmpty else { return }
        
        var textsToTranslate = currentPageContent
        if currentPageIndex == 0 && !currentChapterTitle.isEmpty {
            textsToTranslate.insert(currentChapterTitle, at: 0)
        }
        
        translationService.requestTranslation(
            texts: textsToTranslate,
            from: .from("fr"),
            to: .from("en")
        )
    }
    
    func handleTranslationComplete() {
        // Separate chapter title from page content if on first page
        if currentPageIndex == 0 && !currentChapterTitle.isEmpty {
            let results = translationService.translatedTexts
            if !results.isEmpty {
                translatedChapterTitle = results[0]
                translatedPage = Array(results.dropFirst())
            } else {
                translatedPage = results
            }
        } else {
            translatedPage = translationService.translatedTexts
        }
    }
    
    // MARK: - Resize Handling
    
    func handleSizeChange(newSize: CGSize) {
        resizeDebounceTask?.cancel()
        
        withAnimation(.easeIn(duration: 0.1)) {
            isResizing = true
        }
        
        let contentHeight = newSize.height - 64
        let contentWidth = (newSize.width / 2) - 96
        if abs(contentHeight - availableContentHeight) > 20 || abs(contentWidth - availableContentWidth) > 20 {
            availableContentHeight = contentHeight
            availableContentWidth = contentWidth
            paginateContent()
            if currentPageIndex >= pages.count {
                currentPageIndex = max(0, pages.count - 1)
            }
            translateCurrentPage()
        }
        
        resizeDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.3)) {
                        isResizing = false
                    }
                }
            }
        }
    }
    
    func handleFontSizeChange() {
        withAnimation(.easeIn(duration: 0.1)) {
            isResizing = true
        }
        
        paginateContent()
        if currentPageIndex >= pages.count {
            currentPageIndex = max(0, pages.count - 1)
        }
        translateCurrentPage()
        
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    isResizing = false
                }
            }
        }
    }
    
    // MARK: - Progress Saving
    
    func saveProgress(book: Book, modelContext: ModelContext) {
        book.currentChapterIndex = currentChapterIndex
        book.currentPageIndex = currentPageIndex
        book.lastReadDate = Date()
        try? modelContext.save()
    }
}
