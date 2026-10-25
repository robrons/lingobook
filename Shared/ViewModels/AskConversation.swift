import Foundation
import NaturalLanguage

/// What Claude is shown of the book with a question.
///
/// No summaries and no preparation: the chapter's own text up to the page on screen, the
/// book's contents with each chapter's length, and where the reader is. A model asked
/// about a page it can read doesn't have to remember the book — which is where a small
/// model goes wrong. No text past the current page is sent; what's to come is only in
/// the contents, for questions about the book's shape.
struct PageContext: Equatable {
    var bookTitle: String
    var bookAuthor: String
    /// The book's language from its metadata, e.g. "fr". Nil when the EPUB doesn't say.
    var bookLanguage: String?
    var chapterIndex: Int
    var chapterCount: Int
    var chapterTitle: String
    /// The whole table of contents, parts and books included, the current chapter marked ▸
    /// and every chapter with its length — so "how long until the story picks up again?"
    /// has an answer.
    var outline: String
    var pageInChapter: Int
    var pagesInChapter: Int
    var bookPercent: Int
    /// The chapter from its first line to the end of the page on screen.
    var chapterSoFar: String
    var pageText: String

    var position: String {
        "Page \(pageInChapter) of \(pagesInChapter) in chapter \(chapterIndex + 1) of \(chapterCount), about \(bookPercent)% through the book."
    }
}

extension ReaderViewModel {
    /// The page on screen, as `AskConversation` sends it. Nil until a chapter has laid out.
    func pageContext(for book: Book) -> PageContext? {
        guard currentPageIndex >= 0, currentPageIndex < pages.count else { return nil }
        let page = pages[currentPageIndex].units
        guard let lastOffset = page.last?.offset else { return nil }

        // Whole units up to the last one on screen: a paragraph that runs over the page
        // break arrives whole, a few lines early, rather than cut mid-sentence.
        let soFar = allUnits.filter { $0.offset <= lastOffset }.map(\.text)
        let chapter = paginatedChapterIndex >= 0 ? paginatedChapterIndex : currentChapterIndex
        let current = chapterTitle(at: chapter)

        return PageContext(
            bookTitle: book.title,
            bookAuthor: book.author,
            bookLanguage: book.language,
            chapterIndex: chapter,
            chapterCount: chapters.count,
            chapterTitle: current,
            outline: outline(marking: chapter),
            pageInChapter: currentPageIndex + 1,
            pagesInChapter: pages.count,
            bookPercent: Int((bookProgress * 100).rounded()),
            chapterSoFar: soFar.joined(separator: "\n"),
            pageText: page.map(\.text).joined(separator: "\n")
        )
    }
}

extension ReaderViewModel {
    /// The book's contents, the reader's chapter marked, each chapter with its length.
    ///
    /// From the book's own table of contents where it has one, because that carries the
    /// parts and books a chapter sits in. Given only "Chapitre 1 HISTOIRE D'UN PROGRÈS…",
    /// Haiku guessed which book of Les Misérables it was in, and guessed wrong.
    ///
    /// All of it, not just the chapters read: given only those, "how long is this battle
    /// going to go on?" was unanswerable, and that's a question about the book's shape, not
    /// its plot. Lengths are in words, which turn into minutes.
    fileprivate func outline(marking chapter: Int) -> String {
        let words = ChapterLengths.words(in: chapters)
        func length(_ index: Int?) -> String {
            guard let index, words.indices.contains(index), words[index] >= 50 else { return "" }
            return " — \(words[index].formatted()) words"
        }
        func chapterIndex(of item: EPUBService.TOCItem) -> Int? {
            chapters.firstIndex { $0.href.contains(item.href) || item.href.contains($0.href) }
        }
        if chapters.indices.contains(chapter), tableOfContents.contains(where: { chapterIndex(of: $0) == chapter }) {
            let minimum = tableOfContents.map(\.level).min() ?? 0
            var marked = false
            return tableOfContents.map { item in
                let index = chapterIndex(of: item)
                let isCurrent = !marked && index == chapter
                if isCurrent { marked = true }
                let indent = String(repeating: "  ", count: max(0, item.level - minimum))
                return (isCurrent ? "▸ " : "  ") + indent + item.label + length(index)
            }.joined(separator: "\n")
        }
        // No usable contents: the chapters' own titles, in reading order.
        return chapters.indices.map { index in
            let title = chapterTitle(at: index)
            return (index == chapter ? "▸ " : "  ") + (title.isEmpty ? "Chapter \(index + 1)" : title) + length(index)
        }.joined(separator: "\n")
    }
}

