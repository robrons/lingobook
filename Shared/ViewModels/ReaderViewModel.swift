import SwiftUI
import SwiftData
#if !os(tvOS)
@preconcurrency import Translation
#endif

/// ViewModel for the Reader view, managing all reading state and logic
@MainActor
@Observable
final class ReaderViewModel {
    // MARK: - Reading State
    var chapters: [EPUBService.Chapter] = []
    var tableOfContents: [EPUBService.TOCItem] = []
    var currentChapterIndex: Int = 0
    var isLoadingChapter = false
    var isInitialLoadComplete = false
    /// Why this book couldn't be opened. Non-nil means the reader shows an explanation
    /// and a way back rather than an empty spread.
    var loadError: String?
    
    // MARK: - Pagination State

    /// A block of text plus its character offset within the chapter.
    ///
    /// The offset is what anchors the reading position. Unlike a page number it survives
    /// a window resize, a font change, or a switch to interleaved mode (which re-splits
    /// paragraphs into sentences) — all of which renumber the pages underneath the reader.
    struct TextUnit: Equatable {
        let text: String
        let offset: Int
        /// Set only on the part of a paragraph that ends a page: the whole of the text it
        /// was cut from, drawn and clipped to `lineLimit` lines. Drawing just its own text
        /// would set the page's last line ragged, as a paragraph's final line — clipping
        /// the full paragraph keeps it justified, the way Books runs text over a page.
        var clippedFrom: String? = nil
        var lineLimit: Int? = nil
        var indented = false
        var isHeading = false
        /// The sentence whose translation goes under this unit — the unit itself, unless
        /// it's part of a sentence that runs on into the next column. The part that ends
        /// a column shows no translation (""); the part that finishes the sentence shows
        /// the whole sentence's, so the English always follows the French it belongs to.
        var translationKey: String? = nil

        var paragraph: ReaderParagraph {
            ReaderParagraph(text: clippedFrom ?? text, lineLimit: lineLimit, indented: indented, isHeading: isHeading)
        }
    }

    /// One spread's worth of text, split into the columns it renders as.
    ///
    /// A page used to be a flat list of units. It isn't any more: on a wide window an
    /// interleaved page reads as two columns, left then right — the same trick that lets
    /// Books put ~2.5× as much text on screen as a single centred column ever could.
    struct Page: Equatable {
        var columns: [[TextUnit]]

        /// Every unit on the page in reading order, left column then right.
        var units: [TextUnit] { columns.flatMap { $0 } }

        var firstOffset: Int { columns.first?.first?.offset ?? 0 }
    }

    var allUnits: [TextUnit] = []
    var pages: [Page] = []
    /// The chapter `pages` belong to. Lags `currentChapterIndex` while the next chapter
    /// loads, so a view can tell a turn into a new chapter from one that's still coming.
    private(set) var paginatedChapterIndex = -1
    /// Bumped on every pagination: the same page number can hold different text after a
    /// font change or a resize, and a view that caches spreads needs to know.
    private(set) var layoutVersion = 0
    var currentPageIndex: Int = 0 {
        didSet { readingAnchor = nil }
    }
    /// Keep the original character position through repeated reflows. Using each new
    /// page's first character as the next anchor walks backwards a little on every resize.
    private var readingAnchor: Int?
    var translatedPage: [String] = []
    var translatedChapterTitle: String = ""
    
    // MARK: - UI State
    var fontSize: CGFloat = 17
    var showTOC = false
    var showThemeSettings = false
    var currentTheme: BookTheme = .calm {
        didSet {
            // A theme brings its own font and spacing, which moves line and page breaks.
            if themeStyles.style(for: oldValue) != themeStyles.style(for: currentTheme) && isInitialLoadComplete {
                handleFontSizeChange()
            }
        }
    }
    /// Every theme's customizations, kept per theme as Books keeps them.
    var themeStyles = ThemeStyles()

    /// Font, spacing and margins for the theme on show: Books' Customize settings.
    /// Changing it customizes this theme only.
    var readingStyle: ReadingStyle {
        get { themeStyles.style(for: currentTheme) }
        set {
            let old = readingStyle
            themeStyles.set(newValue, for: currentTheme)
            if old != newValue && isInitialLoadComplete {
                handleFontSizeChange()
            }
        }
    }

    /// Whether this theme has been customized, for Reset Theme.
    var isThemeCustomized: Bool { readingStyle != currentTheme.defaultStyle }

    func resetTheme() { readingStyle = currentTheme.defaultStyle }

    /// What the page is set in. Both the paginator and `PageView` use this.
    var renderStyle: ReadingStyle { readingStyle }
    var layoutMode: LayoutMode = .sideBySide {
        didSet {
            if oldValue != layoutMode && isInitialLoadComplete {
                handleLayoutModeChange()
            }
        }
    }
    var viewSize: CGSize = CGSize(width: 800, height: 600)
    
    var availableContentHeight: CGFloat {
        max(100, viewSize.height - ReaderLayout.totalVerticalInset)
    }

    /// Columns of text on one page.
    ///
    /// Side-by-side never gets two: it already spends the width on the translation, so
    /// there's none left to split.
    var columnsPerPage: Int {
        guard layoutMode != .sideBySide else { return 1 }
        return viewSize.width >= ReaderLayout.twoColumnMinWidth ? 2 : 1
    }

    /// Width of a single text column. Capped at `maxTextWidth` so lines stay readable on
    /// a wide window; `PageView` applies the same cap, so measurement matches rendering.
    var availableContentWidth: CGFloat {
        ReaderLayout.columnWidth(
            in: (layoutMode == .sideBySide ? viewSize.width / 2 : viewSize.width) - renderStyle.extraMargin * 2,
            columns: columnsPerPage
        )
    }
    var navigatingForward: Bool = true
    
    // MARK: - Translation State
    var showSystemTranslation = false
    var textToTranslate = ""
    #if !os(tvOS)
    var translationService = TranslationService()
    var speechService = SpeechRecognitionService()
    #endif
    var ttsService = TTSService()
    var isAutoReading = false
    /// Translations already made for this book — read before asking the translator, and
    /// the only source of translations on Apple TV, which has no translator to ask.
    private var memory = TranslationMemory()
    private var memoryHasUnsavedEntries = false

    var isTranslating: Bool {
        #if os(tvOS)
        false
        #else
        translationService.isTranslating
        #endif
    }

    /// The page has text with no saved translation. Only Apple TV can end up here.
    var isMissingTranslations = false

    /// The saved translation that goes under a unit: "" for one with none to show (the
    /// first part of a sentence split across columns), nil if it was never translated.
    private func savedTranslation(for unit: TextUnit) -> String? {
        let key = unit.translationKey ?? unit.text
        return key.isEmpty ? "" : memory.translation(of: key)
    }

