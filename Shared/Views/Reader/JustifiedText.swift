import SwiftUI
import CoreText
import NaturalLanguage

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Body text set the way a book sets it: justified, with hyphenation.
///
/// SwiftUI's `Text` cannot justify — `.multilineTextAlignment` offers leading, centre and
/// trailing and nothing else — so this drops to the platform text view, which has done
/// justification and hyphenation since TextKit existed.
///
/// Two details matter more than they look:
///
/// **Justification never stretches a paragraph's last line.** That is what makes this safe
/// for interleaved mode, where a "paragraph" is often a single sentence: a one-line
/// sentence *is* its own last line, so it sets flush left exactly as before rather than
/// spreading its words across the column.
///
/// **Hyphenation is language-specific.** Hyphenating French with English rules breaks
/// words in the wrong places, so the language is detected from the text itself and
/// attached to the string. Detection is memoised — pagination measures the same sentences
/// many times over.
struct JustifiedText: View {

    let text: String
    let fontSize: CGFloat
    var weight: PlatformFont.Weight = .regular
    var italic: Bool = false
    var lineSpacing: CGFloat
    var color: Color
    var style = ReadingStyle()
    var firstLineIndent: CGFloat = 0
    /// Draw only this many lines: the part of a paragraph that ends a page.
    var lineLimit: Int? = nil

    var body: some View {
        JustifiedTextRepresentable(
            attributed: JustifiedTextStyle.attributed(
                text,
                fontSize: fontSize,
                weight: weight,
                italic: italic,
                lineSpacing: lineSpacing,
                color: color,
                style: style,
                firstLineIndent: firstLineIndent
            ),
            lineLimit: lineLimit
        )
    }
}

/// Builds the attributed string both the renderer and the paginator lay out.
///
/// Anything here that changes line breaking changes page breaking, so there is exactly one
/// copy of it — `ReaderTextMeasurer` measures a `JustifiedText`, not a reconstruction of one.
enum JustifiedTextStyle {

    @MainActor private static var languageCache: [String: String] = [:]

    /// The character an attachment occupies in the string — what an indent adds.
    static let indentMark = "\u{FFFC}"

    /// A transparent pixel, stretched to an indent's width.
    @MainActor static let blank: PlatformImage = {
        #if os(macOS)
        NSImage(size: NSSize(width: 1, height: 1))
        #else
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        #endif
    }()

