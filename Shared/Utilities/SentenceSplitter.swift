import Foundation

/// Splits prose into sentences without breaking them in the wrong places.
///
/// Foundation's `.bySentences` enumeration treats every period and exclamation mark as a
/// terminator, which is wrong for the French this app exists to read. Two failures show
/// up on nearly every page of Hugo:
///
///     "Il éclairait en face le visage de M. Madeleine."
///         → "Il éclairait en face le visage de M." + "Madeleine."
///
///     "— Blancs ! dit-il."
///         → "Blancs !" + "dit-il."
///
/// The first breaks on the abbreviation "M." (Monsieur); the second on the exclamation
/// mark that ends a line of dialogue but not the sentence carrying it. Both matter more
/// here than they would in a plain text view: each fragment becomes its own interleaved
/// unit with its own translation, and its own utterance when the book is read aloud —
/// so a bad split puts a full stop into the narrator's voice mid-name.
///
/// The repair is two rules applied after the split, both of which only ever *join*
/// fragments. Over-joining costs a slightly longer unit; over-splitting costs meaning.
enum SentenceSplitter {

    /// A sentence and where it begins in the source string.
    struct Sentence {
        let text: String
        /// Character offset from the start of the passed-in text. Reading positions are
        /// stored as offsets, so these have to survive the merge.
        let offset: Int
    }

    /// Words that end in a period without ending the sentence.
    ///
    /// Weighted toward French, since that is what gets read here, with the common English
    /// titles alongside for imported translations. Compared case- and accent-insensitively.
    private static let abbreviations: Set<String> = [
        // French courtesy titles — "M." is the one that breaks Les Misérables constantly
        "m", "mm", "mme", "mmes", "mlle", "mlles", "me", "mgr",
        // English equivalents
        "mr", "mrs", "ms", "dr", "prof", "jr", "sr",
        // Saints and places
        "st", "ste", "sts",
        // Reference and editorial shorthand
        "no", "nos", "art", "cf", "etc", "ibid", "op", "vol", "vols",
        "p", "pp", "ed", "éd", "av", "apr", "fig", "chap", "vs", "trad"
    ]

    /// Characters that can only ever *close* something, so a fragment starting with one
    /// belongs to the fragment before it.
    private static let closingMarks: Set<Character> = ["»", "”", "’", "'", ")", "]", "…"]

    /// Sentences in `text`, with the wrongly-split ones rejoined.
    static func sentences(in text: String) -> [Sentence] {
        var fragments: [Sentence] = []

        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, range, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            fragments.append(
                Sentence(text: trimmed, offset: text.distance(from: text.startIndex, to: range.lowerBound))
            )
        }

        guard fragments.count > 1 else { return fragments }

        var merged: [Sentence] = []

        for fragment in fragments {
            if let previous = merged.last, shouldJoin(previous.text, to: fragment.text) {
                // Keep the earlier offset: the joined sentence starts where the first did.
                merged[merged.count - 1] = Sentence(
                    text: previous.text + " " + fragment.text,
                    offset: previous.offset
                )
            } else {
                merged.append(fragment)
            }
        }

        return merged
    }

    /// Convenience for callers that only want the strings.
    static func sentenceTexts(in text: String) -> [String] {
        sentences(in: text).map(\.text)
    }

    // MARK: - Rules

    private static func shouldJoin(_ left: String, to right: String) -> Bool {
        endsWithAbbreviation(left) || continuesSentence(right)
    }

    /// True when `text`'s final word is an abbreviation rather than a sentence ending.
    private static func endsWithAbbreviation(_ text: String) -> Bool {
        guard text.hasSuffix(".") else { return false }

        guard let lastWord = text.split(whereSeparator: { $0.isWhitespace }).last else { return false }

        // Strip the trailing period and any quotes or brackets clinging to the word.
        let word = lastWord
            .trimmingCharacters(in: CharacterSet(charactersIn: ".\"'“”«»()[]"))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)

        guard !word.isEmpty else { return false }

        // A lone letter is an initial — "J." in "J.-C.", "A." in a name.
        if word.count == 1, word.first?.isLetter == true { return true }

        return abbreviations.contains(word)
    }

    /// True when `text` reads as the continuation of the fragment before it.
    ///
    /// A sentence in French or English never opens with a lowercase letter, so when one
    /// does, the break that produced it was spurious — the dialogue tag in
    /// "— Blancs ! dit-il." being the everyday case.
    private static func continuesSentence(_ text: String) -> Bool {
        guard let first = text.first else { return false }

        if closingMarks.contains(first) { return true }
        if first.isLowercase { return true }

        // Dashes open dialogue in French typography, so a fragment starting with one is a
        // new utterance — but a lowercase word right after it is still a continuation.
        if first == "—" || first == "–" || first == "-" {
            let rest = text.dropFirst().drop(while: { $0.isWhitespace })
            return rest.first?.isLowercase == true
        }

        return false
    }
}
