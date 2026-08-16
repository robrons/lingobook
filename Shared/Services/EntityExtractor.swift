import Foundation
import NaturalLanguage

/// What a question is *about*, extracted on device.
///
/// This is the retrieval half of the tutor's reference lookup, and it is deliberately
/// plain code rather than a tool the model calls. An 8B model asked to decide when to
/// search does it at the wrong moments, rewrites the query into something unrecognisable,
/// and costs a full extra inference pass per attempt. Here the model never decides
/// anything: the question is read for names and quoted phrases, those are looked up, and
/// whatever comes back is put in front of it, labelled as possibly irrelevant.
///
/// Pure and synchronous by design — no network, no state — so its behaviour on a list of
/// real questions can be checked without a model or a server anywhere in sight.
enum EntityExtractor {

    /// At most three, because each one costs a lookup and a slice of context, and a
    /// question about more than three things is really a question about a chapter.
    static let maximumTerms = 3

    /// Terms worth looking up in the reader's question.
    ///
    /// - Parameter excluding: the book's title and author. Both are already covered by
    ///   the standing "about this book" block, and re-fetching them per question would
    ///   spend the budget saying what the prompt has said all along.
    static func terms(in question: String, excluding: [String] = []) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        let blocked = Set(
            excluding.flatMap { $0.split(separator: " ").map { fold(String($0)) } }
                     .filter { $0.count > 2 }
        ) .union(excluding.map(fold))

        /// - Parameter inferred: true for terms we picked out of the phrasing rather than
        ///   ones the reader marked. Those get the stricter reading, because a pattern
        ///   like "what is …" happily captures "happening on this page".
        func consider(_ raw: String, inferred: Bool = true) {
            let term = clean(raw)
            let key = fold(term)
            guard term.count >= 3, term.count <= 60 else { return }
            guard !seen.contains(key) else { return }

            // Any word of the book's own title or author's name: §1 covers the book
            // itself, so "what is Les Misérables about" needs no encyclopedia at all.
            let words = key.split(separator: " ").map(String.init)
            guard !blocked.contains(key), !words.contains(where: blocked.contains) else { return }

            guard !isStopPhrase(key) else { return }
            if inferred, words.contains(where: deictic.contains) { return }

            // "Who was Marshal Ney?" yields both "Marshal Ney" and "Ney" — and looking up
            // the second returns an end-blown Persian flute, which is exactly the kind of
            // confident irrelevance this whole feature exists to keep out of the prompt.
            if found.contains(where: {
                let other = fold($0)
                return other.contains(key) || key.contains(other)
            }) { return }

            seen.insert(key)
            found.append(term)
        }

        // Order matters: a reader who put quotes around something has told us exactly
        // what they're asking about, which beats anything we could infer.
        quoted(in: question).forEach { consider($0, inferred: false) }
        definitional(in: question).forEach { consider($0) }
        names(in: question).forEach { consider($0, inferred: false) }

