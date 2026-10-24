import SwiftUI

/// Single page of text content (used for both original and translated sides).
///
/// A page is a page: there is no scroll view here. `ReaderViewModel.paginateContent()`
/// measures this exact layout — same fonts, same spacing, same column width — and only
/// puts on a page what will fit on it.
///
/// A page may hold more than one column. On a wide window an interleaved page reads as
/// two columns, left then right, the way a book shows two facing pages rather than one
/// narrow strip of text marooned in the middle.
struct PageView: View {
    /// Text per column. One entry for a single-column page, two for a spread.
    let columns: [[String]]
    /// Book-set paragraphs — indents, page-spanning splits — in place of `columns`' plain
    /// strings, when the reader is laying the book out as a book rather than a bilingual text.
    var paragraphs: [[ReaderParagraph]]? = nil
    var translatedColumns: [[String]]? = nil
    var layoutMode: LayoutMode = .sideBySide
    let isOriginal: Bool
    let chapterTitle: String
    let translatedChapterTitle: String
    let isFirstPage: Bool
    let fontSize: CGFloat
    let theme: BookTheme
    var style = ReadingStyle()
    let isTranslating: Bool
    let onTranslate: (String) -> Void
    let onCopy: (String) -> Void

    private var isEmpty: Bool {
        columns.allSatisfy(\.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEmpty && !isOriginal && isTranslating {
                loadingState
            } else {
                pageContent
            }
        }
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
                Spacer()
            }
            Spacer()
        }
    }

    private var pageContent: some View {
        GeometryReader { geometry in
            // The style's margins come off both sides before the columns are cut — the
            // same subtraction the paginator makes, so lines break where they were measured.
            columnLayout(width: geometry.size.width - style.extraMargin * 2)
                .frame(maxWidth: .infinity)
        }
            .padding(.top, ReaderLayout.topContentInset)
            .padding(.bottom, ReaderLayout.bottomContentInset)
            .frame(maxHeight: .infinity, alignment: .top)
            // Backstop: if an estimate is ever off, clip rather than spill onto the chrome.
            .clipped()
    }

    @ViewBuilder
    private func columnLayout(width: CGFloat) -> some View {
        if columns.count <= 1 {
            // Cap the measure, then centre that column in whatever space is left.
            column(at: 0)
                .frame(width: ReaderLayout.columnWidth(in: width, columns: 1), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            HStack(alignment: .top, spacing: ReaderLayout.columnGutter) {
                ForEach(columns.indices, id: \.self) { index in
                    column(at: index)
                        .frame(width: ReaderLayout.columnWidth(in: width, columns: columns.count), alignment: .leading)
                }
            }
            // Centre the spread as a whole. Expanding each column independently added
            // its unused width to the gutter and left the right margin larger than the left.
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func column(at columnIndex: Int) -> some View {
        if let paragraphs, layoutMode != .interleaved {
            bookColumn(paragraphs.indices.contains(columnIndex) ? paragraphs[columnIndex] : [], columnIndex: columnIndex)
        } else {
            bilingualColumn(at: columnIndex)
        }
    }

    /// A column set as a book is: paragraphs indented, with no more space between them
    /// than between lines — a text view leaves line spacing off a paragraph's last line,
    /// so it goes back in here and the rhythm runs unbroken down the page.
    private func bookColumn(_ items: [ReaderParagraph], columnIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: ReaderLayout.bodyLineSpacing * style.lineSpacingScale) {
            if isFirstPage && columnIndex == 0 && !chapterTitle.isEmpty {
                Text(isOriginal ? chapterTitle : translatedChapterTitle)
                    .font(style.titleFont(size: fontSize + ReaderLayout.titleSizeIncrease, weight: .medium))
                    .foregroundStyle(theme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    // The stack's own spacing adds a line gap; the paginator budgets the
                    // heading's air without it, so take it back out here.
                    .padding(.bottom, ReaderLayout.titleBottomPadding + ReaderLayout.paragraphSpacing
                             - ReaderLayout.bodyLineSpacing * style.lineSpacingScale)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                JustifiedText(
                    text: item.text,
                    fontSize: fontSize,
                    lineSpacing: ReaderLayout.bodyLineSpacing * style.lineSpacingScale,
                    color: theme.textColor,
                    style: style,
                    firstLineIndent: item.indented ? ReaderLayout.firstLineIndent(size: fontSize) : 0,
                    lineLimit: item.lineLimit
                )
                .fixedSize(horizontal: false, vertical: true)
                #if !os(tvOS)
                .contextMenu {
                    if isOriginal {
                        Button("Translate") { onTranslate(item.text) }
                    }
                    Button("Copy") { onCopy(item.text) }
                }
                #endif
            }
        }
    }

    private func bilingualColumn(at columnIndex: Int) -> some View {
        let paragraphs = columns.indices.contains(columnIndex) ? columns[columnIndex] : []
        let translations = translatedColumns?.indices.contains(columnIndex) == true
            ? translatedColumns![columnIndex]
            : []

        return VStack(alignment: .leading, spacing: ReaderLayout.paragraphSpacing) {
            // The heading belongs to the first column of the first page only — anywhere
            // else it would read as a second chapter starting mid-spread.
            if isFirstPage && columnIndex == 0 && !chapterTitle.isEmpty {
                Text(isOriginal ? chapterTitle : translatedChapterTitle)
                    .font(style.titleFont(size: fontSize + ReaderLayout.titleSizeIncrease, weight: .medium))
                    .foregroundStyle(theme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, ReaderLayout.titleBottomPadding)
            }

            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, text in
                // A sentence running on into the next column draws its French clipped to
                // the lines that fit here; the part finishing it may be its English alone.
                let setting = self.paragraphs?.indices.contains(columnIndex) == true
                    && self.paragraphs![columnIndex].indices.contains(index)
                    ? self.paragraphs![columnIndex][index]
                    : nil
                VStack(alignment: .leading, spacing: ReaderLayout.interleavedPairSpacing) {
                    if !text.isEmpty {
                    JustifiedText(
                        text: setting?.text ?? text,
                        fontSize: fontSize,
                        lineSpacing: ReaderLayout.bodyLineSpacing * style.lineSpacingScale,
                        color: theme.textColor,
                        style: style,
                        lineLimit: setting?.lineLimit
                    )
                        .fixedSize(horizontal: false, vertical: true)
                        .contextMenu {
                            if isOriginal {
                                Button("Translate") { onTranslate(text) }
                            }
                            Button("Copy") { onCopy(text) }
                        }
                    }

                    if layoutMode == .interleaved {
                        let translated = translations.indices.contains(index) ? translations[index] : ""
                        if !translated.isEmpty {
                            JustifiedText(
                                text: translated,
                                fontSize: fontSize * ReaderLayout.translationScale,
                                italic: true,
                                lineSpacing: ReaderLayout.translationLineSpacing * style.lineSpacingScale,
                                color: theme.translationColor,
                                style: style
                            )
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.trailing, ReaderLayout.italicOverhang)
                                .padding(.bottom, ReaderLayout.interleavedTranslationBottomPadding)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.bottom, layoutMode == .interleaved ? ReaderLayout.interleavedPairBottomPadding : 0)
            }

        }
    }
}

/// A paragraph as the book layout sets it.
struct ReaderParagraph: Equatable {
    var text: String
    /// Draw only this many lines of `text` — the part of a paragraph that ends a page.
    var lineLimit: Int?
    var indented: Bool
    var isHeading: Bool

    /// A short line with no closing punctuation — "LETTER VII", "Part Two" — reads as a
    /// heading: it isn't indented, and neither is the paragraph after it.
    static func looksLikeHeading(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, trimmed.count <= 48 else { return false }
        return !".,;:!?…»”\"'’)]–—-*".contains(last)
    }
}

#Preview {
    PageView(
        columns: [["This is a sample paragraph.", "And another one here."]],
        translatedColumns: [["Ceci est un paragraphe d'exemple.", "Et un autre ici."]],
        layoutMode: .interleaved,
        isOriginal: true,
        chapterTitle: "Chapter 1",
        translatedChapterTitle: "Chapitre 1",
        isFirstPage: true,
        fontSize: 17,
        theme: .calm,
        isTranslating: false,
        onTranslate: { _ in },
        onCopy: { _ in }
    )
}
