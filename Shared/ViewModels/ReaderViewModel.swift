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
    var currentPageIndex: Int = 0
    var translatedPage: [String] = []
    var translatedChapterTitle: String = ""
    
    // MARK: - UI State
    var fontSize: CGFloat = 17
    var showTOC = false
    var showThemeSettings = false
    var currentTheme: BookTheme = .calm
    var layoutMode: LayoutMode = .sideBySide {
        didSet {
            if oldValue != layoutMode && isInitialLoadComplete {
                handleLayoutModeChange()
            }
        }
    }
    var viewSize: CGSize = CGSize(width: 800, height: 600)
    
    /// iPad in portrait stacks the original above the translation instead of placing them
    /// side by side, so each page gets half the *height* and the full width. Mirrors the
    /// `isLandscape` test in `ReaderView.pageSpread` — if one changes, so must the other.
    var isVerticalSpread: Bool {
        #if os(iOS)
        return layoutMode != .interleaved && viewSize.width <= viewSize.height
        #else
        return false
        #endif
    }

    var availableContentHeight: CGFloat {
        let usable = isVerticalSpread ? viewSize.height / 2 : viewSize.height
        return max(100, usable - ReaderLayout.totalVerticalInset)
    }

    /// Columns of text on one page.
    ///
    /// Only interleaved mode gets two: side-by-side already spends the width on the
    /// translation, so there's none left to split.
    var columnsPerPage: Int {
        guard layoutMode == .interleaved else { return 1 }
        return viewSize.width >= ReaderLayout.twoColumnMinWidth ? 2 : 1
    }

    /// Width of a single text column. Capped at `maxTextWidth` so lines stay readable on
    /// a wide window; `PageView` applies the same cap, so measurement matches rendering.
    var availableContentWidth: CGFloat {
        let inner: CGFloat
        if layoutMode == .interleaved || isVerticalSpread {
            inner = viewSize.width - ReaderLayout.horizontalPadding * 2
        } else {
            inner = viewSize.width / 2 - ReaderLayout.horizontalPadding * 2
        }

        let usable = columnsPerPage == 2
            ? (inner - ReaderLayout.columnGutter) / 2
            : inner

        return max(100, min(usable, ReaderLayout.maxTextWidth))
    }
    var navigatingForward: Bool = true
    
    // MARK: - Translation State
    var showSystemTranslation = false
    var textToTranslate = ""
    var translationService = TranslationService()
    var ttsService = TTSService()
    var speechService = SpeechRecognitionService()
    var isAutoReading = false
    private var pendingAutoReadAfterTranslation = false
    /// The texts behind the translation currently on screen, so we don't ask twice.
    private var lastTranslationRequest: [String] = []
    
    // MARK: - Chrome Visibility

    var isChromeVisible = true
    private var chromeHideTask: Task<Void, Never>?

    /// Something is open that's anchored to the chrome, so it must stay put.
    private var isOverlayPresented: Bool {
        showTOC || showThemeSettings
    }

    /// Pointer moved (macOS). Show the chrome, then start the clock again.
    func noteChromeActivity() {
        if !isChromeVisible {
            withAnimation(.easeOut(duration: 0.2)) { isChromeVisible = true }
        }
        scheduleChromeHide()
    }

    /// Center tap (iPadOS). No timer here — on touch, Books leaves it to you.
    func toggleChrome() {
        chromeHideTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { isChromeVisible.toggle() }
    }

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
        return pages[currentPageIndex].firstOffset
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

        let chapter = chapters[index]

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
            setupTTSCallback()
            setupSpeechCallback()
            tableOfContents = content.tableOfContents
            currentChapterIndex = book.currentChapterIndex
            fontSize = CGFloat(book.savedFontSize)
            currentTheme = BookTheme(rawValue: book.savedThemeName) ?? .calm
            layoutMode = LayoutMode(rawValue: book.savedLayoutMode) ?? .sideBySide
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
        translatedPage = []
        translationService.reset()
        lastTranslationRequest = []

        let paragraphs = epubService.extractParagraphs(from: chapters[index].htmlContent)
        allUnits = buildUnits(from: paragraphs, chapterTitle: chapterTitle(at: index))
        paginateContent()

        switch start {
        case .beginning:
            currentPageIndex = 0
        case .end:
            currentPageIndex = max(0, pages.count - 1)
        case .offset(let offset):
            currentPageIndex = pageIndex(containing: offset)
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
            } else {
                units.append(TextUnit(text: paragraph, offset: cursor))
            }
            // +2 mirrors the blank line between paragraphs; only monotonicity matters.
            cursor += paragraph.count + 2
        }

        return units
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
        let width = availableContentWidth
        let fullHeight = availableContentHeight

        lastPaginatedSize = viewSize

        guard width > 0, fullHeight > 0, !allUnits.isEmpty else {
            pages = [Page(columns: [[]])]
            return
        }

        // Heights come from SwiftUI itself (see ReaderTextMeasurer) — the paginator and
        // the renderer share one notion of how tall a unit is, so pages fill to the
        // budget instead of stopping a paragraph early or clipping a line late.
        func unitHeight(_ unit: TextUnit) -> CGFloat {
            if layoutMode == .interleaved {
                return ReaderTextMeasurer.interleavedPairHeight(
                    text: unit.text,
                    fontSize: fontSize,
                    width: width
                )
            }
            return ReaderTextMeasurer.height(
                of: unit.text,
                size: fontSize,
                lineSpacing: ReaderLayout.bodyLineSpacing,
                width: width
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
                justified: false
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
            : ReaderLayout.paragraphSpacing

        // Fill one column at a time. Whether two of them end up side by side or one below
        // the toolbar is a question for the grouping step — the filling is identical.
        var columns: [[TextUnit]] = []
        var column: [TextUnit] = []
        var columnHeight: CGFloat = 0
        var budget = firstColumnHeight

        for unit in allUnits {
            // A paragraph taller than a whole column has to be broken up, or removing the
            // inner ScrollView would simply cut its tail off.
            let pieces = unitHeight(unit) > fullHeight
                ? split(unit, toFit: fullHeight, measure: unitHeight)
                : [unit]

            for piece in pieces {
                let height = unitHeight(piece)
                let spacing = column.isEmpty ? 0 : unitSpacing

                if !column.isEmpty && columnHeight + spacing + height > budget {
                    columns.append(column)
                    column = [piece]
                    columnHeight = height
                    budget = fullHeight
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

        pages = Self.group(columns: columns, perPage: columnsPerPage)
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
            result.append(Page(columns: Array(columns[index..<end])))
            index = end
        }

        return result
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

        // A single sentence longer than a page is left whole; splitting mid-sentence
        // would read worse than the rare clipped tail.
        guard sentences.count > 1 else { return [unit] }

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

        return pieces.isEmpty ? [unit] : pieces
    }

    /// Re-flow the text, keeping the reader on the same sentence.
    private func repaginatePreservingPosition() {
        let anchor = currentOffset
        paginateContent()
        currentPageIndex = pageIndex(containing: anchor)
    }
    
    // MARK: - Translation
    
    func translateCurrentPage() {
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

        translationService.requestTranslation(
            texts: textsToTranslate,
            from: nil,
            to: .from("en")
        )
    }
    
    /// The translation failure to show the reader, if any.
    ///
    /// Apple's own message is usually terse ("The operation couldn't be completed"), and by
    /// far the most common cause is simply that the language pair hasn't been downloaded yet
    /// — which is fixable in System Settings, so say so.
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
        translationService.error = nil
        translateCurrentPage()
    }

    func handleTranslationComplete() {
        // Only accept results for the request currently on screen. Fast page flips can
        // deliver a superseded session's completion after the reader has moved on —
        // writing page N's English under page N+1's French, or blanking a page that a
        // fresh request is about to fill.
        let delivered = translationService.results.map(\.original)
        guard !delivered.isEmpty, delivered == lastTranslationRequest else { return }

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
        
        if pendingAutoReadAfterTranslation {
            pendingAutoReadAfterTranslation = false
            startPlayingCurrentPage()
        }
    }
    
    // MARK: - Text-To-Speech
    
    private func setupTTSCallback() {
        ttsService.onFinishReading = { [weak self] in
            guard let self = self else { return }
            if self.isAutoReading && self.canGoNext {
                self.pendingAutoReadAfterTranslation = true
                self.goToNextPage(isAutoTurn: true)
            } else {
                self.isAutoReading = false
            }
        }
    }
    
    private func setupSpeechCallback() {
        speechService.onCommandRecognized = { [weak self] command in
            guard let self = self else { return }
            switch command {
            case .next:
                if self.canGoNext {
                    self.goToNextPage()
                }
            case .previous:
                if self.canGoPrevious {
                    self.goToPreviousPage()
                }
            }
        }
    }
    
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
        book.lastReadDate = Date()
        try? modelContext.save()
    }
}