        return Array(found.prefix(maximumTerms))
    }

    // MARK: - Passes

    /// Text inside quotation marks, in the several shapes a French page invites.
    private static func quoted(in question: String) -> [String] {
        let patterns = [
            #"«\s*([^»]{2,60})\s*»"#,
            #"“([^”]{2,60})”"#,
            #""([^"]{2,60})""#,
            #"‘([^’]{2,60})’"#
        ]
        return patterns.flatMap { captures(of: $0, in: question) }
    }

    /// The subject of a definitional question.
    ///
    /// These catch the common nouns that named-entity recognition is built to ignore —
    /// "what's quinquina" is exactly the question a reader of a French novel asks, and
    /// `quinquina` is not a name.
    private static func definitional(in question: String) -> [String] {
        let patterns = [
            #"(?i)\bwhat(?:'s| is| are| was| were)\s+(?:an?\s+|the\s+)?(.{2,60})"#,
            #"(?i)\bwho(?:'s| is| are| was| were)\s+(?:an?\s+|the\s+)?(.{2,60})"#,
            #"(?i)\bwhat does\s+(.{2,60}?)\s+mean\b"#,
            #"(?i)\bqu'est-ce que\s+(?:le\s+|la\s+|les\s+|l'|un\s+|une\s+)?(.{2,60})"#,
            #"(?i)\bqui (?:est|était|sont|étaient)\s+(?:le\s+|la\s+|les\s+)?(.{2,60})"#,
            #"(?i)\bc'est quoi\s+(?:le\s+|la\s+|les\s+|l'|un\s+|une\s+)?(.{2,60})"#,
            #"(?i)\bque veut dire\s+(.{2,60})"#,
            #"(?i)\bque signifie\s+(.{2,60})"#
        ]
        return patterns.flatMap { captures(of: $0, in: question) }.map(firstClause)
    }

    /// People, places, and organisations, courtesy of the system's own tagger.
    private static func names(in question: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = question

        var results: [String] = []
        let wanted: Set<NLTag> = [.personalName, .placeName, .organizationName]

        tagger.enumerateTags(
            in: question.startIndex..<question.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, range in
            if let tag, wanted.contains(tag) {
                results.append(String(question[range]))
            }
            return true
        }
        return results
    }

    // MARK: - Cleanup

    /// Everything up to the first clause boundary.
    ///
    /// "what is quinquina and why is she making it?" asks about one thing, not about the
    /// eight words that follow it. Without this the lookup goes out for the whole tail of
    /// the sentence and finds nothing at all.
    private static func firstClause(_ value: String) -> String {
        var text = value
        let breaks = [",", ";", "?", "!", ".", " and ", " or ", " but ", " et ", " ou ",
                      " mais ", " why ", " pourquoi ", " when ", " quand "]
        for boundary in breaks {
            if let range = text.range(of: boundary, options: [.caseInsensitive]) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text
    }

    private static func clean(_ value: String) -> String {
        var text = firstClause(value).trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "«»\"“”‘’.,;:!?()[]"))
        // A leading article survives the pattern's own optional group when the question
        // phrases it differently ("what is the quinquina she's making").
        for article in ["the ", "a ", "an ", "le ", "la ", "les ", "l'", "un ", "une ", "des ", "du "] {
            if text.lowercased().hasPrefix(article) {
                text = String(text.dropFirst(article.count))
                break
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Phrases that survive the patterns but are worthless as encyclopedia queries.
    private static func isStopPhrase(_ folded: String) -> Bool {
        let phrases: Set<String> = [
            "this", "that", "it", "he", "she", "they", "him", "her", "them",
            "this page", "the page", "this chapter", "the chapter", "this book",
            "the book", "this word", "the word", "this sentence", "the sentence",
            "happening", "going on", "the point", "the meaning", "meaning",
            "cette page", "ce chapitre", "ce livre", "ce mot", "cette phrase",
            "ca", "cela", "ceci", "il", "elle", "ils", "elles"
        ]
        if phrases.contains(folded) { return true }
        // A "term" of six words is a sentence fragment, not something with an article.
        return folded.split(separator: " ").count > 5
    }

    /// Words that point at the text in front of the reader rather than out at the world.
    ///
    /// A question containing one of these is answered by the page, which the tutor
    /// already has. Wikipedia has nothing to add about "this page".
    private static let deictic: Set<String> = [
        "this", "that", "these", "those", "here", "there", "it",
        "page", "chapter", "book", "sentence", "paragraph", "passage", "line", "word",
        "happening", "going", "meaning", "means",
        "cette", "ce", "ces", "cet", "ici", "page", "chapitre", "livre",
        "phrase", "paragraphe", "ligne", "mot", "passe"
    ]

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func captures(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }
}

// MARK: - The reference block

/// What a lookup found: the text for the model, and the article names for the reader.
///
/// The reader gets the names because retrieval that happens invisibly can't be judged.
/// An answer that leaned on an encyclopedia should say which one, so a wrong answer can
/// be traced to a wrong article rather than blamed on the model.
struct ReferenceNotes: Sendable {
    let block: String
    let titles: [String]
}

/// Turns a question into the notes that ride along with it.
struct ReferenceLookup: Sendable {

    let lookup: WikiLookup

    init(lookup: WikiLookup = WikiLookup()) {
        self.lookup = lookup
    }

    /// Short enough that three of them still leave the page as the biggest thing in the
    /// newest turn — the reader's own book must stay the centre of attention.
    private static let extractLimit = 600

    /// Reference notes for one question, or nil when there is nothing worth attaching.
    ///
    /// - Parameter budget: how long the whole lookup may take. On expiry the question
    ///   goes out exactly as it does today. A lookup is allowed to delay an answer a
    ///   little; it is never allowed to prevent one.
    func referenceBlock(
        for question: String,
        bookLanguage: String?,
        excluding: [String],
        budget: Duration = .seconds(2)
    ) async -> ReferenceNotes? {
        guard TutorSettings.wikipediaLookupEnabled else { return nil }

        let terms = EntityExtractor.terms(in: question, excluding: excluding)
        guard !terms.isEmpty else { return nil }

        let articles = await withTaskGroup(of: (Int, WikiSummary?).self) { group -> [WikiSummary] in
            for (index, term) in terms.enumerated() {
                group.addTask {
                    (index, await lookup.article(for: term, bookLanguage: bookLanguage))
                }
            }
            group.addTask {
                try? await Task.sleep(for: budget)
                return (-1, nil)
            }

            var found: [(Int, WikiSummary)] = []
            var settled = 0
            for await (index, summary) in group {
                if index == -1 { break }        // the budget ran out
                if let summary { found.append((index, summary)) }
                settled += 1
                if settled == terms.count { break }
            }
            group.cancelAll()
            // Back into the order the reader wrote them in; a task group answers in
            // whatever order the network happens to finish.
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }

        guard !articles.isEmpty else { return nil }

        let notes = articles.map { "— \($0.title): \(Self.trim($0.extract))" }
        return ReferenceNotes(
            block: """
            Notes looked up from Wikipedia for this question. They may be irrelevant — use \
            them only if they answer what was asked, and say when an answer comes from them:
            \(notes.joined(separator: "\n"))
            """,
            titles: articles.map(\.title)
        )
    }

    private static func trim(_ extract: String) -> String {
        guard extract.count > extractLimit else { return extract }
        let clipped = String(extract.prefix(extractLimit))
        if let lastStop = clipped.lastIndex(where: { ".!?".contains($0) }) {
            return String(clipped[...lastStop])
        }
        return clipped + "…"
    }
}
