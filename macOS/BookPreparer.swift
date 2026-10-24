import SwiftUI
import SwiftData
@preconcurrency import Translation

/// Translates a whole book ahead of time, so it can be read where nothing can translate it.
///
/// Apple TV has no Translation framework, so a book goes there with every sentence already
/// translated by the Mac — the same on-device engine the reader uses page by page, run
/// over the whole book once. The results land in the book's `TranslationMemory`, which also
/// makes those pages instant and offline the next time the book is read on the Mac.
///
/// A `TranslationSession` can only be had from SwiftUI's `.translationTask`, so the work
/// runs inside one hosted by `AppleTVBridge`; this class holds the queue and the progress.
@MainActor
@Observable
final class BookPreparer {
    static let shared = BookPreparer()

    /// 0…1 for each book being translated.
    private(set) var progress: [UUID: Double] = [:]
    /// Why the last attempt for a book failed, shown on its card until it's retried.
    private(set) var failures: [UUID: String] = [:]
    /// Sentences the translator refused in the last run, which read in the original only.
    private(set) var skippedCounts: [UUID: Int] = [:]
    /// Drives `.translationTask`. Replaced (or invalidated) to start the next book.
    private(set) var configuration: TranslationSession.Configuration?

    private var queue: [Book] = []
    private var current: Book?
    /// Each open window hosts a translation task; only one may work a book at a time.
    private var isRunning = false

    func sendToAppleTV(_ book: Book) {
        failures[book.id] = nil
        skippedCounts[book.id] = nil
        guard current?.id != book.id, !queue.contains(where: { $0.id == book.id }) else { return }

        // Nothing to translate: an English book reads on the TV as it is. Running it
        // through the translator would ask for an English→English pair, which fails, and
        // the book would never leave the Mac.
        guard book.needsTranslation else {
            book.appleTVStatus = .waiting
            try? book.modelContext?.save()
            AppleTVSender.shared.sendWaitingBooks()
            return
        }

        book.appleTVStatus = .preparing
        try? book.modelContext?.save()
        queue.append(book)
        startNextIfIdle()
    }

