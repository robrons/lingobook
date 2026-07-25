import Foundation
import CoreGraphics
import SwiftUI

#if os(iOS)
import UIKit
public typealias PlatformFont = UIFont
#else
import AppKit
public typealias PlatformFont = NSFont
#endif

/// Page metrics shared by `PageView` (which renders) and `ReaderViewModel` (which
/// paginates). Both read from here: if the two disagree, text either clips at the
/// bottom of a page or leaves a gap.
enum ReaderLayout {
    /// Comfortable measure, ~65–75 characters a line. Without a cap, a full-screen
    /// Mac window stretches lines past 90 characters and reading falls apart.
    static let maxTextWidth: CGFloat = 650

    /// Measured from Apple Books showing the same book on a 1470pt-wide display: 88pt of
    /// margin either side. Generous framing is most of why a page reads as a page rather
    /// than as a document — Books gives its text *less* room than this app used to, and
    /// looks the better for it. On a phone that much margin would eat the line, so the
    /// idiom still decides; it never changes at runtime, so paginator and renderer agree.
    static var horizontalPadding: CGFloat {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? 20 : 88
        #else
        return 88
        #endif
    }

    /// Books runs ~112pt above its first line and ~140pt below its last. With the chrome
    /// insets below, 56 lands the text at 110/114 — near enough to read the same.
    static let verticalPadding: CGFloat = 56

    /// Gap between the two columns of an interleaved spread. Books uses ~99pt; below
    /// about this the eye starts jumping the gutter mid-line.
    static let columnGutter: CGFloat = 96

    /// Below this the window stays single-column.
    ///
    /// Raised from 1000: an iPad in portrait is 1032pt, which cleared the old bar and
    /// split into two 380pt columns of about 35 characters — too narrow to read. Books
    /// only goes to two columns in landscape, and at 1200 so does this.
    static let twoColumnMinWidth: CGFloat = 1200

    /// Room kept for the toolbar and scrubber that float above the page.
    ///
    /// Reserved whether the chrome is showing or not, and that constancy is the whole
    /// point: the text's geometry can't depend on chrome visibility, or every fade
    /// would repaginate the chapter and shuffle the reader's place.
    ///
    /// Sized from what the chrome actually measures, with a little slack — the toolbar
    /// runs ~50pt (12 + 8 padding around a ~30pt row) and the scrubber ~53pt (22pt track
    /// + 7 + ~14pt labels + 10 padding). Erring small would tuck text under the bars.
    static let chromeTopInset: CGFloat = 54
    static let chromeBottomInset: CGFloat = 58

    static var topContentInset: CGFloat { verticalPadding + chromeTopInset }
    static var bottomContentInset: CGFloat { verticalPadding + chromeBottomInset }
    static var totalVerticalInset: CGFloat { topContentInset + bottomContentInset }

    static let paragraphSpacing: CGFloat = 16
    static let bodyLineSpacing: CGFloat = 6

    static let titleSizeIncrease: CGFloat = 8
    static let titleBottomPadding: CGFloat = 8

    static let translationScale: CGFloat = 0.9
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
    #if os(iOS)
    private static let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    #else
    private static let hosting = NSHostingController(rootView: AnyView(EmptyView()))
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
        justified: Bool = true
    ) -> CGFloat {
        guard width > 0, !text.isEmpty else { return 0 }

        let key = "t|\(Int(width))|\(size)|\(weight)|\(lineSpacing)|\(justified)|\(text)"

        guard justified else {
            return measure(
                Text(text)
                    .font(.system(size: size, weight: weight, design: .serif))
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
                color: .primary
            )
            .fixedSize(horizontal: false, vertical: true),
            width: width,
            cacheKey: key
        )
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
        fontSize: CGFloat,
        width: CGFloat
    ) -> CGFloat {
        guard width > 0, !text.isEmpty else { return 0 }
        return measure(
            VStack(alignment: .leading, spacing: ReaderLayout.interleavedPairSpacing) {
                JustifiedText(
                    text: text,
                    fontSize: fontSize,
                    lineSpacing: ReaderLayout.bodyLineSpacing,
                    color: .primary
                )
                .fixedSize(horizontal: false, vertical: true)

                JustifiedText(
                    text: text,
                    fontSize: fontSize * ReaderLayout.translationScale,
                    italic: true,
                    lineSpacing: ReaderLayout.translationLineSpacing,
                    color: .primary
                )
                .fixedSize(horizontal: false, vertical: true)
            },
            width: width,
            cacheKey: "p|\(Int(width))|\(fontSize)|\(text)"
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
            #if os(iOS)
            if let italicised = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
                descriptor = italicised
            }
            #else
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic))
            #endif
        }

        #if os(iOS)
        return UIFont(descriptor: descriptor, size: size)
        #else
        return NSFont(descriptor: descriptor, size: size) ?? base
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
