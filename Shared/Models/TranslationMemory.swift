import Foundation

/// A book's translations, keyed by the exact source text they translate.
///
/// Keyed by text rather than by page because pages don't survive a font change, a resize,
/// or a different screen — and the whole point is that a book translated on the Mac reads
/// on a television with completely different pagination.
///
/// Whole-book preparation stores sentences, since that's what interleaved mode shows.
/// Side-by-side mode asks for whole paragraphs; those are answered by joining the
/// paragraph's sentences, split exactly the way `ReaderViewModel` splits them.
struct TranslationMemory: Codable {
    /// Language the entries are in.
    var target: String = "en"
    var entries: [String: String] = [:]

    init() {}

    init(data: Data?) {
        guard let data, let decoded = try? PropertyListDecoder().decode(Self.self, from: data) else { return }
        self = decoded
    }

    func encoded() -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(self)
    }

    var isEmpty: Bool { entries.isEmpty }

    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The saved translation of `text`, or nil if any part of it was never translated.
    func translation(of text: String) -> String? {
        let key = Self.key(text)
        guard !key.isEmpty else { return "" }
        if let hit = entries[key] { return hit }

        // Not stored whole: a paragraph (side-by-side mode), or a line of dialogue whose
        // leading dash interleaved mode strips. Rebuild it from its sentences.
        let sentences = Self.sentences(in: key)
        guard !sentences.isEmpty else { return nil }

        var parts: [String] = []
        for sentence in sentences {
            guard let translated = entries[sentence] else { return nil }
            parts.append(translated)
        }
        return parts.joined(separator: " ")
    }

    func contains(_ text: String) -> Bool {
        entries[Self.key(text)] != nil
    }

    mutating func record(_ original: String, _ translated: String) {
        let key = Self.key(original)
        let value = translated.strippingLeadingDashes()
        guard !key.isEmpty, !value.isEmpty else { return }
        entries[key] = value
    }

    /// Sentences as the reader displays them in interleaved mode.
    static func sentences(in paragraph: String) -> [String] {
        SentenceSplitter.sentences(in: paragraph)
            .map { $0.text.strippingLeadingDashes() }
            .filter { !$0.isEmpty }
    }
}
