import Foundation
import SwiftData

/// Which books are being read up on right now.
///
/// Without this, a book still fetching its background is indistinguishable from a book
/// that has none and never will — both are simply a tutor that doesn't mention it. The
/// panel needs to tell those apart to say anything honest about what it knows.
@MainActor
@Observable
final class GroundingMonitor {
    static let shared = GroundingMonitor()

    private(set) var inFlight: Set<UUID> = []

    /// Books whose lookup couldn't reach Wikipedia at all this session. Kept in memory
    /// only — it describes the network, not the book, and next launch deserves a fresh try.
    private(set) var unreachable: Set<UUID> = []

    func isFetching(_ id: UUID) -> Bool { inFlight.contains(id) }
    func couldNotReachWikipedia(_ id: UUID) -> Bool { unreachable.contains(id) }

    fileprivate func begin(_ id: UUID) {
        inFlight.insert(id)
        unreachable.remove(id)
    }

    fileprivate func finish(_ id: UUID, reached: Bool) {
        inFlight.remove(id)
        if !reached { unreachable.insert(id) }
    }
}

@MainActor
enum BookGrounding {

    /// A book Wikipedia has never heard of shouldn't send the same two requests every
    /// time it's opened — but a book imported on a train should get another chance.
    private static let retryInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Fills in a book's background, if it needs it and we haven't just tried.
    ///
    /// Safe to call on every import and every open: the guards below make repeat calls
    /// free, which is what lets the whole existing library backfill itself simply by
    /// being read.
    static func groundIfNeeded(_ book: Book, modelContext: ModelContext) {
        guard TutorSettings.wikipediaLookupEnabled else { return }
        guard book.aboutBook == nil || book.aboutAuthor == nil else { return }
        if let attempted = book.groundingAttemptedAt,
           Date().timeIntervalSince(attempted) < retryInterval { return }

        let title = book.title
        let author = book.author
        let language = book.language
        let id = book.id

        // Opening the same book twice in quick succession must not fetch twice. Tracked
        // in memory rather than by stamping the book up front — see below.
        guard !GroundingMonitor.shared.isFetching(id) else { return }
        GroundingMonitor.shared.begin(id)

        Task {
            let found = await BookGrounder().ground(title: title, author: author, language: language)
            GroundingMonitor.shared.finish(id, reached: found.reachedWikipedia)

            // Stamped only once Wikipedia has actually answered. Stamping before the
            // request — the first version — meant a lookup cut short by quitting the app,
            // or simply made offline, recorded a verdict it never received: the book was
            // written off as "no article" for a week, and said so in the panel.
            guard found.reachedWikipedia else { return }
            book.groundingAttemptedAt = Date()

            guard found.aboutBook != nil || found.aboutAuthor != nil else {
                try? modelContext.save()
                return
            }

            if book.aboutBook == nil { book.aboutBook = found.aboutBook }
            if book.aboutAuthor == nil { book.aboutAuthor = found.aboutAuthor }
            if !found.sources.isEmpty {
                book.aboutSources = found.sources.joined(separator: "\n")
            }
            try? modelContext.save()
        }
    }

    /// Chapter summaries are keyed to a book by id rather than by a relationship, so
    /// they need clearing by hand when the book goes.
    static func deleteSummaries(for book: Book, modelContext: ModelContext) {
        let id = book.id
        let descriptor = FetchDescriptor<ChapterSummary>(predicate: #Predicate { $0.bookID == id })
        guard let orphans = try? modelContext.fetch(descriptor) else { return }
        for summary in orphans { modelContext.delete(summary) }
    }
}