    /// Whether this book came with translations to show. On Apple TV, a book sent without
    /// them (an English book, say) offers no translation settings at all.
    var hasSavedTranslations: Bool { !memory.isEmpty }
    private var pendingAutoReadAfterTranslation = false
    /// The texts behind the translation currently on screen, so we don't ask twice.
    private var lastTranslationRequest: [String] = []
    /// What was last asked of the translator: this page's texts, then the pages either
    /// side's, so a page turn finds its English already made.
    private var lastTranslatorRequest: [String] = []
    /// How many of `lastTranslatorRequest`'s texts are the page on screen's.
    private var requestedPageCount = 0
    /// Bumped whenever new translations are remembered, so pictures of pages taken
    /// before them — the ones a page curl is made from — get taken again.
    private(set) var translationsVersion = 0

    /// Translating the page on screen, as opposed to the pages either side of it in the
    /// background — only the first is worth covering the page for.
    var isTranslatingPage: Bool {
        #if os(tvOS)
        false
        #else
        translationService.isTranslating && requestedPageCount > 0
        #endif
    }
    
    // MARK: - Chrome Visibility

    var isChromeVisible = true
    private var chromeHideTask: Task<Void, Never>?

    /// Something is open that's anchored to the chrome, so it must stay put.
    private var isOverlayPresented: Bool {
        showTOC || showThemeSettings
    }

    /// Show controls. Only the Mac hides them automatically after pointer inactivity.
    func noteChromeActivity() {
        if !isChromeVisible {
            withAnimation(.easeOut(duration: 0.2)) { isChromeVisible = true }
        }
        #if os(macOS)
        scheduleChromeHide()
        #endif
    }