/// Words in each chapter of a book, counted once and kept: the first question about a
/// book pays for reading through its whole text, the rest don't.
@MainActor
private enum ChapterLengths {
    private static var cache: [String: [Int]] = [:]

    static func words(in chapters: [EPUBService.Chapter]) -> [Int] {
        let key = "\(chapters.first?.id ?? "")|\(chapters.count)|\(chapters.last?.id ?? "")"
        if let known = cache[key] { return known }
        let counts = chapters.map { chapter in
            chapter.htmlContent
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace)
                .count
        }
        cache[key] = counts
        return counts
    }
}

/// A conversation with Claude about the chapter being read.
///
/// It lasts as long as the chapter: a new chapter starts a fresh one, so the context sent
/// stays one chapter long and a question is never answered from a chapter left behind.
@MainActor
@Observable
final class AskConversation {
    struct Entry: Identifiable, Equatable {
        enum Role { case reader, claude, problem }
        let id = UUID()
        let role: Role
        var text: String
        /// Set while a web search is under way for this answer.
        var isSearching = false
        /// The pages the answer cited, in the order it first cited them.
        var sources: [Claude.Source] = []
    }

    /// The questions on offer before anything is typed. The label is what the panel shows
    /// and the transcript records; the prompt is what's actually asked.
    struct Suggestion: Identifiable {
        let label: String
        let systemImage: String
        let prompt: String
        var id: String { label }
    }

    static let suggestions = [
        Suggestion(
            label: "Explain This Page",
            systemImage: "text.magnifyingglass",
            prompt: "Explain this page: what is happening, and any words, idioms or references someone reading it in a language they are still learning might stumble on."
        ),
        Suggestion(
            label: "Who's Who",
            systemImage: "person.2",
            prompt: "Who are the people on this page, and how do they connect to each other and to what has happened so far?"
        ),
        Suggestion(
            label: "Recap So Far",
            systemImage: "arrow.counterclockwise",
            prompt: "Recap what has happened in this chapter up to this page."
        ),
    ]

    private(set) var entries: [Entry] = []
    private(set) var isAnswering = false

    /// What has been sent, and the chapter and text it was sent for — so a follow-up after
    /// a page turn sends only what was read in between.
    private var sent: [Claude.Message] = []
    private var system = ""
    private var chapterKey: String?
    private var textSent = ""
    private var pageSent = ""
    private var answering: Task<Void, Never>?

    var isEmpty: Bool { entries.isEmpty }

    /// The ready-made questions never search: they're about the page, and should stay a
    /// second and a tenth of a cent.
    func ask(_ suggestion: Suggestion, about context: PageContext) {
        ask(suggestion.prompt, shownAs: suggestion.label, about: context, webSearch: false)
    }

    /// A typed or dictated question may search the web, if Claude decides it needs to.
    func ask(
        _ question: String,
        shownAs label: String? = nil,
        about context: PageContext,
        webSearch: Bool = true
    ) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else { return }

        let key = "\(context.bookTitle)|\(context.chapterIndex)"
        if key != chapterKey { reset(for: context, key: key) }

        let message = Claude.Message(role: "user", content: turn(question, context: context))
        let history = sent + [message]
        let answer = Entry(role: .claude, text: "")
        entries.append(Entry(role: .reader, text: label ?? question))
        entries.append(answer)
        isAnswering = true

