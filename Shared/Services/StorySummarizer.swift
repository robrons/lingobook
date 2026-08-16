import Foundation
import SwiftData

/// Writes down what happened in each chapter, as the reader finishes it.
///
/// "What's happened so far?" is the question the tutor was worst at, and no amount of
/// prompting could fix it: the model was answering from a hazy memory of the novel, so it
/// recapped events the reader hadn't reached and invented them wholesale for anything
/// less famous than Hugo. This builds the alternative out of the only reliable source
/// available — the chapters the reader has actually turned past — one small local
/// summary at a time, in the background.
///
/// Everything here is best effort. A summary that fails leaves a gap, the recap says
/// nothing about that chapter, and the reader loses nothing they had before.
@MainActor
@Observable
final class StorySummarizer {

    /// Chapters kept verbatim behind the reader before older ones are folded into the
    /// digest. Eight is a few evenings of reading — enough that "what just happened"
    /// has real detail to draw on.
    private let recentWindow = 8

    /// How many chapters accumulate past the window before they're compacted. Together
    /// these bound the recap at 8–18 summaries no matter how long the book is.
    private let compactionBatch = 10

    /// A chapter this short is a title page or a table of contents, not a scene.
    private let minimumChapterLength = 400

    /// Above this, a chapter goes to the model in pieces. Ministral's window would
    /// otherwise silently drop the end of a long chapter — and summarise half a chapter
    /// while claiming to summarise all of it.
    private let chunkLimit = 40_000

    /// How far back to reach for a book that was read before any of this existed.
    ///
    /// Unbounded, this would put a 300-chapter backlog through a local model the first
    /// time an old book is opened: hours of inference and an audibly busy laptop, for
    /// chapters the reader finished months ago. The recent dozen is what a recap
    /// actually leans on.
    private let backfillLimit = 12

    private var book: Book?
    private var modelContext: ModelContext?
    private var chapters: [EPUBService.Chapter] = []

    private var pending: [Int] = []
    private var summarized: Set<Int> = []
    private var worker: Task<Void, Never>?

    /// The chapter being written up right now, if any. Read by the panel, which has to be
    /// able to say "still working" rather than leaving the reader to guess.
    private(set) var writingChapter: Int?

    /// How many chapters the tutor can actually recall, and how many are still queued.
    var rememberedChapters: Int { summarized.count }
    var queuedChapters: Int { pending.count }

    /// True while the tutor is answering.
    ///
    /// One model serves both, and the reader is the one waiting. Summarising during a
    /// reply would put a chapter-sized prompt in front of the question being asked.
    var isPaused = false {
        didSet { if !isPaused { drain() } }
    }

    /// The assembled recap, rebuilt only when it changes.
    ///
    /// `ReaderView`'s body re-evaluates on every mouse event while the panel is being
    /// dragged, and the context it builds is rebuilt with it. A SwiftData fetch on that
    /// path would judder the drag exactly the way re-parsing every message once did.
    private var cachedStory: (chapter: Int, block: String?)?

    // MARK: - Wiring

    func configure(book: Book, modelContext: ModelContext, chapters: [EPUBService.Chapter]) {
        stop()

        self.book = book
        self.modelContext = modelContext
        self.chapters = chapters
        self.cachedStory = nil
        self.summarized = Set(fetchSummaries().map(\.chapterIndex))

        let finished = min(book.currentChapterIndex, chapters.count)
        let earliest = max(0, finished - backfillLimit)
        pending = (earliest..<finished).filter { !summarized.contains($0) }

        drain()
    }

    /// The reader turned past the last page of a chapter.
    func noteChapterFinished(_ index: Int) {
        guard index >= 0, index < chapters.count, !summarized.contains(index) else { return }
        guard !pending.contains(index) else { return }
        pending.append(index)
        drain()
    }

    func stop() {
        worker?.cancel()
        worker = nil
        writingChapter = nil
        pending.removeAll()
    }

    // MARK: - The recap

