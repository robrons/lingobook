import Foundation

/// Wikipedia, as the tutor's reference shelf.
///
/// An 8B model doesn't *contain* the history of a book, the life of its author, or what
/// a `quinquina` is — no prompt can fix that, because the facts were never in the
/// weights. What can be fixed is what sits in front of it when it answers. Everything in
/// this file exists to put real text there: fetched once per book at import, or looked
/// up per question, and cached so the second ask costs nothing.
///
/// Deliberately keyless and free. A paid search API would have been the other route, and
/// the whole reason for a local model here is that no key, no bill, and no account stand
/// between the reader and an answer.

// MARK: - Values

struct WikiSearchHit: Sendable {
    /// The canonical page title, which is what the summary endpoint wants.
    let title: String
    /// Wikipedia's own one-liner — "novel by Alexandre Dumas", "French writer". This is
    /// what lets us tell the novel from the sandwich without reading the article.
    let description: String?
}

struct WikiSummary: Codable, Sendable {
    let title: String
    /// Plain text, one to three paragraphs. Already stripped of markup by the API.
    let extract: String
    let description: String?
    let url: String
    /// A disambiguation page is a list of links, not an article. Its extract reads as
    /// "X may refer to:" and is worse than nothing in a prompt.
    let isDisambiguation: Bool
}

protocol WikipediaClient: Sendable {
    func search(_ query: String, language: String) async throws -> [WikiSearchHit]
    func summary(title: String, language: String) async throws -> WikiSummary?
}

// MARK: - Settings

enum TutorSettings {
    /// Mirrors the Settings toggle. Read here rather than through `@AppStorage` because
    /// most callers aren't views. Unset means on — the feature ships enabled.
    static var wikipediaLookupEnabled: Bool {
        UserDefaults.standard.object(forKey: "wikipediaLookupEnabled") as? Bool ?? true
    }
}

// MARK: - Client

struct WikipediaService: WikipediaClient {

    static let shared = WikipediaService()

    /// Wikimedia asks automated traffic to identify itself and offer a way to get in
    /// touch, and answers generic user agents with 403s. Ours names the app and points
    /// at its source.
    private static let userAgent =
        "LingoBook/1.0 (macOS reading app; https://github.com/robrons/lingobook)"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        // Short: a lookup that hasn't landed in a few seconds has already missed the
        // window where it could have helped this question.
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func search(_ query: String, language: String) async throws -> [WikiSearchHit] {
        var components = URLComponents(
            string: "https://\(language).wikipedia.org/w/rest.php/v1/search/page"
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url else { return [] }

        let (data, response) = try await Self.session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.pages.map { WikiSearchHit(title: $0.title, description: $0.description) }
    }

    func summary(title: String, language: String) async throws -> WikiSummary? {
        // The REST path wants underscores for spaces, then ordinary percent-encoding.
        // Anything outside the unreserved set is escaped, including the slash — a title
        // containing one would otherwise split into two path components.
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let escaped = title
            .replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: unreserved)

        guard let escaped,
              let url = URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(escaped)")
        else { return nil }

        let (data, response) = try await Self.session.data(from: url)
        // 404 is an ordinary outcome here — plenty of terms have no article.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let decoded = try JSONDecoder().decode(SummaryResponse.self, from: data)
        let extract = decoded.extract?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !extract.isEmpty else { return nil }

        return WikiSummary(
            title: decoded.title,
            extract: extract,
            description: decoded.description,
            url: decoded.content_urls?.desktop?.page ?? "",
            isDisambiguation: decoded.type == "disambiguation"
        )
    }

    // MARK: Wire format

    private struct SearchResponse: Decodable {
        struct Page: Decodable {
            let title: String
            let description: String?
        }
        let pages: [Page]
    }

    private struct SummaryResponse: Decodable {
        struct URLs: Decodable {
            struct Desktop: Decodable { let page: String? }
            let desktop: Desktop?
        }
        let title: String
        let extract: String?
        let description: String?
        let type: String?
        let content_urls: URLs?
    }
}

// MARK: - Cache

