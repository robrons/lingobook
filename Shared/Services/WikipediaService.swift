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

    /// A candidate article, and which Wikipedia it came from.
    private struct Candidate {
        let hit: WikiSearchHit
        let wiki: String
    }

    func ground(title: String, author rawAuthor: String, language: String?) async -> Result {
        var result = Result()
        let author = Self.naturalOrder(rawAuthor)

        // Wikipedia is keyed by bare language, so "fr-FR" has to become "fr" — as a
        // hostname the regional form simply doesn't resolve, which silently killed the
        // fallback wiki for every book whose EPUB tagged its language that way.
        let bare = language?.split(separator: "-").first.map(String.init)
        var seen = Set<String>()
        let wikis = ["en", bare].compactMap { $0 }
            .filter { $0 != "unknown" && seen.insert($0).inserted }

        if title != "Unknown Title" {
            let (work, reached) = await bestWork(title: title, author: author, wikis: wikis)
            result.reachedWikipedia = result.reachedWikipedia || reached
            if let work {
                result.aboutBook = Self.trim(work.extract)
                if !work.url.isEmpty { result.sources.append(work.url) }
            }
        }

        if author != "Unknown Author" {
            let (person, reached) = await bestAuthor(author, wikis: wikis)
            result.reachedWikipedia = result.reachedWikipedia || reached
            if let person {
                result.aboutAuthor = Self.trim(person.extract)
                if !person.url.isEmpty { result.sources.append(person.url) }
            }
        }

        return result
    }

    // MARK: - Matching

    /// A wrong article is worse than none.
    ///
    /// The extract gets injected as trusted background — the prompt tells the model to
    /// prefer it over its own memory — so an article about the Monte Cristo *sandwich*
    /// would actively make the tutor worse than it is today. Every candidate must look
    /// like a written work, and the ranking below decides between the ones that do.
    private func bestWork(
        title: String, author: String, wikis: [String]
    ) async -> (WikiSummary?, reached: Bool) {
        let short = Self.mainTitle(title)
        let query = author == "Unknown Author" ? short : "\(short) \(author)"
        let surname = Self.fold(author.split(separator: " ").last.map(String.init) ?? author)

        func isAWork(_ hit: WikiSearchHit) -> Bool {
            let described = Self.fold(hit.description ?? "")
            // Wikipedia describes the Discours de la méthode as a "1637 treatise by
            // Descartes" and frwiki calls Terre des hommes a "recueil d'essais" — neither
            // of which the first, novel-shaped version of this list recognised, so a
            // philosophy text or an essay collection could never be grounded at all.
            return ["novel", "book", "roman", "livre", "poem", "poème", "play", "pièce",
                    "story", "nouvelle", "essay", "essai", "treatise", "traité",
                    "oeuvre", "œuvre", "discourse", "discours", "meditation", "méditation",
                    "memoir", "mémoire", "autobiograph", "fable", "conte", "tale",
                    "collection", "recueil", "poetry", "poésie", "text", "texte",
                    "writing", "écrit"]
                .contains { described.contains($0) }
        }

        func namesTheAuthor(_ hit: WikiSearchHit) -> Bool {
            author != "Unknown Author" && Self.fold(hit.description ?? "").contains(surname)
        }

        // Three tiers, strongest first — and applied across *all* wikis before dropping
        // to the next. Ranking within each wiki instead was what matched "Terre des
        // hommes" to *The Little Prince*: English had no article under that title, so its
        // weakest tier — any work by this author — answered before French, which had the
        // book itself, was ever consulted. Tier order has to outrank wiki order.
        var exactAndAuthor: [Candidate] = []
        var exactTitle: [Candidate] = []
        var sameAuthor: [Candidate] = []
        var reached = false

        for wiki in wikis {
            guard let hits = try? await client.search(query, language: wiki) else { continue }
            reached = true
            for hit in hits.prefix(5) where isAWork(hit) {
                let candidate = Candidate(hit: hit, wiki: wiki)
                let titled = Self.sameTitle(hit.title, title)
                if titled && namesTheAuthor(hit) { exactAndAuthor.append(candidate) }
                else if titled { exactTitle.append(candidate) }
                else if namesTheAuthor(hit) { sameAuthor.append(candidate) }
            }
        }

        return (await resolve(exactAndAuthor + exactTitle + sameAuthor), reached)
    }

    private func bestAuthor(_ author: String, wikis: [String]) async -> (WikiSummary?, reached: Bool) {
        func isAPerson(_ hit: WikiSearchHit) -> Bool {
            let described = Self.fold(hit.description ?? "")
            // A parenthesised lifespan — "(1596–1650)" — is how Wikipedia marks a person,
            // and it catches the ones no job-title list would: Descartes and Pascal are
            // both filed as "French polymath", which the writer-shaped first version of
            // this test rejected outright.
            if described.range(of: #"\(\d{3,4}\s*[–—-]\s*\d{3,4}\)"#,
                               options: .regularExpression) != nil { return true }
            return ["writer", "écrivain", "novelis", "romancier", "poet", "poète",
                    "author", "auteur", "playwright", "dramaturge", "journalis",
                    "philosoph", "polymath", "mathematic", "mathématic", "physicist",
                    "physicien", "scientist", "scientifique", "theolog", "théolog",
                    "historian", "historien", "essayist", "essayiste", "aviator", "aviateur"]
                .contains { described.contains($0) }
        }

        var exact: [Candidate] = []
        var prefixed: [Candidate] = []
        var reached = false

        for wiki in wikis {
            guard let hits = try? await client.search(author, language: wiki) else { continue }
            reached = true
            for hit in hits.prefix(4) where isAPerson(hit) {
                let candidate = Candidate(hit: hit, wiki: wiki)
                // Exact first: "Alexandre Dumas" and "Alexandre Dumas fils" are two
                // writers, and only one of them wrote the book in hand.
                if Self.sameTitle(hit.title, author) { exact.append(candidate) }
                else if Self.fold(hit.title).hasPrefix(Self.fold(author)) { prefixed.append(candidate) }
            }
        }

        return (await resolve(exact + prefixed), reached)
    }

    /// The first candidate that resolves to a real, non-disambiguation article.
    private func resolve(_ candidates: [Candidate]) async -> WikiSummary? {
        var tried = Set<String>()
        for candidate in candidates {
            let key = "\(candidate.wiki):\(candidate.hit.title)"
            guard tried.insert(key).inserted else { continue }
            if let summary = try? await client.summary(
                title: candidate.hit.title, language: candidate.wiki
            ), !summary.isDisambiguation {
                return summary
            }
        }
        return nil
    }

    // MARK: - Text

    /// True when two titles are the same, ignoring case, accents, and a parenthetical
    /// qualifier — "Les Misérables" against "Les Miserables (novel)".
    private static func sameTitle(_ candidate: String, _ wanted: String) -> Bool {
        let a = fold(candidate.replacingOccurrences(
            of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression))
        guard !a.isEmpty else { return false }
        // Compared against the subtitle stripped as well as the full string: EPUBs file
        // this book as "Discours de la méthode - Pour bien conduire sa raison, et…",
        // which is never going to equal an encyclopedia's article title.
        return [fold(wanted), fold(mainTitle(wanted))].contains(a)
    }

    /// A title up to its first subtitle separator.
    static func mainTitle(_ title: String) -> String {
        for separator in [" - ", " — ", " – ", ": ", " | "] {
            if let range = title.range(of: separator) {
                return String(title[..<range.lowerBound])
            }
        }
        return title
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