    /// What to tell the tutor has happened, for a reader on `chapterIndex`.
    ///
    /// Only chapters strictly before this one, which is what makes the whole thing
    /// spoiler-safe without a single check anywhere else: a chapter the reader hasn't
    /// finished has no summary, and one they've skipped past never got one either.
    func storySoFar(before chapterIndex: Int) -> String? {
        guard let book else { return nil }
        if let cachedStory, cachedStory.chapter == chapterIndex { return cachedStory.block }

        let digestThrough = book.digestThroughChapter
        let recent = fetchSummaries()
            .filter { $0.chapterIndex < chapterIndex && $0.chapterIndex > digestThrough && $0.hasEvents }

        var lines: [String] = []
        if let digest = book.storyDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
           !digest.isEmpty {
            lines.append("Earlier in the book: \(digest)")
        }
        for summary in recent {
            let title = summary.chapterTitle.isEmpty
                ? "Chapter \(summary.chapterIndex + 1)"
                : summary.chapterTitle
            lines.append("\(summary.chapterIndex + 1). \(title): \(summary.text)")
        }

        let block = lines.isEmpty ? nil : lines.joined(separator: "\n")
        cachedStory = (chapterIndex, block)
        return block
    }

    // MARK: - The queue

    private func drain() {
        guard worker == nil, !isPaused, !pending.isEmpty else { return }

        worker = Task {
            // Let the page turn land before competing with it for the machine.
            try? await Task.sleep(for: .seconds(2))

            while !isPaused, !pending.isEmpty, !Task.isCancelled {
                let next = pending.removeFirst()
                writingChapter = next
                let succeeded = await summarize(chapterIndex: next)
                writingChapter = nil
                guard succeeded else {
                    // Ollama isn't answering. Trying the rest of the queue would just
                    // spend a three-minute timeout apiece discovering the same thing;
                    // the backfill runs again next time the book is opened.
                    pending.removeAll()
                    break
                }
            }

            writingChapter = nil
            worker = nil
            if !pending.isEmpty { drain() }
        }
    }

    /// - Returns: false only when the model itself couldn't be reached.
    private func summarize(chapterIndex: Int) async -> Bool {
        guard let book, let modelContext,
              chapterIndex >= 0, chapterIndex < chapters.count,
              !summarized.contains(chapterIndex)
        else { return true }

        let chapter = chapters[chapterIndex]
        let bookTitle = book.title
        let bookID = book.id
        let html = chapter.htmlContent

        // Stripping markup from a whole chapter is real work, and the main actor is
        // busy rendering a book.
        let text = await Task.detached(priority: .utility) {
            EPUBService().extractPlainText(from: html)
        }.value

        guard !Task.isCancelled else { return true }

        let summaryText: String
        if text.count < minimumChapterLength {
            // Recorded as "nothing happened here" rather than skipped, so the backfill
            // doesn't ask about the title page again every time the book opens.
            summaryText = ""
        } else {
            do {
                summaryText = try await write(text: text, chapterTitle: chapter.title, bookTitle: bookTitle)
            } catch {
                return false
            }
        }

        guard !Task.isCancelled else { return true }

        modelContext.insert(ChapterSummary(
            bookID: bookID,
            chapterIndex: chapterIndex,
            chapterTitle: chapter.title,
            text: summaryText,
            modelName: Ollama.defaultModel
        ))
        try? modelContext.save()

        summarized.insert(chapterIndex)
        cachedStory = nil

        await compactIfNeeded()
        return true
    }

    // MARK: - Prompts

    /// Strict on purpose.
    ///
    /// A hallucinated summary doesn't stay in one chapter — it gets folded into the
    /// digest and then colours every recap after it. The model is given the text and
    /// told, in as many ways as fit, that the text is the only thing it may use.
    private func summarySystem(bookTitle: String) -> String {
        """
        You are writing a reader's own notes on “\(bookTitle)”, one chapter at a time.

        Summarise ONLY what happens in the chapter text you are given. Three to five \
        sentences, plain prose, in English. Name characters and places exactly as the \
        text names them.

        Do not interpret, do not foreshadow, do not explain the significance of anything, \
        and do not add a single detail from what you may know about this book from \
        elsewhere. No preamble — begin with the events.

        If the text has no events in it at all — a title page, a table of contents, a \
        list of works — reply with exactly: NO EVENTS
        """
    }

