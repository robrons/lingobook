import Foundation
import SwiftUI
@testable import LingoBook

/// Runs against the built application's real paginator and text renderer, without
/// opening a window, requesting translations, or touching the user's library store.
@main
struct ReaderLayoutChecks {
    @MainActor
    static func main() async throws {
        let model = ReaderViewModel()
        model.fontSize = 25
        model.layoutMode = .interleaved
        model.viewSize = CGSize(width: 1250, height: 891)

        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let content = try EPUBService().parse(epubData: data)
            model.chapters = content.chapters
        } else {
            let sentence = "Les pensionnaires regardaient la maison et parlaient tranquillement de leur journée."
            let longSentence = Array(repeating: "une promenade dans le jardin", count: 50).joined(separator: " ") + "."
            let paragraphs = Array(repeating: sentence, count: 70) + [longSentence] + Array(repeating: sentence, count: 70)
            let html = paragraphs.map { "<p>\($0)</p>" }.joined()
            model.chapters = [.init(id: "fixture", title: "Chapitre premier", htmlContent: html, href: "fixture", index: 0)]
        }

        let sizes = [
            CGSize(width: 1250, height: 891),
            CGSize(width: 1470, height: 891),
            CGSize(width: 1920, height: 1018),
            CGSize(width: 1100, height: 700),
            CGSize(width: 800, height: 600),
            CGSize(width: 1250, height: 891)
        ]
        var checkedColumns = 0
        for chapter in model.chapters.indices {
            model.currentChapterIndex = chapter
            await model.loadChapter(at: chapter)
            guard !model.allUnits.isEmpty else { continue }
            let anchor = model.allUnits.first(where: { $0.text.hasPrefix("Outre les sept") })?.offset
                ?? model.allUnits[model.allUnits.count / 2].offset
            await model.loadChapter(at: chapter, start: .offset(anchor))

            for size in sizes {
                model.handleSizeChange(newSize: size)
                await model.resizeDebounceTask?.value
                precondition(model.currentOffset == anchor, "Resizing changed the reading anchor")
                precondition(model.fontSize == 25, "Resizing changed the font")
                let page = model.pages[model.currentPageIndex]
                precondition(page.firstOffset <= anchor)
                if model.currentPageIndex + 1 < model.pages.count {
                    precondition(model.pages[model.currentPageIndex + 1].firstOffset > anchor)
                }

                let rendered = model.pages.flatMap(\.units)
                // Long units may be split, but every source word and punctuation mark
                // must appear exactly once, in order, with the original character offset.
                let expectedWords = model.allUnits.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
                let actualWords = rendered.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
                precondition(actualWords == expectedWords, "Missing, duplicated, or reordered source text")
                var originalIndex = 0
                for unit in rendered {
                    while originalIndex + 1 < model.allUnits.count,
                          model.allUnits[originalIndex + 1].offset <= unit.offset { originalIndex += 1 }
                    let original = model.allUnits[originalIndex]
                    let relative = unit.offset - original.offset
                    precondition(relative >= 0 && relative < original.text.count)
                    let start = original.text.index(original.text.startIndex, offsetBy: relative)
                    precondition(original.text[start...].hasPrefix(unit.text), "Split changed a character offset")
                }

                for (pageIndex, spread) in model.pages.enumerated() {
                    precondition(spread.columns.count == model.columnsPerPage, "Last spread changed column width")
                    for (columnIndex, column) in spread.columns.enumerated() {
                        var height: CGFloat = 0
                        for unit in column {
                            height += ReaderTextMeasurer.interleavedPairHeight(
                                text: unit.text, fontSize: model.fontSize, width: model.availableContentWidth
                            )
                        }
                        height += CGFloat(max(0, column.count - 1))
                            * (ReaderLayout.paragraphSpacing + ReaderLayout.interleavedTrailingDecoration)
                        if pageIndex == 0 && columnIndex == 0 && !model.currentChapterTitle.isEmpty {
                            height += ReaderTextMeasurer.height(
                                of: model.currentChapterTitle, size: model.fontSize + ReaderLayout.titleSizeIncrease,
                                weight: .medium, lineSpacing: 0, width: model.availableContentWidth, justified: false
                            ) + ReaderLayout.titleBottomPadding + ReaderLayout.paragraphSpacing
                        }
                        precondition(height <= model.availableContentHeight, "Column overflows at \(size): \(height)")
                        checkedColumns += 1
                    }
                }

                // Verify translations are assigned to the same source units after reflow.
                model.translatedPage = model.currentPageContent.indices.map { "translation-\($0)" }
                precondition(model.translatedColumns.flatMap { $0 } == model.translatedPage)
            }
        }

        let wideColumn = ReaderLayout.columnWidth(in: 1920, columns: 2)
        precondition(wideColumn == ReaderLayout.maxTextWidth)
        let spreadWidth = wideColumn * 2 + ReaderLayout.columnGutter
        let margin = (1920 - spreadWidth) / 2
        precondition(margin >= ReaderLayout.horizontalPadding)
        print("PASS: \(model.chapters.count) chapters, \(checkedColumns) columns; no source overflow, loss, duplication, or reading-anchor drift across six window sizes.")
    }
}
