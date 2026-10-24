import Foundation
import CoreGraphics
import SwiftUI

#if os(macOS)
import AppKit
public typealias PlatformFont = NSFont
#else
import UIKit
public typealias PlatformFont = UIFont
#endif

/// Page metrics shared by `PageView` (which renders) and `ReaderViewModel` (which
/// paginates). Both read from here: if the two disagree, text either clips at the
/// bottom of a page or leaves a gap.
enum ReaderLayout {
    /// Comfortable measure, ~65–75 characters a line. Without a cap, a full-screen
    /// Mac window stretches lines past 90 characters and reading falls apart.
    #if os(tvOS)
    // Type on a television is roughly twice the size, so the same ~70-character measure
    // needs twice the width.
    static let maxTextWidth: CGFloat = 1300
    #else
    static let maxTextWidth: CGFloat = 650
    #endif

    /// Measured from Apple Books showing the same book on a 1470pt-wide display: 88pt of
    /// margin either side. Generous framing is most of why a page reads as a page rather
    /// than as a document — Books gives its text *less* room than this app used to, and
    /// looks the better for it.
    #if os(macOS)
    static let horizontalPadding: CGFloat = 88
    #elseif os(tvOS)
    // On top of the TV's own safe-area inset, which already keeps clear of the bezel.
    static let horizontalPadding: CGFloat = 40
    #else
    static let horizontalPadding: CGFloat = 28
    #endif

    /// A little breathing room in addition to the controls, not a second full margin.
    /// Reserving 56 points above AND below the chrome cost 112 points of reading height.
    static let verticalPadding: CGFloat = 16

    /// Gap between the two columns of an interleaved spread. Books uses ~99pt; below
    /// about this the eye starts jumping the gutter mid-line.
    static let columnGutter: CGFloat = 96

    /// Below this the window stays single-column.
    ///
    /// Raised from 1000, where a 1032pt window cleared the bar and then split into two
    /// 380pt columns of about 35 characters — too narrow to read. Books waits for real
    /// width before going to two columns, and at 1200 so does this.
    ///
    /// A television is always wide enough. One 1300pt column there ran to ~95 characters
    /// a line and left the lower half of the screen empty; two facing pages of ~800pt
    /// each read like an open book, which is what Books does on any wide screen.
    static let twoColumnMinWidth: CGFloat = 1200

    /// Room kept for the toolbar and scrubber that float above the page.
    ///
    /// Reserved whether the chrome is showing or not, and that constancy is the whole
    /// point: the text's geometry can't depend on chrome visibility, or every fade
    /// would repaginate the chapter and shuffle the reader's place.
    ///
    /// The toolbar needs 54 points; the footer is now just a label with bottom padding.
    /// Do not keep reserving the removed scrubber's 58-point height.
    #if os(macOS)
    static let chromeTopInset: CGFloat = 54
    static let chromeBottomInset: CGFloat = 30
    #elseif os(tvOS)
    // Bands above and below the spread, as Books keeps its toolbar off the text: the
    // running heads live in them while reading, and the controls take them over when
    // shown. Nothing that appears ever covers a line.
    static let chromeTopInset: CGFloat = 80
    static let chromeBottomInset: CGFloat = 56
    #else
    static let chromeTopInset: CGFloat = 64
    // A 44-point button row plus 14 points below it, kept constant when hidden.
    static let chromeBottomInset: CGFloat = 58
    #endif

    static var topContentInset: CGFloat { verticalPadding + chromeTopInset }
    static var bottomContentInset: CGFloat { verticalPadding + chromeBottomInset }
    static var totalVerticalInset: CGFloat { topContentInset + bottomContentInset }

    /// Shared by measurement and rendering, including at widths above the line-length cap.
    static func columnWidth(in pageWidth: CGFloat, columns: Int) -> CGFloat {
        let count = max(1, columns)
        let inner = pageWidth - horizontalPadding * 2 - CGFloat(count - 1) * columnGutter
        return max(1, min(inner / CGFloat(count), maxTextWidth))
    }

    static let paragraphSpacing: CGFloat = 16

    /// A book paragraph's first-line indent, as Books sets it: a little over an em.
    static func firstLineIndent(size: CGFloat) -> CGFloat { (size * 1.2).rounded() }
    #if os(tvOS)
    // A fixed 6pt was ~0.35em at Mac sizes but under 0.2em at television sizes, which
    // set lines noticeably tighter than Books. Scaled by `ReadingStyle.lineSpacingScale`.
    static let bodyLineSpacing: CGFloat = 10
    #else
    static let bodyLineSpacing: CGFloat = 6
    #endif

    static let titleSizeIncrease: CGFloat = 8
    static let titleBottomPadding: CGFloat = 8

    static let translationScale: CGFloat = 0.9

