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
    var translatedColumns: [[String]]? = nil
    var layoutMode: LayoutMode = .sideBySide
    let isOriginal: Bool
    let chapterTitle: String
    let translatedChapterTitle: String
    let isFirstPage: Bool
    let fontSize: CGFloat
    let theme: BookTheme
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
        columnLayout
            .padding(.horizontal, ReaderLayout.horizontalPadding)
            .padding(.top, ReaderLayout.topContentInset)
            .padding(.bottom, ReaderLayout.bottomContentInset)
            .frame(maxHeight: .infinity, alignment: .top)
            // Backstop: if an estimate is ever off, clip rather than spill onto the chrome.
            .clipped()
    }

    @ViewBuilder
    private var columnLayout: some View {
        if columns.count <= 1 {
            // Cap the measure, then centre that column in whatever space is left.
            column(at: 0)
                .frame(maxWidth: ReaderLayout.maxTextWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            HStack(alignment: .top, spacing: ReaderLayout.columnGutter) {
                ForEach(columns.indices, id: \.self) { index in
                    column(at: index)
                        .frame(maxWidth: ReaderLayout.maxTextWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func column(at columnIndex: Int) -> some View {
        let paragraphs = columns.indices.contains(columnIndex) ? columns[columnIndex] : []
        let translations = translatedColumns?.indices.contains(columnIndex) == true
            ? translatedColumns![columnIndex]
            : []

        return VStack(alignment: .leading, spacing: ReaderLayout.paragraphSpacing) {
            // The heading belongs to the first column of the first page only — anywhere
            // else it would read as a second chapter starting mid-spread.
            if isFirstPage && columnIndex == 0 && !chapterTitle.isEmpty {
                Text(isOriginal ? chapterTitle : translatedChapterTitle)
                    .font(.system(size: fontSize + ReaderLayout.titleSizeIncrease, weight: .medium, design: .serif))
                    .foregroundStyle(theme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, ReaderLayout.titleBottomPadding)
            }

            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, text in
                VStack(alignment: .leading, spacing: ReaderLayout.interleavedPairSpacing) {
                    JustifiedText(
                        text: text,
                        fontSize: fontSize,
                        lineSpacing: ReaderLayout.bodyLineSpacing,
                        color: theme.textColor
                    )
                        .fixedSize(horizontal: false, vertical: true)
                        .contextMenu {
                            if isOriginal {
                                Button("Translate") { onTranslate(text) }
                            }
                            Button("Copy") { onCopy(text) }
                        }

                    if layoutMode == .interleaved {
                        let translated = translations.indices.contains(index) ? translations[index] : ""
                        if !translated.isEmpty {
                            JustifiedText(
                                text: translated,
                                fontSize: fontSize * ReaderLayout.translationScale,
                                italic: true,
                                lineSpacing: ReaderLayout.translationLineSpacing,
                                color: theme.textColor.opacity(0.6)
                            )
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, ReaderLayout.interleavedTranslationBottomPadding)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(.bottom, layoutMode == .interleaved ? ReaderLayout.interleavedPairBottomPadding : 0)
            }

            Spacer(minLength: 0)
        }
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
