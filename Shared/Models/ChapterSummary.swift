import Foundation
import SwiftData

/// What happened in one chapter, written down when the reader finished it.
///
/// The tutor's memory of the story. Asked "what's happened so far?", a model without
/// these answers from a general recollection of the novel — which recaps events the
/// reader hasn't reached yet, and invents them outright for any book it barely knows.
/// These rows are the alternative: an account of *this* reading, assembled only from
/// chapters actually turned past.
///
/// A row per chapter rather than one blob on `Book`, because summaries arrive one at a
/// time across weeks of reading. Per-row writes stay small, a single bad summary can be
/// replaced on its own, and nothing re-encodes a growing document on every page turn.
@Model
final class ChapterSummary {
    /// Keyed by `Book.id` rather than by a relationship: the query this always runs is
    /// "summaries for this book, in chapter order", and the delete path clears them
    /// alongside the book.
    var bookID: UUID = UUID()
    var chapterIndex: Int = 0
    var chapterTitle: String = ""

    /// Three to five sentences. Empty means the chapter had no events worth recording —
    /// a title page, a table of contents — which is different from not having tried, and
    /// stops the backfill from asking about it again every time the book opens.
    var text: String = ""

    /// Which model wrote it. A summary is only as trustworthy as its author, and this is
    /// what makes it possible to regenerate everything a weaker model produced.
    var modelName: String = ""
    var createdAt: Date = Date()

    init(
        bookID: UUID,
        chapterIndex: Int,
        chapterTitle: String,
        text: String,
        modelName: String
    ) {
        self.bookID = bookID
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.text = text
        self.modelName = modelName
        self.createdAt = Date()
    }

    var hasEvents: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