    /// Room left at the end of an italic translation's lines: slanted letters lean past
    /// the line's end, and a text view clips whatever leans out of it.
    static let italicOverhang: CGFloat = 16
    static let translationLineSpacing: CGFloat = 4
    static let interleavedPairSpacing: CGFloat = 4
    // Trimmed from 8/12: Books sets paragraphs far tighter than this, and every point
    // of padding here is multiplied by every pair on the page.
    static let interleavedTranslationBottomPadding: CGFloat = 4
    static let interleavedPairBottomPadding: CGFloat = 10

    /// The air PageView renders below a pair's translation. Between pairs the paginator
    /// charges it as spacing; below a column's last pair it overlaps the leftover and
    /// costs nothing — which is why pair heights are measured without it.
    static var interleavedTrailingDecoration: CGFloat {
        interleavedTranslationBottomPadding + interleavedPairBottomPadding
    }
}

/// Measures text by asking SwiftUI itself, via a hidden hosting controller.
///
/// The previous approach modelled SwiftUI with TextKit (`boundingRect`), and the model
/// was ~15% short per column: TextKit and SwiftUI `Text` disagree about New York's line
/// height, and the error compounds line by line. Modelling a renderer is a losing game —
/// so instead this builds the *exact* view `PageView` draws and asks it for its size.
/// Measured and rendered can no longer disagree, because they are the same code path.
@MainActor
enum ReaderTextMeasurer {
    #if os(macOS)
    private static let hosting = NSHostingController(rootView: AnyView(EmptyView()))
    #else
    private static let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    #endif

    /// Pagination re-measures the same sentences on every pass (and `split` measures
    /// candidates repeatedly). Hosting-controller layout isn't free, so memoise.
    private static var cache: [String: CGFloat] = [:]

    private static func measure(_ view: some View, width: CGFloat, cacheKey: String) -> CGFloat {
        if let hit = cache[cacheKey] { return hit }

        hosting.rootView = AnyView(
            view.frame(width: width, alignment: .leading)
        )
        let size = hosting.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        let height = ceil(size.height)

        if cache.count > 8192 { cache.removeAll(keepingCapacity: true) }
        cache[cacheKey] = height
        return height
    }

    /// Height of a body paragraph or chapter title — the same view PageView renders.
    ///
    /// Body text is justified and hyphenated, which changes where lines break and so how
    /// tall a paragraph is; measuring an unjustified copy would put the page break in a
    /// different place than the renderer does. Chapter titles set ragged, as in Books,
    /// and pass `justified: false`.
    static func height(
        of text: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        lineSpacing: CGFloat,
        width: CGFloat,
        justified: Bool = true,
        style: ReadingStyle = ReadingStyle()
    ) -> CGFloat {
        guard width > 0, !text.isEmpty else { return 0 }

        let key = "t|\(Int(width))|\(size)|\(weight)|\(lineSpacing)|\(justified)|\(style.cacheKey)|\(text)"

        guard justified else {
            return measure(
                Text(text)
                    .font(style.titleFont(size: size, weight: weight))
                    .lineSpacing(lineSpacing)
                    .fixedSize(horizontal: false, vertical: true),
                width: width,
                cacheKey: key
            )
        }

        return measure(
            JustifiedText(
                text: text,
                fontSize: size,
                weight: weight.platformWeight,
                lineSpacing: lineSpacing,
                color: .primary,
                style: style
            )
            .fixedSize(horizontal: false, vertical: true),
            width: width,
            cacheKey: key
        )
    }

    /// Height of a paragraph as the book layout sets it: indent, and line limit if it's
    /// the part that ends a page.
    static func height(
        of paragraph: ReaderParagraph,
        size: CGFloat,
        lineSpacing: CGFloat,
        width: CGFloat,
        style: ReadingStyle
    ) -> CGFloat {
        guard paragraph.indented || paragraph.lineLimit != nil else {
            return height(of: paragraph.text, size: size, lineSpacing: lineSpacing, width: width, style: style)
        }
        guard width > 0, !paragraph.text.isEmpty else { return 0 }
        let indent = paragraph.indented ? ReaderLayout.firstLineIndent(size: size) : 0
        let key = "b|\(Int(width))|\(size)|\(lineSpacing)|\(style.cacheKey)|\(indent)|\(paragraph.lineLimit ?? 0)|\(paragraph.text)"
        return measure(
            JustifiedText(
                text: paragraph.text,
                fontSize: size,
                lineSpacing: lineSpacing,
                color: .primary,
                style: style,
                firstLineIndent: indent,
                lineLimit: paragraph.lineLimit
            )
            .fixedSize(horizontal: false, vertical: true),
            width: width,
            cacheKey: key
        )
    }

