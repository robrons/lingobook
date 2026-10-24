import Foundation
import NaturalLanguage

/// What Claude is shown of the book with a question.
///
/// No summaries and no preparation: the chapter's own text up to the page on screen, the
/// titles of the chapters already reached, and where the reader is. A model asked about
/// a page it can read doesn't have to remember the book — which is where a small model
/// goes wrong — and nothing past the current page is ever sent, so it can't spoil it.
struct PageContext: Equatable {
    var bookTitle: String
    var bookAuthor: String
    /// The book's language from its metadata, e.g. "fr". Nil when the EPUB doesn't say.
    var bookLanguage: String?
    var chapterIndex: Int
    var chapterCount: Int
    var chapterTitle: String
    /// The table of contents up to and including the current chapter, parts and books
    /// included, the current chapter marked ▸. Nothing later: a title like "The Death
    /// of…" is a spoiler.
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
            outline: outline(upTo: chapter, current: current),
            pageInChapter: currentPageIndex + 1,
            pagesInChapter: pages.count,
            bookPercent: Int((bookProgress * 100).rounded()),
            chapterSoFar: soFar.joined(separator: "\n"),
            pageText: page.map(\.text).joined(separator: "\n")
        )
    }
}

extension ReaderViewModel {
    /// The contents up to the reader's chapter.
    ///
    /// From the book's own table of contents where it has one, because that carries the
    /// parts and books a chapter sits in. Given only "Chapitre 1 HISTOIRE D'UN PROGRÈS…",
    /// Haiku guessed which book of Les Misérables it was in, and guessed wrong.
    fileprivate func outline(upTo chapter: Int, current: String) -> String {
        let href = chapters.indices.contains(chapter) ? chapters[chapter].href : ""
        if !href.isEmpty, let end = tableOfContents.firstIndex(where: { href.contains($0.href) || $0.href.contains(href) }) {
            let minimum = tableOfContents.map(\.level).min() ?? 0
            return tableOfContents[...end].enumerated().map { index, item in
                let indent = String(repeating: "  ", count: max(0, item.level - minimum))
                return (index == end ? "▸ " : "  ") + indent + item.label
            }.joined(separator: "\n")
        }
        // No usable contents: the chapters' own titles, in reading order.
        return (0...max(0, min(chapter, chapters.count - 1))).map { index in
            let title = chapterTitle(at: index)
            return (index == chapter ? "▸ " : "  ") + (title.isEmpty ? "Chapter \(index + 1)" : title)
        }.joined(separator: "\n")
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
        let remaining = context.chapterCount - context.chapterIndex - 1
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

        The contents up to here, ▸ marking the current chapter\(remaining > 0 ? " (\(remaining) more chapters follow)" : ""). \
        Use it to say where something is in the book:
        \(context.outline)

        Answer what they ask about what they are reading. For this chapter, rely on the text \
        you are given. For the chapters before it you only have the titles, so use what you \
        know of the book freely — asked to recap the story so far, recap it, from the \
        beginning up to this chapter. Say you're unsure only of a detail you really are unsure \
        of — no general caveats about memory, and don't go back to correct earlier answers \
        unless something in them was wrong.

        Don't give away what happens after this chapter, unless they plainly ask you to \
        spoil it. Then tell them.

        Some questions come with a web search. Use it only for the real world outside the \
        book — history, the author, real people's lives beyond the novel — never for what is \
        in the text you were given or for the story itself. When you use what you found, say \
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