    private func write(text: String, chapterTitle: String, bookTitle: String) async throws -> String {
        let system = summarySystem(bookTitle: bookTitle)
        let pieces = Self.chunk(text, limit: chunkLimit)

        var partials: [String] = []
        for (index, piece) in pieces.enumerated() {
            let heading = pieces.count == 1
                ? "Chapter: “\(chapterTitle)”"
                : "Chapter: “\(chapterTitle)” (part \(index + 1) of \(pieces.count))"
            let reply = try await Ollama.complete(
                system: system,
                user: "\(heading)\n\n\(piece)"
            )
            let cleaned = Self.cleanUp(reply)
            if !cleaned.isEmpty { partials.append(cleaned) }
        }

        guard !partials.isEmpty else { return "" }
        guard partials.count > 1 else { return partials[0] }

        let merged = try await Ollama.complete(
            system: """
            You are merging notes on consecutive parts of a single chapter into one \
            account. Three to five sentences, plain prose, in English, in the order the \
            events happened. Use only what the notes contain — add nothing.
            """,
            user: partials.joined(separator: "\n\n")
        )
        return Self.cleanUp(merged)
    }

    /// Folds everything past the recent window into one paragraph.
    ///
    /// Without this a long book's recap grows without limit and eventually pushes the
    /// page itself out of the model's context — the exact failure this feature exists to
    /// prevent. After it, a 300-chapter book costs the same as a 12-chapter one.
    private func compactIfNeeded() async {
        guard let book, let modelContext else { return }

        let digestThrough = book.digestThroughChapter
        let uncompacted = fetchSummaries().filter { $0.chapterIndex > digestThrough }
        guard uncompacted.count >= recentWindow + compactionBatch else { return }

        let toCompact = uncompacted.dropLast(recentWindow)
        guard let lastIndex = toCompact.last?.chapterIndex else { return }

        var material: [String] = []
        if let digest = book.storyDigest, !digest.isEmpty {
            material.append("The story up to now:\n\(digest)")
        }
        material.append(
            toCompact
                .filter(\.hasEvents)
                .map { "\($0.chapterIndex + 1). \($0.text)" }
                .joined(separator: "\n")
        )

        do {
            let digest = try await Ollama.complete(
                system: """
                You are keeping a running account of a novel for a reader who is partway \
                through it. Merge everything below into one continuous account of what has \
                happened, at most 250 words, in English.

                Keep names, places, and what actually happened; drop repetition and small \
                detail. Add nothing that is not in the text below. Reply with the account \
                and nothing else.
                """,
                user: material.joined(separator: "\n\n")
            )

            let cleaned = Self.cleanUp(digest)
            guard !cleaned.isEmpty else { return }

            book.storyDigest = cleaned
            book.digestThroughChapter = lastIndex
            try? modelContext.save()
            cachedStory = nil
        } catch {
            // The summaries stay where they are and compaction is retried after the next
            // chapter. Nothing is lost by leaving them uncompacted a while longer.
            return
        }
    }

    // MARK: - Helpers

    private func fetchSummaries() -> [ChapterSummary] {
        guard let book, let modelContext else { return [] }
        let id = book.id
        let descriptor = FetchDescriptor<ChapterSummary>(
            predicate: #Predicate { $0.bookID == id },
            sortBy: [SortDescriptor(\.chapterIndex)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Splits at paragraph boundaries, so no piece begins mid-sentence.
    private static func chunk(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }

        var pieces: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if current.count + paragraph.count > limit, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += current.isEmpty ? paragraph : "\n\n" + paragraph
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Drops the small talk a chat model puts around a summary it was asked for plainly.
    private static func cleanUp(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased().contains("NO EVENTS") { return "" }

        // "Here is a summary of the chapter:" and friends — always the first line, always
        // ending in a colon, and never part of the summary itself.
        if let newline = text.firstIndex(of: "\n") {
            let firstLine = text[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
            if firstLine.hasSuffix(":") && firstLine.count < 80 {
                text = String(text[text.index(after: newline)...])
            }
        }

        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
    }
}