        let system = system
        answering = Task {
            var reply = ""
            do {
                for try await chunk in Claude.stream(system: system, messages: history, webSearch: webSearch) {
                    guard let index = entries.firstIndex(where: { $0.id == answer.id }) else { return }
                    switch chunk {
                    case .searching:
                        entries[index].isSearching = true
                    case .text(let piece):
                        reply += piece
                        entries[index].text = reply
                        entries[index].isSearching = false
                    case .source(let source):
                        if !entries[index].sources.contains(where: { $0.url == source.url }) {
                            entries[index].sources.append(source)
                        }
                    }
                }
                // A reply can end with nothing said — all thinking, or only searching.
                // Say so, rather than leave an empty answer on screen.
                guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Claude.Failure.http(0, "No answer came back. Try asking again.")
                }
                // Only a finished exchange joins the history, and only then does the text
                // it carried count as shown: a failed question is resent whole next time.
                let sources = entries.first(where: { $0.id == answer.id })?.sources ?? []
                sent = history + [Claude.Message(role: "assistant", content: Self.remembered(reply, sources: sources))]
                if context.chapterSoFar.count > textSent.count { textSent = context.chapterSoFar }
                pageSent = context.pageText
                #if DEBUG
                Self.log(
                    question: label ?? question, context: context, system: system, sent: message.content, reply: reply,
                    sources: entries.first(where: { $0.id == answer.id })?.sources.map(\.url) ?? []
                )
                #endif
            } catch is CancellationError {
                return
            } catch {
                if reply.isEmpty { entries.removeAll { $0.id == answer.id } }
                entries.append(Entry(role: .problem, text: error.localizedDescription))
            }
            isAnswering = false
        }
    }

    #if DEBUG
    /// One line of JSON per answer in Caches/ask-log.jsonl, for checking answers against
    /// the text they were given.
    private static func log(
        question: String, context: PageContext, system: String, sent: String, reply: String, sources: [String]
    ) {
        let entry: [String: Any] = [
            "sources": sources,
            "system": system,
            "book": context.bookTitle,
            "chapter": context.chapterTitle,
            "position": context.position,
            "question": question,
            "page": context.pageText,
            "chapterChars": context.chapterSoFar.count,
            "sentChars": sent.count,
            "answer": reply,
        ]
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(0x0A)
        let url = caches.appending(path: "ask-log.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
    #endif

    /// An answer as the conversation keeps it.
    ///
    /// Only the answer's text goes back with the next question — not the search behind it,
    /// whose pages would be resent every turn. Without a trace of the search, the next turn
    /// found its own dates and names unexplained and apologised for them, as if it had made
    /// them up. So a searched answer carries a note of where it came from.
    private static func remembered(_ reply: String, sources: [Claude.Source]) -> String {
        guard !sources.isEmpty else { return reply }
        let list = sources.prefix(6).map { "\($0.title) (\($0.site))" }.joined(separator: "; ")
        return reply + "\n\n[Found by web search: \(list)]"
    }

    /// Claude's italics and bold, kept; anything block-level shows as written.
    ///
    /// Asked for Markdown, Haiku sometimes italicises a quotation with `<i>` instead, which
    /// the panel would print as it stands. Those few tags become Markdown first.
    nonisolated static func styled(_ text: String) -> AttributedString {
        var text = text
        for (tags, mark) in [(["<i>", "</i>", "<em>", "</em>"], "*"), (["<b>", "</b>", "<strong>", "</strong>"], "**")] {
            for tag in tags { text = text.replacingOccurrences(of: tag, with: mark) }
        }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    func stop() {
        answering?.cancel()
        answering = nil
        isAnswering = false
    }

    private func reset(for context: PageContext, key: String) {
        stop()
        entries = []
        sent = []
        textSent = ""
        pageSent = ""
        chapterKey = key
        system = Self.systemPrompt(for: context)
    }

    /// The question, with whatever of the book Claude hasn't been shown yet.
    private func turn(_ question: String, context: PageContext) -> String {
        var parts: [String] = []

        if textSent.isEmpty {
            parts.append("<chapter_so_far>\n\(context.chapterSoFar)\n</chapter_so_far>")
            parts.append("<page_on_screen>\n\(context.pageText)\n</page_on_screen>")
        } else if context.pageText != pageSent {
            if context.chapterSoFar.hasPrefix(textSent) {
                let since = context.chapterSoFar.dropFirst(textSent.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !since.isEmpty {
                    parts.append("<read_since_last_question>\n\(since)\n</read_since_last_question>")
                }
                parts.append("They have turned to a new page.")
            } else {
                parts.append("They have gone back to an earlier page.")
            }
            parts.append("<page_on_screen>\n\(context.pageText)\n</page_on_screen>")
        }

        if context.pageText != pageSent { parts.append(context.position) }
        parts.append(question)
        parts.append(Self.replyLanguage(for: question, bookLanguage: context.bookLanguage))
        return parts.joined(separator: "\n\n")
    }

    /// The reply language, named outright, right after the question.
    ///
    /// "Reply in the language they asked in" doesn't survive a French page: Haiku answered
    /// an English "Who's who" in French. Stated as a fact next to the question, it holds.
    /// The ready-made questions are English; anything short or unclear is taken as English.
    ///
    /// Only the languages that can actually come up are considered — English, the book's,
    /// and the device's own. Unconstrained, "Qui est Lobau ?" came out as Catalan, and
    /// was answered in it.
    private static func replyLanguage(for question: String, bookLanguage: String?) -> String {
        let recognizer = NLLanguageRecognizer()
        var candidates: Set<NLLanguage> = [.english]
        for code in [bookLanguage, Locale.current.language.languageCode?.identifier] {
            if let code = code?.split(separator: "-").first { candidates.insert(NLLanguage(String(code))) }
        }
        recognizer.languageConstraints = Array(candidates)
        recognizer.processString(question)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence > 0.6, language != .english,
              let name = Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue)
        else {
            return "(Reply in English.)"
        }
        return "(They asked in \(name), so reply in \(name).)"
    }

    /// The standing instructions — fixed for the whole chapter, so every follow-up reads
    /// them from the cache.
    ///
    /// Not a tutor persona: given a teaching role, a model turns every question into a
    /// lesson nobody asked for. The length limit is a number, because "keep it short"
    /// produces essays, and the answer is read from across a room or in a narrow panel.
    static func systemPrompt(for context: PageContext) -> String {
        #if os(tvOS)
        let device = "television"
        let readingDistance = "from across the room"
        #elseif os(macOS)
        let device = "Mac"
        let readingDistance = "in a panel beside the page"
        #else
        let device = "iPad"
        let readingDistance = "in a panel beside the page"
        #endif

        return """
        You are helping someone read “\(context.bookTitle)” by \(context.bookAuthor) on their \
        \(device). They are reading “\(context.chapterTitle)”, and you are given the text of \
        this chapter up to the page on their screen. A page can start or end mid-sentence; \
        that is only where the page breaks, so don't mention it.

        The book's contents, ▸ marking the chapter they are reading, with each chapter's \
        length in words. Use it to say where things are and how long they run: how many \
        chapters, words or minutes until a section ends or the story moves on is a fair \
        question, not a spoiler. A reader takes about a minute per 200 words. For where \
        things are in this book, trust these contents over anything you remember or find.
        \(context.outline)

        Answer what they ask about what they are reading. For this chapter, rely on the text \
        you are given. For the chapters before it you only have the titles, so use what you \
        know of the book freely — asked to recap the story so far, recap it, from the \
        beginning up to this chapter. Say you're unsure only of a detail you really are unsure \
        of — no general caveats about memory, and don't go back to correct earlier answers \
        unless something in them was wrong.

        Be helpful about what lies ahead without spoiling it. Saying what a coming chapter or \
        section is about in general — "the next book returns to Valjean", "eight more \
        chapters of battle" — is fine. Don't give away plot turns after this chapter, such \
        as deaths, hidden identities or how things end, unless they ask you to spoil it; \
        then tell them.

        Some questions come with a web search. Search whenever they ask you to, and for \
        anything about the real world outside the book — history, the author, real people — \
        or that you aren't sure of. When you use what you found, say \
        each fact once: no opening summary that the sentences after it then repeat. An \
        earlier answer of yours that ends in [Found by web search: …] came from a search you \
        ran; stand by it as you would by the book, and never write that note yourself.

        Reply in the language each question says to. Quote the book's words in its own \
        language, and only words that are in the text you were sent — paraphrase anything \
        you remember rather than put it in quotation marks.

        At most two short paragraphs, about 120 words — a recap of the whole book so far can \
        run to about 250: they are reading this \(readingDistance) and want to get back to \
        the book. Plain prose — no headings, lists or tables. *Italics* for quoted words and \
        titles are fine.
        """
    }
}