/// Looked-up articles, kept on disk between launches.
///
/// Misses are cached alongside hits. Without that, a question about a term Wikipedia has
/// never heard of would pay the full network round trip every single time it's asked —
/// and "what does he mean here?" gets asked about the same word more than once.
actor WikiCache {

    static let shared = WikiCache()

    private let directory: URL
    private let lifetime: TimeInterval = 30 * 24 * 60 * 60
    private let byteCap = 5 * 1024 * 1024

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LingoBook/WikiCache", isDirectory: true)
    }

    private struct Entry: Codable {
        let storedAt: Date
        /// Nil records a term Wikipedia had nothing for.
        let summary: WikiSummary?
    }

    func cached(term: String, language: String) -> WikiSummary?? {
        let url = fileURL(term: term, language: language)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              Date().timeIntervalSince(entry.storedAt) < lifetime
        else { return nil }
        // Double optional: the outer says "we have an answer", the inner carries it —
        // and a cached miss is an answer.
        return .some(entry.summary)
    }

    func store(_ summary: WikiSummary?, term: String, language: String) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let entry = Entry(storedAt: Date(), summary: summary)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(term: term, language: language))

        evictIfNeeded()
    }

    private func evictIfNeeded() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        let sized = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ), let size = values.fileSize, let modified = values.contentModificationDate
            else { return nil }
            return (url, size, modified)
        }

        var total = sized.reduce(0) { $0 + $1.1 }
        guard total > byteCap else { return }

        for (url, size, _) in sized.sorted(by: { $0.2 < $1.2 }) {
            try? fileManager.removeItem(at: url)
            total -= size
            if total <= byteCap { break }
        }
    }

    private func fileURL(term: String, language: String) -> URL {
        directory.appendingPathComponent("\(language)-\(Self.key(term)).json")
    }

    /// A stable filename for a term.
    ///
    /// FNV-1a rather than `hashValue`: Swift's hashing is seeded per process, so a cache
    /// written today would be unfindable tomorrow.
    static func key(_ term: String) -> String {
        let normalized = term
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Lookup (§2 support)

/// One cache-first lookup, shared by the per-question reference block.
struct WikiLookup: Sendable {

    let client: any WikipediaClient
    let cache: WikiCache

    init(client: any WikipediaClient = WikipediaService.shared, cache: WikiCache = .shared) {
        self.client = client
        self.cache = cache
    }

    /// Resolves one term to an article, English first and the book's own language second.
    ///
    /// English first because the tutor answers in English by default and its extracts are
    /// the ones a learner can read; the book's wiki is the fallback that knows about the
    /// regional and period-specific things an English encyclopedia never covered.
    func article(for term: String, bookLanguage: String?) async -> WikiSummary? {
        var languages = ["en"]
        if let bookLanguage, bookLanguage != "en" { languages.append(bookLanguage) }

        for language in languages {
            if let cached = await cache.cached(term: term, language: language) {
                if let hit = cached { return hit }
                continue  // a cached miss for this wiki; try the next one
            }

            let found = await resolve(term: term, language: language)
            await cache.store(found, term: term, language: language)
            if let found { return found }
        }
        return nil
    }

    private func resolve(term: String, language: String) async -> WikiSummary? {
        // Straight to the summary endpoint first: for an exact title this is one request
        // instead of two, and most looked-up names are exact titles.
        if let direct = try? await client.summary(title: term, language: language),
           !direct.isDisambiguation {
            return direct
        }

        guard let hits = try? await client.search(term, language: language) else { return nil }
        for hit in hits.prefix(2) {
            if let summary = try? await client.summary(title: hit.title, language: language),
               !summary.isDisambiguation {
                return summary
            }
        }
        return nil
    }
}

// MARK: - Book grounding (§1 support)

/// What Wikipedia knows about a book and its author, matched conservatively.
struct BookGrounder: Sendable {

    let client: any WikipediaClient

    init(client: any WikipediaClient = WikipediaService.shared) {
        self.client = client
    }

    struct Result: Sendable {
        var aboutBook: String?
        var aboutAuthor: String?
        var sources: [String] = []
        /// Whether Wikipedia answered at all.
        ///
        /// "It has no article on this book" and "we never got to ask" look identical in
        /// the fields above and mean opposite things: the first is final, the second is
        /// worth retrying the moment there's a network again.
        var reachedWikipedia = false
    }

    /// Roughly a page of prose. Long enough to carry publication history and reception,
    /// short enough that two of them don't crowd the page the reader is actually on.
    private static let extractLimit = 1_200

    func ground(title: String, author rawAuthor: String, language: String?) async -> Result {
        var result = Result()
        let author = Self.naturalOrder(rawAuthor)

        let wikis = ["en", language].compactMap { $0 }.filter { $0 != "unknown" }
        var seen = Set<String>()
        let languages = wikis.filter { seen.insert($0).inserted }

        for wiki in languages {
            do {
                if result.aboutBook == nil,
                   let work = try await matchWork(title: title, author: author, language: wiki) {
                    result.aboutBook = Self.trim(work.extract)
                    if !work.url.isEmpty { result.sources.append(work.url) }
                }
                if result.aboutAuthor == nil, author != "Unknown Author",
                   let person = try await matchAuthor(author, language: wiki) {
                    result.aboutAuthor = Self.trim(person.extract)
                    if !person.url.isEmpty { result.sources.append(person.url) }
                }
                result.reachedWikipedia = true
            } catch {
                // No network, or Wikipedia refused us. Leave `reachedWikipedia` false so
                // the caller retries rather than recording a verdict it never got.
                continue
            }
            if result.aboutBook != nil && result.aboutAuthor != nil { break }
        }

        return result
    }

    // MARK: Matching

    /// A wrong article is worse than none.
    ///
    /// The extract gets injected as trusted background — the prompt tells the model to
    /// prefer it over its own memory — so an article about the Monte Cristo *sandwich*
    /// would actively make the tutor worse than it is today. Both matchers below would
    /// rather return nothing than guess, and the caller simply omits the block.
    private func matchWork(title: String, author: String, language: String) async throws -> WikiSummary? {
        guard title != "Unknown Title" else { return nil }
        let query = author == "Unknown Author" ? title : "\(title) \(author)"
        // Deliberately not `try?`: a failure here is the network, and the caller has to
        // be able to tell that apart from an honest "no such article".
        let hits = try await client.search(query, language: language)

        let surname = Self.fold(author.split(separator: " ").last.map(String.init) ?? author)

        /// The test that always has to hold. A film adaptation shares both the title and
        /// the author's name — "French drama film" is the only thing that separates it
        /// from the novel it was made from.
        func isAWork(_ hit: WikiSearchHit) -> Bool {
            let described = Self.fold(hit.description ?? "")
            return ["novel", "book", "roman", "livre", "poem", "poème",
                    "play", "pièce", "story", "nouvelle", "essay", "essai"]
                .contains { described.contains($0) }
        }

        func namesTheAuthor(_ hit: WikiSearchHit) -> Bool {
            author != "Unknown Author" && Self.fold(hit.description ?? "").contains(surname)
        }

        // Strongest evidence first, because relevance order alone is not enough to trust:
        // searching "Pride and Prejudice Jane Austen" puts *Pride and Prejudice and
        // Zombies* — a genuine novel, by Seth Grahame-Smith — above the real one.
        //
        //  1. right title and right author: unambiguous.
        //  2. right title alone: the author's name isn't always in the description.
        //  3. right author alone: how a French novel finds its English article, where
        //     “Le Comte de Monte-Cristo” is filed as “The Count of Monte Cristo”.
        //
        // Titles are compared exactly (bar a parenthetical qualifier). Substring matching
        // was what let the Zombies parody through, and it buys nothing that pass 3 and the
        // French fallback don't already cover.
        let candidates = hits.prefix(5).filter(isAWork)
        let ranked =
            candidates.filter { Self.sameTitle($0.title, title) && namesTheAuthor($0) }
            + candidates.filter { Self.sameTitle($0.title, title) }
            + candidates.filter(namesTheAuthor)

        var tried = Set<String>()
        for hit in ranked where tried.insert(hit.title).inserted {
            if let summary = try? await client.summary(title: hit.title, language: language),
               !summary.isDisambiguation {
                return summary
            }
        }
        return nil
    }

    private func matchAuthor(_ author: String, language: String) async throws -> WikiSummary? {
        let hits = try await client.search(author, language: language)

        let people = hits.prefix(4).filter { hit in
            let described = Self.fold(hit.description ?? "")
            return ["writer", "écrivain", "novelist", "romancier",
                    "poet", "poète", "author", "auteur", "playwright",
                    "dramaturge", "journalist", "journaliste", "philosopher"]
                .contains { described.contains($0) }
        }

        // Exact first: "Alexandre Dumas" and "Alexandre Dumas fils" are two writers, and
        // only one of them wrote the book in hand.
        let ranked = people.filter { Self.sameTitle($0.title, author) }
            + people.filter { Self.fold($0.title).hasPrefix(Self.fold(author)) }

        var tried = Set<String>()
        for hit in ranked where tried.insert(hit.title).inserted {
            if let summary = try? await client.summary(title: hit.title, language: language),
               !summary.isDisambiguation {
                return summary
            }
        }
        return nil
    }

    /// True when two titles are the same, ignoring case, accents, and a parenthetical
    /// qualifier — "Les Misérables" against "Les Miserables (novel)".
    private static func sameTitle(_ candidate: String, _ wanted: String) -> Bool {
        let a = fold(candidate.replacingOccurrences(
            of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression))
        let b = fold(wanted)
        return !a.isEmpty && a == b
    }

    /// "Hugo, Victor" as the reader would say it. EPUB `dc:creator` is routinely filed
    /// surname-first, which matches no Wikipedia article title at all.
    static func naturalOrder(_ author: String) -> String {
        let parts = author.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return author }
        let surname = parts[0].trimmingCharacters(in: .whitespaces)
        let given = parts[1].trimmingCharacters(in: .whitespaces)
        guard !surname.isEmpty, !given.isEmpty else { return author }
        return "\(given) \(surname)"
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cuts at a sentence boundary, so an extract never ends mid-clause.
    private static func trim(_ extract: String) -> String {
        guard extract.count > extractLimit else { return extract }
        let clipped = String(extract.prefix(extractLimit))
        if let lastStop = clipped.lastIndex(where: { ".!?".contains($0) }) {
            return String(clipped[...lastStop])
        }
        return clipped + "…"
    }
}