    #if os(iOS)
    func toggleReadingControls() {
        guard !isOverlayPresented else { return }
        cancelChromeHide()
        withAnimation(.easeOut(duration: 0.2)) {
            isChromeVisible.toggle()
        }
    }
    #endif

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        chromeHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            // Fading the bar out from under an open popover would yank its anchor away.
            guard !self.isOverlayPresented else { return }
            withAnimation(.easeOut(duration: 0.4)) { self.isChromeVisible = false }
        }
    }

    func cancelChromeHide() {
        chromeHideTask?.cancel()
    }

    // MARK: - Resize State
    var isResizing = false
    var resizeDebounceTask: Task<Void, Never>?

    /// The view size pagination last actually ran against.
    ///
    /// This is the fix for the stale-page bug: pages built for a 1200×800 window were
    /// being rendered fullscreen with a quarter of every column empty, because the
    /// "did the size change?" check compared against `viewSize` — which an `onAppear`
    /// had already updated without repaginating. Comparing against what pagination
    /// *used* makes staleness detectable no matter which event path led to it.
    private var lastPaginatedSize: CGSize = .zero

    private func sizeMatchesLastPagination(_ size: CGSize) -> Bool {
        abs(size.width - lastPaginatedSize.width) <= 1
            && abs(size.height - lastPaginatedSize.height) <= 1
    }

    /// Called with every geometry report, including the first. Repaginates only when the
    /// current pages were built for a different size than the one on screen.
    func reconcileSize(_ newSize: CGSize) {
        guard !sizeMatchesLastPagination(newSize) else {
            viewSize = newSize
            return
        }

        // Before the book has loaded there is nothing to re-flow; just make sure the
        // initial pagination uses the real geometry, not the 800×600 placeholder.
        guard isInitialLoadComplete else {
            viewSize = newSize
            return
        }

        handleSizeChange(newSize: newSize)
    }
    
    // MARK: - Services
    private let epubService = EPUBService()
    
    // MARK: - Computed Properties
    
    /// Everything on the page in reading order. What TTS reads, what the tutor is shown,
    /// and what gets sent for translation — all of which want a flat list.
    var currentPageContent: [String] {
        guard currentPageIndex >= 0 && currentPageIndex < pages.count else { return [] }
        return pages[currentPageIndex].units.map(\.text)
    }

    /// The same text, still in its columns. What `PageView` draws.
    var currentPageColumns: [[String]] {
        guard currentPageIndex >= 0 && currentPageIndex < pages.count else { return [[]] }
        return pages[currentPageIndex].columns.map { $0.map(\.text) }
    }

    /// `translatedPage` arrives flat, matching `currentPageContent`. Re-cut it to the same
    /// shape as the columns so each translation stays under the line it belongs to.
    var translatedColumns: [[String]] {
        guard currentPageIndex >= 0 && currentPageIndex < pages.count else { return [[]] }

        var result: [[String]] = []
        var cursor = 0

        for column in pages[currentPageIndex].columns {
            let end = min(cursor + column.count, translatedPage.count)
            result.append(cursor < end ? Array(translatedPage[cursor..<end]) : [])
            cursor += column.count
        }

        return result
    }

    /// Character offset of the first unit on the current page — the position we persist.
    var currentOffset: Int {
        guard currentPageIndex >= 0 && currentPageIndex < pages.count else { return 0 }
        return readingAnchor ?? pages[currentPageIndex].firstOffset
    }

    /// The page holding a given character offset: the last page that starts at or before it.
    private func pageIndex(containing offset: Int) -> Int {
        var match = 0
        for (index, page) in pages.enumerated() {
            guard page.columns.contains(where: { !$0.isEmpty }) else { continue }
            if page.firstOffset <= offset { match = index } else { break }
        }
        return match
    }
    
    /// How far through the whole book the reader is, 0…1.
    ///
    /// Chapter-weighted: each chapter counts equally regardless of length, so a short
    /// chapter advances the bar as much as a long one. Character-exact progress would
    /// mean measuring every chapter up front — for a shelf label and a scrubber, this
    /// is close enough and costs nothing.
    var bookProgress: Double {
        guard !chapters.isEmpty else { return 0 }
        let pageFraction = pages.isEmpty ? 0 : Double(currentPageIndex + 1) / Double(pages.count)
        let progress = (Double(currentChapterIndex) + pageFraction) / Double(chapters.count)
        return min(max(progress, 0), 1)
    }

    /// Pages remaining after this one in the current chapter.
    var pagesLeftInChapter: Int {
        max(0, pages.count - currentPageIndex - 1)
    }

    var canGoPrevious: Bool {
        currentPageIndex > 0 || currentChapterIndex > 0
    }
    
    var canGoNext: Bool {
        currentPageIndex < pages.count - 1 || currentChapterIndex < chapters.count - 1
    }
    
    var currentChapterTitle: String {
        chapterTitle(at: currentChapterIndex)
    }

    func chapterTitle(at index: Int) -> String {
        guard index >= 0 && index < chapters.count else {
            return ""
        }
        return Self.chapterTitle(of: chapters[index], tableOfContents: tableOfContents)
    }

    /// Shared with whole-book translation, which has to translate exactly the headings
    /// the reader will show.
    nonisolated static func chapterTitle(of chapter: EPUBService.Chapter, tableOfContents: [EPUBService.TOCItem]) -> String {
        // Try to find matching TOC item by href
        if let tocItem = tableOfContents.first(where: { tocItem in
            chapter.href.contains(tocItem.href) || tocItem.href.contains(chapter.href)
        }) {
            return tocItem.label
        }

        return chapter.title
    }
    
    // MARK: - Navigation
    
    func goToPreviousPage() {
        ttsService.stop()
        navigatingForward = false
        if currentPageIndex > 0 {
            currentPageIndex -= 1
        } else if currentChapterIndex > 0 {
            currentChapterIndex -= 1
            Task { await loadChapter(at: currentChapterIndex, start: .end) }
        }
    }
    
    func goToNextPage(isAutoTurn: Bool = false) {
        if !isAutoTurn {
            isAutoReading = false
            pendingAutoReadAfterTranslation = false
            ttsService.stop()
        }
        navigatingForward = true
        if currentPageIndex < pages.count - 1 {
            currentPageIndex += 1
        } else if currentChapterIndex < chapters.count - 1 {
            currentChapterIndex += 1
            Task { await loadChapter(at: currentChapterIndex) }
        }
    }
    
    /// Jump straight to a page in this chapter — the scrubber's landing.
    func goToPage(_ index: Int) {
        guard index >= 0, index < pages.count, index != currentPageIndex else { return }
        isAutoReading = false
        pendingAutoReadAfterTranslation = false
        ttsService.stop()
        navigatingForward = index > currentPageIndex
        currentPageIndex = index
    }

    // MARK: - Data Loading
    
    func loadBook(book: Book) async {
        loadError = nil
        do {
            let content = try epubService.parse(epubData: book.epubData)
            chapters = content.chapters

            // Books imported before the EPUB's language was being kept still have none.
            if book.language == nil, let language = content.language {
                book.language = language
            }
            memory = TranslationMemory(data: book.translationsData)
            memoryHasUnsavedEntries = false
            setupTTSCallback()
            #if !os(tvOS)
            setupSpeechCallback()
            #endif
            tableOfContents = content.tableOfContents
            currentChapterIndex = book.currentChapterIndex
            fontSize = CGFloat(book.savedFontSize)
            currentTheme = BookTheme(rawValue: book.savedThemeName) ?? .calm
            themeStyles = ThemeStyles(data: book.savedStyleData)
            layoutMode = LayoutMode(rawValue: book.savedLayoutMode) ?? .sideBySide
            #if os(tvOS)
            if memory.isEmpty { layoutMode = .original }
            #endif
            if !chapters.isEmpty {
                // Books saved before offsets existed only have a page number to go on.
                let start: ChapterStart = (book.currentOffset == 0 && book.currentPageIndex > 0)
                    ? .legacyPage(book.currentPageIndex)
                    : .offset(book.currentOffset)
                await loadChapter(at: currentChapterIndex, start: start)
            }
            isInitialLoadComplete = true

            // If the window reported its real size while the EPUB was still parsing,
            // the pagination above ran against stale geometry. Catch it here instead
            // of trusting event order.
            if !sizeMatchesLastPagination(viewSize) {
                repaginatePreservingPosition()
                translateCurrentPage()
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
    
    /// Where to land when a chapter finishes loading.
    enum ChapterStart {
        case beginning
        case end
        case offset(Int)
        /// A page number saved before offsets existed. Approximate, and only used once.
        case legacyPage(Int)
    }

    func loadChapter(at index: Int, start: ChapterStart = .beginning) async {
        guard index >= 0 && index < chapters.count else { return }
        readingAnchor = nil
        translatedPage = []
        #if !os(tvOS)
        translationService.reset()
        #endif
        lastTranslationRequest = []
        lastTranslatorRequest = []
        requestedPageCount = 0

        if let laidOut = neighbors[index] {
            // Laid out ahead of time for a page turn into it: no need to do it again.
            layoutVersion += 1
            lastPaginatedSize = viewSize
            neighbors = [:]
            allUnits = laidOut.units
            pages = laidOut.pages
        } else {
            let paragraphs = epubService.extractParagraphs(from: chapters[index].htmlContent)
            allUnits = buildUnits(from: paragraphs, chapterTitle: chapterTitle(at: index))
            paginateContent()
        }
        paginatedChapterIndex = index

        switch start {
        case .beginning:
            currentPageIndex = 0
        case .end:
            currentPageIndex = max(0, pages.count - 1)
        case .offset(let offset):
            currentPageIndex = pageIndex(containing: offset)
            readingAnchor = offset
        case .legacyPage(let page):
            currentPageIndex = min(page, max(0, pages.count - 1))
        }

        translateCurrentPage()
    }

    // MARK: - Pagination

    /// Turns a chapter's paragraphs into display units, tagging each with its character
    /// offset in the chapter so the reading position can survive re-pagination.
    private func buildUnits(from paragraphs: [String], chapterTitle: String) -> [TextUnit] {
        var units: [TextUnit] = []
        var cursor = 0

        for paragraph in droppingHeading(chapterTitle, from: paragraphs) {
            if layoutMode == .interleaved {
                // Sentence-level pairing is the whole point of interleaved mode.
                for sentence in SentenceSplitter.sentences(in: paragraph) {
                    let stripped = sentence.text.strippingLeadingDashes()
                    guard !stripped.isEmpty else { continue }
                    units.append(TextUnit(text: stripped, offset: cursor + sentence.offset))
                }
            } else if usesBookParagraphs {
                // Books' paragraphs: indented, except a heading and the paragraph that
                // opens a chapter or follows a heading — as a typesetter does it.
                let heading = ReaderParagraph.looksLikeHeading(paragraph)
                let follows = units.last.map { !$0.isHeading } ?? false
                var unit = TextUnit(text: paragraph, offset: cursor)
                unit.isHeading = heading
                unit.indented = !heading && follows
                units.append(unit)
            } else {
                units.append(TextUnit(text: paragraph, offset: cursor))
            }
            // +2 mirrors the blank line between paragraphs; only monotonicity matters.
            cursor += paragraph.count + 2
        }

        return units
    }

    /// Book typesetting — indents, and no more space between paragraphs than between
    /// lines — wherever text is set as paragraphs: the book read as itself, and both pages
    /// of side-by-side.
    private var usesBookParagraphs: Bool {
        layoutMode != .interleaved
    }

    /// Paragraphs run on across page breaks, at a line. Only when the book is read as
    /// itself: side-by-side's translations are looked up a whole paragraph at a time, so
    /// a paragraph there moves over whole to stay opposite its translation. Interleaved
    /// runs on too on Apple TV, where every translation arrived with the book and can be
    /// measured; elsewhere they're made a page at a time, a whole sentence per lookup.
    private var runsParagraphsAcrossPages: Bool {
        #if os(tvOS)
        layoutMode != .sideBySide
        #else
        layoutMode == .original
        #endif
    }

    /// The current page as `PageView` draws it, in columns, with each paragraph's setting.
    var currentPageParagraphs: [[ReaderParagraph]] {
        guard currentPageIndex >= 0 && currentPageIndex < pages.count else { return [[]] }
        return pages[currentPageIndex].columns.map { $0.map(\.paragraph) }
    }

    /// Everything needed to draw one spread of the current chapter — any spread, not just
    /// the one on screen, so a page curl can show the page being turned to before it's
    /// turned. Translations come from what's saved, which on Apple TV is all there is.
    struct SpreadContent {
        var pageIndex: Int
        var columns: [[String]]
        var paragraphs: [[ReaderParagraph]]
        var translatedColumns: [[String]]
        var translatedParagraphs: [ReaderParagraph]
        var translatedPage: [String]
        var chapterTitle: String
        var translatedChapterTitle: String
        /// Pages in the chapter this spread is from, for "pages left in chapter".
        var pageCount: Int
        var isFirstPage: Bool { pageIndex == 0 }
        var pagesLeft: Int { max(0, pageCount - pageIndex - 1) }
    }

    func spreadContent(at pageIndex: Int) -> SpreadContent? {
        guard pageIndex >= 0 && pageIndex < pages.count else { return nil }
        guard pageIndex != currentPageIndex else {
            return SpreadContent(
                pageIndex: pageIndex,
                columns: currentPageColumns,
                paragraphs: currentPageParagraphs,
                translatedColumns: translatedColumns,
                translatedParagraphs: translatedPageParagraphs,
                translatedPage: translatedPage,
                chapterTitle: currentChapterTitle,
                translatedChapterTitle: translatedChapterTitle,
                pageCount: pages.count
            )
        }
        return spreadContent(of: pages, at: pageIndex, chapterTitle: currentChapterTitle)
    }

    private func spreadContent(of pages: [Page], at pageIndex: Int, chapterTitle: String) -> SpreadContent? {
        guard pageIndex >= 0 && pageIndex < pages.count else { return nil }
        let page = pages[pageIndex]

        let translations = layoutMode.showsTranslation
            ? page.units.map { savedTranslation(for: $0) ?? "" }
            : []
        var translatedColumns: [[String]] = []
        var cursor = 0
        for column in page.columns {
            let end = min(cursor + column.count, translations.count)
            translatedColumns.append(cursor < end ? Array(translations[cursor..<end]) : [])
            cursor += column.count
        }
        let units = page.units
        let translatedParagraphs = translations.enumerated().map { index, text in
            ReaderParagraph(
                text: text,
                lineLimit: nil,
                indented: units[index].indented,
                isHeading: units[index].isHeading
            )
        }

        return SpreadContent(
            pageIndex: pageIndex,
            columns: page.columns.map { $0.map(\.text) },
            paragraphs: page.columns.map { $0.map(\.paragraph) },
            translatedColumns: translatedColumns,
            translatedParagraphs: translatedParagraphs,
            translatedPage: translations,
            chapterTitle: chapterTitle,
            translatedChapterTitle: layoutMode.showsTranslation ? (memory.translation(of: chapterTitle) ?? "") : "",
            pageCount: pages.count
        )
    }

    /// Side-by-side's facing page: each translation set like the paragraph opposite it.
    var translatedPageParagraphs: [ReaderParagraph] {
        guard currentPageIndex >= 0 && currentPageIndex < pages.count else { return [] }
        let units = pages[currentPageIndex].units
        return translatedPage.enumerated().map { index, text in
            ReaderParagraph(
                text: text,
                lineLimit: nil,
                indented: units.indices.contains(index) && units[index].indented,
                isHeading: units.indices.contains(index) && units[index].isHeading
            )
        }
    }

    /// Drops the chapter heading from the body when the EPUB repeats it there.
    ///
    /// `PageView` draws the chapter title itself at the top of the first page, but most
    /// EPUBs also carry that heading as markup inside the chapter, so the extractor hands
    /// it back as ordinary paragraphs and the reader shows it twice — once large, once as
    /// the opening line of prose.
    ///
    /// Publishers split headings across several elements ("Chapitre 1" in one, the title
    /// proper in the next), so this consumes leading paragraphs for as long as they keep
    /// spelling out the title, and only commits to dropping them once the whole title has
    /// been accounted for. A partial match leaves the text alone: losing a real opening
    /// sentence would be far worse than showing a heading twice.
    private func droppingHeading(_ title: String, from paragraphs: [String]) -> [String] {
        func normalized(_ value: String) -> String {
            value
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        var remaining = normalized(title)
        guard !remaining.isEmpty else { return paragraphs }

        var consumed = 0

        for paragraph in paragraphs {
            let candidate = normalized(paragraph)

            if candidate.isEmpty {
                consumed += 1
                continue
            }

            guard remaining.hasPrefix(candidate) else { break }

            remaining = String(remaining.dropFirst(candidate.count))
                .trimmingCharacters(in: .whitespaces)
            consumed += 1

            if remaining.isEmpty { break }
        }

        guard remaining.isEmpty, consumed > 0 else { return paragraphs }
        return Array(paragraphs.dropFirst(consumed))
    }

    func paginateContent() {
        layoutVersion += 1
        lastPaginatedSize = viewSize
        neighbors = [:]
        pages = layOut(allUnits, title: currentChapterTitle)
    }

    /// Lays a chapter's units out into pages at the current size, type and layout.
    private func layOut(_ allUnits: [TextUnit], title currentChapterTitle: String) -> [Page] {
        let width = availableContentWidth
        let fullHeight = availableContentHeight

        guard width > 0, fullHeight > 0, !allUnits.isEmpty else {
            return [Page(columns: [[]])]
        }

        let style = renderStyle

        // Heights come from SwiftUI itself (see ReaderTextMeasurer) — the paginator and
        // the renderer share one notion of how tall a unit is, so pages fill to the
        // budget instead of stopping a paragraph early or clipping a line late.
        func unitHeight(_ unit: TextUnit) -> CGFloat {
            if layoutMode == .interleaved {
                #if os(tvOS)
                // Every translation the TV will show arrived with the book, so measure the
                // real one rather than reserving the French's length for the English.
                let translation = savedTranslation(for: unit)
                if translation == "" {
                    // French only: the part of a sentence that ends a column.
                    return ReaderTextMeasurer.height(
                        of: unit.paragraph,
                        size: fontSize,
                        lineSpacing: ReaderLayout.bodyLineSpacing * style.lineSpacingScale,
                        width: width,
                        style: style
                    )
                }
                #else
                let translation: String? = nil
                #endif
                return ReaderTextMeasurer.interleavedPairHeight(
                    text: unit.text,
                    translation: translation,
                    fontSize: fontSize,
                    width: width,
                    style: style
                )
            }
            return ReaderTextMeasurer.height(
                of: unit.paragraph,
                size: fontSize,
                lineSpacing: ReaderLayout.bodyLineSpacing * style.lineSpacingScale,
                width: width,
                style: style
            )
        }

        // The chapter heading sits atop the first column, so that column holds less text.
        var firstColumnHeight = fullHeight
        if !currentChapterTitle.isEmpty {
            let titleHeight = ReaderTextMeasurer.height(
                of: currentChapterTitle,
                size: fontSize + ReaderLayout.titleSizeIncrease,
                weight: .medium,
                lineSpacing: 0,
                width: width,
                justified: false,
                style: style
            )
            firstColumnHeight -= titleHeight + ReaderLayout.titleBottomPadding + ReaderLayout.paragraphSpacing
            // An absurdly long heading shouldn't leave a column with no room for text.
            firstColumnHeight = max(firstColumnHeight, fullHeight * 0.25)
        }

        // Unit heights are text-only; the air below a pair is charged here, between
        // units. A column's last pair pays for its text and nothing more — its trailing
        // padding falls into the leftover, where it was going to be empty anyway.
        let unitSpacing = layoutMode == .interleaved
            ? ReaderLayout.paragraphSpacing + ReaderLayout.interleavedTrailingDecoration
            : usesBookParagraphs ? ReaderLayout.bodyLineSpacing * style.lineSpacingScale : ReaderLayout.paragraphSpacing

        // Fill one column at a time. Whether two of them end up side by side or one below
        // the toolbar is a question for the grouping step — the filling is identical.
        var columns: [[TextUnit]] = []
        var column: [TextUnit] = []
        var columnHeight: CGFloat = 0
        var budget = firstColumnHeight

        func closeColumn() {
            columns.append(column)
            column = []
            columnHeight = 0
            budget = fullHeight
        }

        for unit in allUnits {
            if runsParagraphsAcrossPages {
                // Books runs a paragraph on from the foot of one page to the head of the
                // next, at a line, for as many pages as it takes — so a page is only ever
                // short at the end of a chapter. Moving paragraphs over whole is what left
                // pages a third empty; cutting long ones at sentences set each sentence
                // as a paragraph of its own.
                var pending = unit
                while true {
                    let height = unitHeight(pending)
                    let spacing = column.isEmpty ? 0 : unitSpacing
                    if columnHeight + spacing + height <= budget {
                        column.append(pending)
                        columnHeight += spacing + height
                        break
                    }
                    let room = budget - columnHeight - spacing
                    let parts = layoutMode == .interleaved
                        ? splitPairToFill(pending, room: room, measure: unitHeight)
                        : splitToFill(pending, room: room, measure: unitHeight)
                    if let (head, tail) = parts {
                        column.append(head)
                        closeColumn()
                        pending = tail
                    } else if column.isEmpty {
                        // Unbreakable and taller than a page: rare, and clipped rather than lost.
                        column.append(pending)
                        closeColumn()
                        break
                    } else {
                        closeColumn()
                    }
                }
                continue
            }

            // A paragraph taller than a whole column has to be broken up, or removing the
            // inner ScrollView would simply cut its tail off.
            let limit = columns.isEmpty && column.isEmpty ? budget : fullHeight
            let pieces = unitHeight(unit) > limit
                ? split(unit, toFit: limit, measure: unitHeight)
                : [unit]

            for piece in pieces {
                let height = unitHeight(piece)
                let spacing = column.isEmpty ? 0 : unitSpacing

                // Interleaved pairs and side-by-side paragraphs move over whole: their
                // translations are looked up whole, and a sentence parted from its
                // translation is no use to anyone.
                if !column.isEmpty && columnHeight + spacing + height > budget {
                    closeColumn()
                    column = [piece]
                    columnHeight = height
                } else {
                    column.append(piece)
                    columnHeight += spacing + height
                }
            }
        }

        if !column.isEmpty { columns.append(column) }

        #if DEBUG
        let fills = columns.prefix(4).map { col in
            Int(col.reduce(CGFloat(0)) { $0 + unitHeight($1) }
                + CGFloat(max(0, col.count - 1)) * unitSpacing)
        }
        Self.debugLog(
            "[paginate] view=\(Int(viewSize.width))x\(Int(viewSize.height))"
            + " font=\(Int(fontSize)) colsPerPage=\(columnsPerPage) colW=\(Int(width))"
            + " budget=\(Int(fullHeight)) firstColBudget=\(Int(firstColumnHeight))"
            + " units=\(allUnits.count) columns=\(columns.count) fill=\(fills)"
        )
        #endif

        return Self.group(columns: columns, perPage: columnsPerPage)
    }

    // MARK: - Neighbouring chapters

    /// The chapters either side, laid out ahead of time so a page can be turned into
    /// them by hand like any other — and opened instantly, without laying out again.
    private struct Neighbor {
        var units: [TextUnit]
        var pages: [Page]
        var title: String
    }

    private var neighbors: [Int: Neighbor] = [:]

    private func neighbor(_ index: Int) -> Neighbor? {
        guard index >= 0, index < chapters.count else { return nil }
        if let cached = neighbors[index] { return cached }
        let title = chapterTitle(at: index)
        let paragraphs = epubService.extractParagraphs(from: chapters[index].htmlContent)
        let units = buildUnits(from: paragraphs, chapterTitle: title)
        let laidOut = Neighbor(units: units, pages: layOut(units, title: title), title: title)
        neighbors[index] = laidOut
        return laidOut
    }

    /// Lays out the next or previous chapter, if this page is at the edge that leads there.
    func prepareNeighborChapter() {
        guard isInitialLoadComplete, !pages.isEmpty else { return }
        if currentPageIndex == pages.count - 1 { _ = neighbor(currentChapterIndex + 1) }
        if currentPageIndex == 0 { _ = neighbor(currentChapterIndex - 1) }
    }

    /// The spread a page turn leads to, in this chapter or across into the next one.
    func spreadContent(turning forward: Bool) -> SpreadContent? {
        let target = forward ? currentPageIndex + 1 : currentPageIndex - 1
        if target >= 0 && target < pages.count { return spreadContent(at: target) }
        guard let next = neighbor(forward ? currentChapterIndex + 1 : currentChapterIndex - 1) else { return nil }
        let index = forward ? 0 : max(0, next.pages.count - 1)
        return spreadContent(of: next.pages, at: index, chapterTitle: next.title)
    }

    /// Deals filled columns onto pages, in order. A trailing page may be half empty —
    /// that's the end of the chapter, not a bug.
    private static func group(columns: [[TextUnit]], perPage: Int) -> [Page] {
        guard !columns.isEmpty else { return [Page(columns: [[]])] }

        let stride = max(1, perPage)
        var result: [Page] = []
        var index = 0

        while index < columns.count {
            let end = min(index + stride, columns.count)
            var spread = Array(columns[index..<end])
            // Keep the final, partly empty spread at the same measured column width.
            while spread.count < stride { spread.append([]) }
            result.append(Page(columns: spread))
            index = end
        }

        return result
    }

    /// Splits a paragraph at a line so its first part exactly fills `room`, leaving the
    /// rest to open the next column. Nil when that would strand a single line on either
    /// side — Books' widows and orphans — or the paragraph is too short to part.
    ///
    /// The break falls exactly where the text engine wraps the line, so the head, drawn
    /// as the whole paragraph clipped to its lines, and the tail, starting fresh at the
    /// next character, read as one continuous paragraph across the page turn.
    private func splitToFill(
        _ unit: TextUnit,
        room: CGFloat,
        measure: (TextUnit) -> CGFloat
    ) -> (TextUnit, TextUnit)? {
        guard unit.lineLimit == nil, !unit.isHeading else { return nil }

        let style = renderStyle
        let lineEnds = ReaderTextMeasurer.lineEnds(
            of: unit.paragraph,
            size: fontSize,
            lineSpacing: ReaderLayout.bodyLineSpacing * style.lineSpacingScale,
            width: availableContentWidth,
            style: style
        )
        let lineCount = lineEnds.count
        guard lineCount >= 4 else { return nil }

        func head(_ lines: Int) -> TextUnit {
            let end = String.Index(utf16Offset: lineEnds[lines - 1], in: unit.text)
            var head = TextUnit(text: String(unit.text[..<end]), offset: unit.offset)
            head.clippedFrom = unit.text
            head.lineLimit = lines
            head.indented = unit.indented
            return head
        }

        // The most lines that fit, keeping two on each side of the break. Start from what
        // a line's height suggests — a long paragraph has dozens of lines to try otherwise.
        let lineHeight = ReaderTextMeasurer.height(
            of: "A",
            size: fontSize,
            lineSpacing: ReaderLayout.bodyLineSpacing * style.lineSpacingScale,
            width: availableContentWidth,
            style: style
        ) + ReaderLayout.bodyLineSpacing * style.lineSpacingScale
        var lines = min(lineCount - 2, max(2, Int(room / max(lineHeight, 1)) + 1))
        while lines >= 2, measure(head(lines)) > room { lines -= 1 }
        while lines + 1 <= lineCount - 2, measure(head(lines + 1)) <= room { lines += 1 }
        guard lines >= 2 else { return nil }

        let end = String.Index(utf16Offset: lineEnds[lines - 1], in: unit.text)
        let rest = unit.text[end...]
        let start = rest.firstIndex { !$0.isWhitespace } ?? rest.endIndex
        let tail = TextUnit(
            text: String(unit.text[start...]),
            offset: unit.offset + unit.text.distance(from: unit.text.startIndex, to: start)
        )
        return (head(lines), tail)
    }

    /// Splits a sentence and its translation so the column ends full: as many lines of
    /// the French as fit stay here, and the rest — then the English — open the next
    /// column. If all the French fits but not the English, the English goes over alone.
    /// Nil when not even one line of the French fits.
    private func splitPairToFill(
        _ unit: TextUnit,
        room: CGFloat,
        measure: (TextUnit) -> CGFloat
    ) -> (TextUnit, TextUnit)? {
        guard unit.lineLimit == nil, !unit.text.isEmpty else { return nil }
        let key = unit.translationKey ?? unit.text
        guard let translation = memory.translation(of: key), !translation.isEmpty else { return nil }

        let style = renderStyle
        let lineEnds = ReaderTextMeasurer.lineEnds(
            of: ReaderParagraph(text: unit.text, lineLimit: nil, indented: false, isHeading: false),
            size: fontSize,
            lineSpacing: ReaderLayout.bodyLineSpacing * style.lineSpacingScale,
            width: availableContentWidth,
            style: style
        )
        let lineCount = lineEnds.count
        guard lineCount >= 1 else { return nil }

        func head(_ lines: Int) -> TextUnit {
            if lines >= lineCount {
                var whole = unit
                whole.translationKey = ""
                return whole
            }
            let end = String.Index(utf16Offset: lineEnds[lines - 1], in: unit.text)
            var head = TextUnit(text: String(unit.text[..<end]), offset: unit.offset)
            head.clippedFrom = unit.text
            head.lineLimit = lines
            head.translationKey = ""
            return head
        }

        var lines = 0
        for candidate in stride(from: lineCount, through: 1, by: -1) where measure(head(candidate)) <= room {
            lines = candidate
            break
        }
        // One line is enough: the sentence carries straight on at the top of the next
        // column, and a lone line reads far better than a hole two lines deep.
        guard lines >= 1 else { return nil }

        let tail: TextUnit
        if lines >= lineCount {
            tail = TextUnit(text: "", offset: unit.offset + unit.text.count, translationKey: key)
        } else {
            let end = String.Index(utf16Offset: lineEnds[lines - 1], in: unit.text)
            let rest = unit.text[end...]
            let start = rest.firstIndex { !$0.isWhitespace } ?? rest.endIndex
            tail = TextUnit(
                text: String(unit.text[start...]),
                offset: unit.offset + unit.text.distance(from: unit.text.startIndex, to: start),
                translationKey: key
            )
        }
        return (head(lines), tail)
    }

    /// Breaks an over-long unit at sentence boundaries into pieces that each fit a page.
    /// Offsets are preserved so the reading position still resolves.
    private func split(
        _ unit: TextUnit,
        toFit maxHeight: CGFloat,
        measure: (TextUnit) -> CGFloat
    ) -> [TextUnit] {
        let text = unit.text
        let sentences = SentenceSplitter.sentences(in: text)

        // A long sentence still has to fit. Keep normal sentences intact, but split
        // exceptional ones at word boundaries instead of silently clipping their tails.
        guard sentences.count > 1 else {
            return splitWords(unit, toFit: maxHeight, measure: measure)
        }

        var pieces: [TextUnit] = []
        var buffer = ""
        var bufferOffset = sentences[0].offset

        for sentence in sentences {
            let candidate = buffer.isEmpty ? sentence.text : buffer + " " + sentence.text

            if !buffer.isEmpty,
               measure(TextUnit(text: candidate, offset: unit.offset + bufferOffset)) > maxHeight {
                pieces.append(TextUnit(text: buffer, offset: unit.offset + bufferOffset))
                buffer = sentence.text
                bufferOffset = sentence.offset
            } else {
                buffer = candidate
            }
        }

        if !buffer.isEmpty {
            pieces.append(TextUnit(text: buffer, offset: unit.offset + bufferOffset))
        }

        return (pieces.isEmpty ? [unit] : pieces).flatMap { piece in
            measure(piece) > maxHeight
                ? splitWords(piece, toFit: maxHeight, measure: measure)
                : [piece]
        }
    }

    private func splitWords(
        _ unit: TextUnit,
        toFit maxHeight: CGFloat,
        measure: (TextUnit) -> CGFloat
    ) -> [TextUnit] {
        let words = unit.text.split(whereSeparator: \.isWhitespace)
        guard let first = words.first else { return [unit] }
        var start = first.startIndex
        var end = first.endIndex
        var pieces: [TextUnit] = []

        func piece(endingAt boundary: String.Index) -> TextUnit {
            TextUnit(
                text: String(unit.text[start..<boundary]),
                offset: unit.offset + unit.text.distance(from: unit.text.startIndex, to: start)
            )
        }

        for word in words.dropFirst() {
            if measure(piece(endingAt: word.endIndex)) > maxHeight {
                pieces.append(piece(endingAt: end))
                start = word.startIndex
            }
            end = word.endIndex
        }
        pieces.append(piece(endingAt: end))
        return pieces
    }

    /// Re-flow the text, keeping the reader on the same sentence.
    private func repaginatePreservingPosition() {
        let anchor = currentOffset
        paginateContent()
        currentPageIndex = pageIndex(containing: anchor)
        readingAnchor = anchor
    }
    
    // MARK: - Translation
    
    func translateCurrentPage() {
        guard layoutMode.showsTranslation else {
            // Forget the last request, so switching translation back on asks again.
            lastTranslationRequest = []
            translatedPage = []
            translatedChapterTitle = ""
            isMissingTranslations = false
            if pendingAutoReadAfterTranslation {
                pendingAutoReadAfterTranslation = false
                startPlayingCurrentPage()
            }
            return
        }
        guard !currentPageContent.isEmpty else { return }

        var textsToTranslate = currentPageContent
        if currentPageIndex == 0 && !currentChapterTitle.isEmpty {
            textsToTranslate.insert(currentChapterTitle, at: 0)
        }

        // Re-flowing often lands on the same text (a resize that doesn't change the page,
        // a font bump that keeps the same paragraphs). Re-translating it would be free
        // work and a flash of the loading overlay.
        guard textsToTranslate != lastTranslationRequest else { return }
        lastTranslationRequest = textsToTranslate

        // Pages already translated — on this device, or by the Mac before sending the
        // book to the TV — show instantly, offline, without asking the translator again.
        #if os(tvOS)
        var keyed = currentPageIndex >= 0 && currentPageIndex < pages.count
            ? pages[currentPageIndex].units.map { savedTranslation(for: $0) }
            : []
        if currentPageIndex == 0 && !currentChapterTitle.isEmpty {
            keyed.insert(memory.translation(of: currentChapterTitle), at: 0)
        }
        let saved = keyed
        isMissingTranslations = saved.contains(nil)
        applyTranslations(saved.map { $0 ?? "" })
        #else
        let saved = textsToTranslate.map { memory.translation(of: $0) }
        let ahead = textsAhead()
        if saved.allSatisfy({ $0 != nil }) {
            applyTranslations(saved.map { $0 ?? "" })
            // Nothing to wait for here; make the next pages' English while they're read.
            if !ahead.isEmpty { requestTranslation(page: [], ahead: ahead) }
            return
        }

        // What's known now, and blanks for the rest — never the last page's English left
        // standing under this page's sentences while the new translation is made.
        translatedPage = Array(saved.map { $0 ?? "" }.dropFirst(currentPageIndex == 0 && !currentChapterTitle.isEmpty ? 1 : 0))
        requestTranslation(page: textsToTranslate, ahead: ahead)
        #endif
    }

    #if !os(tvOS)
    /// Asks the translator for this page's texts and, in the same request, the pages
    /// either side's — one session's work, and the next turn's English is ready for it.
    private func requestTranslation(page: [String], ahead: [String]) {
        let texts = page + ahead
        guard texts != lastTranslatorRequest || !translationService.isTranslating else { return }
        lastTranslatorRequest = texts
        requestedPageCount = page.count
        translationService.requestTranslation(texts: texts, from: nil, to: .from("en"))
    }

    /// The texts on the spreads either side of this one that have never been translated.
    private func textsAhead() -> [String] {
        guard layoutMode.showsTranslation else { return [] }
        var texts: [String] = []
        for forward in [true, false] {
            guard let spread = spreadContent(turning: forward) else { continue }
            if spread.isFirstPage && !spread.chapterTitle.isEmpty { texts.append(spread.chapterTitle) }
            texts += spread.columns.flatMap { $0 }
        }
        var seen = Set<String>()
        return texts.filter { text in
            !text.isEmpty && memory.translation(of: text) == nil && seen.insert(text).inserted
        }
    }
    #endif

    /// Puts a page's translations on screen. `results` lines up with the texts last
    /// requested: the chapter title first on a chapter's opening page, then the page.
    private func applyTranslations(_ results: [String]) {
        if currentPageIndex == 0 && !currentChapterTitle.isEmpty && !results.isEmpty {
            translatedChapterTitle = results[0]
            translatedPage = Array(results.dropFirst())
        } else {
            translatedPage = results
        }

        if pendingAutoReadAfterTranslation {
            pendingAutoReadAfterTranslation = false
            startPlayingCurrentPage()
        }
    }
    
    /// The translation failure to show the reader, if any.
    ///
    /// Apple's own message is usually terse ("The operation couldn't be completed"), and by
    /// far the most common cause is simply that the language pair hasn't been downloaded yet
    /// — which is fixable in System Settings, so say so.
    #if !os(tvOS)
    var translationErrorMessage: String? {
        guard let error = translationService.error else { return nil }

        let lowered = error.lowercased()
        let looksLikeMissingModel = ["download", "language", "model", "unsupported", "not available"]
            .contains { lowered.contains($0) }

        guard looksLikeMissingModel else { return error }
        return error + " Translation languages download in System Settings → General → Language & Region."
    }

    /// Ask for the current page again after a failure.
    ///
    /// `translateCurrentPage()` skips work when the text matches the last request, which is
    /// what stops a resize from re-translating the same page — but it would also make Retry
    /// do nothing at all. Clearing the record first is what makes the button honest.
    func retryTranslation() {
        lastTranslationRequest = []
        lastTranslatorRequest = []
        translationService.error = nil
        translateCurrentPage()
    }

    func handleTranslationComplete() {
        // Only accept results for the request currently on screen. Fast page flips can
        // deliver a superseded session's completion after the reader has moved on —
        // writing page N's English under page N+1's French, or blanking a page that a
        // fresh request is about to fill.
        let delivered = translationService.results.map(\.original)
        guard !delivered.isEmpty, delivered == lastTranslatorRequest else { return }

        for result in translationService.results {
            memory.record(result.original, result.translated)
        }
        memoryHasUnsavedEntries = true
        translationsVersion += 1

        // Only the page's own share goes on screen; the rest waits in memory for its turn.
        guard requestedPageCount > 0 else { return }
        let count = requestedPageCount
        requestedPageCount = 0
        applyTranslations(Array(translationService.translatedTexts.prefix(count)))
    }
    #endif
    
    // MARK: - Text-To-Speech
    
    /// A page turn asked for by voice or by reading aloud, for the reader to play with
    /// its page curl. Turns go straight through instead when no reader has asked for them
    /// (`turnsByRequest`), as on Apple TV.
    struct TurnRequest: Equatable {
        let forward: Bool
        let isAutoTurn: Bool
        let id = UUID()
    }

    var turnRequest: TurnRequest?
    /// Set by a reader that animates turns itself.
    var turnsByRequest = false

    private func requestTurn(forward: Bool, isAutoTurn: Bool = false) {
        if turnsByRequest {
            turnRequest = TurnRequest(forward: forward, isAutoTurn: isAutoTurn)
        } else if forward {
            goToNextPage(isAutoTurn: isAutoTurn)
        } else {
            goToPreviousPage()
        }
    }

    private func setupTTSCallback() {
        ttsService.onFinishReading = { [weak self] in
            guard let self = self else { return }
            if self.isAutoReading && self.canGoNext {
                self.pendingAutoReadAfterTranslation = true
                self.requestTurn(forward: true, isAutoTurn: true)
            } else {
                self.isAutoReading = false
            }
        }
    }
    
    #if !os(tvOS)
    private func setupSpeechCallback() {
        speechService.onCommandRecognized = { [weak self] command in
            guard let self = self else { return }
            switch command {
            case .next:
                if self.canGoNext {
                    self.requestTurn(forward: true)
                }
            case .previous:
                if self.canGoPrevious {
                    self.requestTurn(forward: false)
                }
            }
        }
    }
    #endif
    
    func toggleReading() {
        if ttsService.isPlaying {
            ttsService.stop()
            isAutoReading = false
            pendingAutoReadAfterTranslation = false
        } else {
            isAutoReading = true
            startPlayingCurrentPage()
        }
    }
    
    private func startPlayingCurrentPage() {
        var originalTexts = currentPageContent
        if currentPageIndex == 0 && !currentChapterTitle.isEmpty {
            originalTexts.insert(currentChapterTitle, at: 0)
        }
        
        var enTexts = translatedPage
        if currentPageIndex == 0 && !translatedChapterTitle.isEmpty {
            enTexts.insert(translatedChapterTitle, at: 0)
        }
        
        ttsService.play(
            originalParagraphs: originalTexts,
            englishParagraphs: enTexts,
            title: currentChapterTitle
        )
    }
    
    // MARK: - Resize Handling
    
    /// Re-flowing on every frame of a window drag repaginated the chapter and re-requested
    /// translation dozens of times a second; the frosted overlay just hid it. Now only the
    /// size the window settles at does any work.
    func handleSizeChange(newSize: CGSize) {
        // Against lastPaginatedSize, not viewSize: viewSize may already hold the new
        // geometry (set by an appear handler) while the pages are still built for the
        // old one. Comparing to viewSize here is exactly how fullscreen pages ended up
        // a quarter empty.
        guard !sizeMatchesLastPagination(newSize) else {
            viewSize = newSize
            return
        }

        resizeDebounceTask?.cancel()

        withAnimation(.easeIn(duration: 0.1)) {
            isResizing = true
        }

        resizeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }

            self.viewSize = newSize
            self.repaginatePreservingPosition()
            self.translateCurrentPage()

            withAnimation(.easeOut(duration: 0.3)) {
                self.isResizing = false
            }
        }
    }

    func handleLayoutModeChange() {
        guard currentChapterIndex >= 0 && currentChapterIndex < chapters.count else { return }

        withAnimation(.easeIn(duration: 0.2)) {
            isResizing = true
        }

        // Switching mode re-splits paragraphs into sentences (or back), so the units are
        // rebuilt from scratch. Character offsets map cleanly across both shapes.
        let anchor = currentOffset
        let paragraphs = epubService.extractParagraphs(from: chapters[currentChapterIndex].htmlContent)
        allUnits = buildUnits(from: paragraphs, chapterTitle: currentChapterTitle)
        paginateContent()
        currentPageIndex = pageIndex(containing: anchor)
        readingAnchor = anchor
        translateCurrentPage()

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.isResizing = false
            }
        }
    }

    func handleFontSizeChange() {
        withAnimation(.easeIn(duration: 0.1)) {
            isResizing = true
        }

        repaginatePreservingPosition()
        translateCurrentPage()

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self.isResizing = false
            }
        }
    }
    
    #if DEBUG
    /// Appends to Documents inside the app's sandbox container and flushes per line —
    /// `print` is block-buffered when stdout is a file, which is how a whole debugging
    /// session's output once vanished into a 4KB buffer.
    private static func debugLog(_ message: String) {
        print(message)
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/pagination-debug.log")
        guard let data = (message + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
    #endif

    // MARK: - Progress Saving
    
    func saveProgress(book: Book, modelContext: ModelContext) {
        // Nothing was ever loaded — a book that failed to open, or one still loading. Saving
        // now would write zeros over a real reading position and lose the reader's place.
        guard isInitialLoadComplete else { return }

        book.currentChapterIndex = currentChapterIndex
        book.currentPageIndex = currentPageIndex
        book.currentOffset = currentOffset
        book.totalChapters = chapters.count
        book.readingProgress = bookProgress
        book.savedFontSize = Double(fontSize)
        book.savedThemeName = currentTheme.rawValue
        book.savedLayoutMode = layoutMode.rawValue
        book.savedStyleData = themeStyles.encoded()
        book.lastReadDate = Date()
        if memoryHasUnsavedEntries {
            book.translationsData = memory.encoded()
            memoryHasUnsavedEntries = false
        }
        try? modelContext.save()
    }
}