    /// Where each line of a paragraph ends, as UTF-16 offsets — laid out by the same
    /// engine, with the same string and width, that `JustifiedText` draws it with.
    static func lineEnds(
        of paragraph: ReaderParagraph,
        size: CGFloat,
        lineSpacing: CGFloat,
        width: CGFloat,
        style: ReadingStyle
    ) -> [Int] {
        let attributed = JustifiedTextStyle.attributed(
            paragraph.text,
            fontSize: size,
            weight: .regular,
            italic: false,
            lineSpacing: lineSpacing,
            color: .primary,
            style: style,
            firstLineIndent: paragraph.indented ? ReaderLayout.firstLineIndent(size: size) : 0
        )
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        // An indent is a lead character the paragraph's own text doesn't have.
        let lead = paragraph.indented ? (JustifiedTextStyle.indentMark as NSString).length : 0
        var ends: [Int] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, glyphs, _ in
            ends.append(max(0, NSMaxRange(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)) - lead))
        }
        return ends
    }

    /// Height of one interleaved unit's *text*: source with its translation beneath,
    /// mirroring PageView's pair layout — but without the pair's trailing paddings.
    ///
    /// Those paddings (see `ReaderLayout.interleavedTrailingDecoration`) are air below
    /// the translation. Between two pairs they're real spacing and the paginator charges
    /// them as such; below the last pair in a column they'd just bleed into the leftover
    /// — and charging for them there once cost a column its final pair by 14 points.
    ///
    /// The translation hasn't arrived at pagination time, so the source text stands in
    /// for it — French runs longer than its English, so this errs toward leaving room
    /// rather than clipping.
    static func interleavedPairHeight(
        text: String,
        translation: String? = nil,
        fontSize: CGFloat,
        width: CGFloat,
        style: ReadingStyle = ReadingStyle()
    ) -> CGFloat {
        guard width > 0, !text.isEmpty || !(translation ?? "").isEmpty else { return 0 }
        if text.isEmpty, let translation {
            // The English of a sentence whose French ended the previous column.
            return measure(
                JustifiedText(
                    text: translation,
                    fontSize: fontSize * ReaderLayout.translationScale,
                    italic: true,
                    lineSpacing: ReaderLayout.translationLineSpacing * style.lineSpacingScale,
                    color: .primary,
                    style: style
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, ReaderLayout.italicOverhang),
                width: width,
                cacheKey: "pt|\(Int(width))|\(fontSize)|\(style.cacheKey)|\(translation)"
            )
        }
        return measure(
            VStack(alignment: .leading, spacing: ReaderLayout.interleavedPairSpacing) {
                JustifiedText(
                    text: text,
                    fontSize: fontSize,
                    lineSpacing: ReaderLayout.bodyLineSpacing * style.lineSpacingScale,
                    color: .primary,
                    style: style
                )
                .fixedSize(horizontal: false, vertical: true)

                JustifiedText(
                    text: translation ?? text,
                    fontSize: fontSize * ReaderLayout.translationScale,
                    italic: true,
                    lineSpacing: ReaderLayout.translationLineSpacing * style.lineSpacingScale,
                    color: .primary,
                    style: style
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, ReaderLayout.italicOverhang)
            },
            width: width,
            cacheKey: "p|\(Int(width))|\(fontSize)|\(style.cacheKey)|\(text)|\(translation ?? "")"
        )
    }
}

extension Font.Weight {
    /// The `NSFont`/`UIFont` weight matching this SwiftUI weight, for the attributed
    /// strings `JustifiedText` builds.
    var platformWeight: PlatformFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

/// Measures text as the reader actually draws it.
///
/// `PageView` renders with SwiftUI's `.system(size:weight:design:.serif)` — New York.
/// These helpers build the matching `NSFont`/`UIFont` and measure against the real
/// column width, replacing the old `characters ÷ (fontSize × 0.45)` estimate that
/// treated "W" and "i" as the same width.
///
/// Superseded by `ReaderTextMeasurer` for pagination (TextKit's idea of New York's
/// line height runs ~15% short of SwiftUI's); kept for standalone tests.
enum TextMeasurement {

    /// The serif system font (New York), matching SwiftUI's `.system(design: .serif)`.
    static func serifFont(
        size: CGFloat,
        weight: PlatformFont.Weight = .regular,
        italic: Bool = false
    ) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor

        if let serif = descriptor.withDesign(.serif) {
            descriptor = serif
        }

        if italic {
            #if os(macOS)
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic))
            #else
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) ?? descriptor
            #endif
        }

        #if os(macOS)
        return NSFont(descriptor: descriptor, size: size) ?? base
        #else
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }

    /// Height of `text` laid out in a column `width` points wide, with SwiftUI's
    /// `.lineSpacing(_:)` modelled as `NSParagraphStyle.lineSpacing`.
    static func height(
        of text: String,
        font: PlatformFont,
        lineSpacing: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        guard width > 0, !text.isEmpty else { return 0 }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraphStyle
        ])

        let bounds = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        return ceil(bounds.height)
    }
}

extension ReadingStyle {
    /// The chapter heading's font: the reading font, ragged, a touch heavier.
    func titleFont(size: CGFloat, weight: Font.Weight) -> Font {
        Font(font.platformFont(size: size, weight: self.weight(weight.platformWeight), italic: false) as CTFont)
    }
}