    /// Picks back up any book whose translation was cut short by quitting the app.
    func resumeUnfinished(in modelContext: ModelContext) {
        let preparing = AppleTVStatus.preparing.rawValue
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.appleTVStatusRaw == preparing })
        for book in (try? modelContext.fetch(descriptor)) ?? [] {
            sendToAppleTV(book)
        }
    }

    func isPreparing(_ book: Book) -> Bool {
        current?.id == book.id || queue.contains { $0.id == book.id }
    }

    private func startNextIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let book = queue.removeFirst()
        current = book
        progress[book.id] = 0
        requestSession(for: book)
    }

    private func requestSession(for book: Book) {
        let source = book.language.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: "en")
        // A new configuration starts a session; an identical one has to be invalidated,
        // or SwiftUI sees nothing to react to.
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    /// Called from `.translationTask` with a session for `configuration`.
    func run(using session: TranslationSession) async {
        guard let book = current, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let id = book.id
        var memory = TranslationMemory(data: book.translationsData)
        var skipped = 0

        func checkpoint() {
            book.translationsData = memory.encoded()
            try? book.modelContext?.save()
        }

        do {
            // Asks to download the language pair first if the Mac doesn't have it yet.
            try await session.prepareTranslation()

            let epubData = book.epubData
            let allTexts = try await Task.detached { try Self.texts(in: epubData) }.value

            var texts: [String] = []
            for text in allTexts where !memory.contains(text) {
                // Roman numerals, "* * *", page numbers: nothing to translate, and the
                // translator refuses them. They read the same in English.
                if text.contains(where: \.isLetter) {
                    texts.append(text)
                } else {
                    memory.record(text, text)
                }
            }
            Self.log("[prepare] \(book.title): \(allTexts.count) texts, \(texts.count) to translate")

            let batchSize = 40
            /// Refusals in a row. A few are the text; dozens mean the translator itself is
            /// failing — no language download, say — and carrying on would just skip the book.
            var consecutiveRefusals = 0

            for start in stride(from: 0, to: texts.count, by: batchSize) {
                try Task.checkCancellation()
                let batch = Array(texts[start..<min(start + batchSize, texts.count)])

                do {
                    try await translate(batch, with: session, into: &memory)
                    consecutiveRefusals = 0
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // One sentence the translator won't take — Latin, a bare name — fails
                    // the whole batch. Retry one at a time and skip only what it refuses.
                    Self.log("[prepare] batch failed (\(error.localizedDescription)); retrying one by one")
                    for text in batch {
                        do {
                            try await translate([text], with: session, into: &memory)
                            consecutiveRefusals = 0
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            skipped += 1
                            consecutiveRefusals += 1
                            Self.log("[prepare] skipped (\(error.localizedDescription)): \(text.prefix(160))")
                            if consecutiveRefusals >= 40 { throw error }
                        }
                    }
                }

                // Through the whole book, not just this run: resuming a book that was 90%
                // done should say 90%, not start again from zero.
                let alreadyDone = allTexts.count - texts.count
                progress[id] = Double(alreadyDone + start + batch.count) / Double(allTexts.count)

                // Checkpoint now and then, so quitting halfway doesn't throw the half away.
                if (start / batchSize) % 10 == 9 { checkpoint() }
            }

            book.appleTVStatus = .waiting
            checkpoint()
            if skipped > 0 { skippedCounts[id] = skipped }
            Self.log("[prepare] \(book.title): done, \(skipped) skipped")
            AppleTVSender.shared.sendWaitingBooks()
        } catch is CancellationError {
            // The window hosting the session closed. Keep what's done and put the book back
            // at the front; any other open window picks it up, or the next launch does.
            checkpoint()
            queue.insert(book, at: 0)
            current = nil
            progress[id] = nil
            return
        } catch {
            Self.log("[prepare] \(book.title): failed: \(error)")
            failures[id] = error.localizedDescription
            book.appleTVStatus = .none
            // Keep what was translated; trying again picks up from here.
            checkpoint()
        }

        progress[id] = nil
        current = nil
        startNextIfIdle()
    }

    private func translate(
        _ texts: [String],
        with session: TranslationSession,
        into memory: inout TranslationMemory
    ) async throws {
        // Built fresh for this call and never touched again, so handing it to the session
        // can't race — the Request type just isn't marked Sendable.
        nonisolated(unsafe) let requests = texts.map { TranslationSession.Request(sourceText: $0) }
        let responses = try await session.translations(from: requests)
        for response in responses {
            memory.record(response.sourceText, response.targetText)
        }
    }

    /// Appends to `Documents/translation.log` in the app's container. Unlike the reader's
    /// debug log this is kept in release builds too: a book that won't translate needs to
    /// say why after the fact, and the system log doesn't keep this app's messages.
    private static func log(_ message: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/translation.log")
        let stamp = Date().formatted(date: .numeric, time: .standard)
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Every piece of text the reader can ask to see translated: each chapter's heading and
    /// each sentence, split exactly as the reader splits them. Paragraphs aren't stored —
    /// `TranslationMemory` rebuilds them from their sentences.
    nonisolated static func texts(in epubData: Data) throws -> [String] {
        let epub = EPUBService()
        let content = try epub.parse(epubData: epubData)

        var seen = Set<String>()
        var texts: [String] = []

        func add(_ text: String) {
            let key = TranslationMemory.key(text)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            texts.append(key)
        }

        for chapter in content.chapters {
            add(ReaderViewModel.chapterTitle(of: chapter, tableOfContents: content.tableOfContents))
            for paragraph in epub.extractParagraphs(from: chapter.htmlContent) {
                TranslationMemory.sentences(in: paragraph).forEach(add)
            }
        }

        return texts
    }
}