    /// The language the text is written in, for hyphenation.
    ///
    /// Falls back to no language attribute rather than guessing: CoreText then uses its own
    /// heuristics, which beats confidently hyphenating French by English rules.
    @MainActor static func language(of text: String) -> String? {
        // A couple of sentences is plenty to identify a language, and capping the sample
        // keeps this cheap on the long paragraphs that dominate a chapter.
        let key = String(text.prefix(120))

        if let cached = languageCache[key] {
            return cached.isEmpty ? nil : cached
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(key)
        let identifier = recognizer.dominantLanguage?.rawValue ?? ""

        if languageCache.count > 4096 { languageCache.removeAll(keepingCapacity: true) }
        languageCache[key] = identifier

        return identifier.isEmpty ? nil : identifier
    }

    @MainActor static func attributed(
        _ text: String,
        fontSize: CGFloat,
        weight: PlatformFont.Weight,
        italic: Bool,
        lineSpacing: CGFloat,
        color: Color,
        style: ReadingStyle = ReadingStyle(),
        firstLineIndent: CGFloat = 0
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = style.justified ? .justified : .natural
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping
        // Full hyphenation. Without it, justifying a narrow column opens rivers of white
        // space between words — the reason justified web text usually looks worse than
        // ragged, and the reason print has always hyphenated.
        paragraphStyle.hyphenationFactor = style.justified ? 1.0 : 0.0

        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.font.platformFont(size: fontSize, weight: style.weight(weight), italic: italic),
            .paragraphStyle: paragraphStyle
        ]

        #if os(macOS)
        attributes[.foregroundColor] = NSColor(color)
        #else
        attributes[.foregroundColor] = UIColor(color)
        #endif

        if let language = language(of: text) {
            attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = language
        }

        let kern = style.kern(size: fontSize)
        if kern > 0 { attributes[.kern] = kern }

        let result = NSMutableAttributedString(string: text, attributes: attributes)

        // The indent is a blank inline image as wide as the indent — not
        // `firstLineHeadIndent`, which the tvOS text view lays out but then draws from the
        // margin, stretching the shortened first line across the full measure. (A kerned
        // zero-width character fares no better: it's dropped before drawing, kern and
        // all.) Justification never stretches an attachment.
        if firstLineIndent > 0 {
            let attachment = NSTextAttachment()
            attachment.image = JustifiedTextStyle.blank
            attachment.bounds = CGRect(x: 0, y: 0, width: firstLineIndent, height: 1)
            let lead = NSMutableAttributedString(attachment: attachment)
            lead.addAttributes(attributes, range: NSRange(location: 0, length: lead.length))
            result.insert(lead, at: 0)
        }

        // No attribute widens only the spaces between words, but kerning a space widens
        // the gap after it — which is all word spacing is.
        let gap = style.wordGap(size: fontSize)
        if gap > 0 {
            let nsText = text as NSString
            var range = nsText.range(of: " ")
            while range.location != NSNotFound {
                result.addAttribute(.kern, value: kern + gap, range: range)
                let next = range.location + 1
                range = nsText.range(of: " ", range: NSRange(location: next, length: nsText.length - next))
            }
        }

        return result
    }
}

// MARK: - Platform text view

#if os(macOS)
private struct JustifiedTextRepresentable: NSViewRepresentable {
    let attributed: NSAttributedString
    var lineLimit: Int? = nil

    func makeNSView(context: Context) -> NSTextField {
        let view = NSTextField(labelWithString: "")
        view.isEditable = false
        view.isSelectable = true
        // Clicking a selectable NSTextField hands the text to the window's shared field
        // editor for the duration of the selection. In plain-text mode that editor keeps
        // none of the attributed string: it redraws using the *control's* own font and
        // colour, so a click dropped a 20pt justified New York page to 13pt ragged system
        // text until the selection was dismissed. Rich-text mode is what carries the
        // attributes across, and it costs nothing here — the field is not editable, so
        // there is no rich-text editing to enable, only rich-text display.
        view.allowsEditingTextAttributes = true
        view.isBezeled = false
        view.drawsBackground = false
        view.lineBreakMode = .byWordWrapping
        view.maximumNumberOfLines = 0
        view.cell?.wraps = true
        view.cell?.isScrollable = false
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSTextField, context: Context) {
        view.maximumNumberOfLines = lineLimit ?? 0
        view.attributedStringValue = attributed

        // The control's own font and colour are what the field editor falls back to. They
        // are redundant while rich text holds, and they are the difference between a
        // wrong-sized page and a merely unjustified one if it ever doesn't.
        if attributed.length > 0 {
            view.font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            view.textColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        nsView.preferredMaxLayoutWidth = width
        let fitted = nsView.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }
}
#else
private struct JustifiedTextRepresentable: UIViewRepresentable {
    let attributed: NSAttributedString
    var lineLimit: Int? = nil

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1, the engine `ReaderTextMeasurer.lineEnds` lays text out with: where
        // a page breaks a paragraph has to be where this view wraps it, to the character.
        let view = UITextView(usingTextLayoutManager: false)
        view.textContainer.lineBreakMode = .byWordWrapping
        #if !os(tvOS)
        view.isEditable = false
        #endif
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Italic letters lean past the end of the line; a text view clips them by default,
        // shaving the last letter off every justified line of an italic translation.
        view.clipsToBounds = false
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.textContainer.maximumNumberOfLines = lineLimit ?? 0
        if view.attributedText != attributed {
            view.attributedText = attributed
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }
}
#endif
