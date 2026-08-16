import SwiftData
import Foundation

/// Represents a book in the user's library
@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String
    @Attribute(.externalStorage) var coverData: Data?
    @Attribute(.externalStorage) var epubData: Data
    var dateAdded: Date
    var lastLocation: String?
    var lastReadDate: Date?
    var currentChapterIndex: Int
    var currentPageIndex: Int
    /// Character offset of the reading position within the chapter. Unlike `currentPageIndex`
    /// this stays meaningful when the window, font size, or layout mode changes.
    var currentOffset: Int = 0
    /// How far through the whole book the reader is, 0…1. Chapter-weighted rather than
    /// character-exact — cheap to keep current, and close enough to show on a shelf.
    var readingProgress: Double = 0
    var totalChapters: Int = 0
    var savedFontSize: Double
    var savedThemeName: String
    var savedLayoutMode: String

    // MARK: - What the tutor knows about this book

    /// The book's own language, from the EPUB's `<dc:language>`.
    ///
    /// The parser has always read this and then dropped it. The tutor needs it to pick a
    /// Wikipedia to fall back to, and to stop asserting that every page is French.
    var language: String?

    /// Wikipedia's account of the book and of its author, fetched once at import.
    ///
    /// Stored rather than looked up per question: it never changes, and a reader who is
    /// offline on a train should still get the publication history right.
    var aboutBook: String?
    var aboutAuthor: String?
    /// The article URLs behind the two fields above, newline-separated. Attribution, and
    /// the beginning of a way to refresh a bad match.
    var aboutSources: String?
    /// When grounding was last attempted, successfully or not. Stops a book with no
    /// Wikipedia article from asking again on every single open.
    var groundingAttemptedAt: Date?

    /// Everything that happened before the recent chapters, folded into one paragraph.
    ///
    /// See `StorySummarizer`: without compaction a long book's recap grows until it
    /// crowds out the page the reader is on.
    var storyDigest: String?
    /// The last chapter index the digest covers. -1 means nothing has been folded in yet.
    var digestThroughChapter: Int = -1

    init(
        title: String,
        author: String,
        epubData: Data,
        coverData: Data? = nil,
        language: String? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.author = author
        self.epubData = epubData
        self.coverData = coverData
        self.language = language
        self.dateAdded = Date()
        self.currentChapterIndex = 0
        self.currentPageIndex = 0
        self.currentOffset = 0
        self.readingProgress = 0
        self.totalChapters = 0
        self.savedFontSize = 17.0
        self.savedThemeName = BookTheme.calm.rawValue
        self.savedLayoutMode = LayoutMode.sideBySide.rawValue
    }
    
    /// Returns the cover as a platform-appropriate image
    var coverImage: PlatformImage? {
        guard let data = coverData else { return nil }
        return PlatformImage.from(data: data)
    }

    /// Whether this is the same book as the given metadata, for import dedupe.
    ///
    /// Ignores case and accents: the same French novel from two sources can differ by
    /// "Le Comte de Monte-Cristo" vs "Le comte de Monte Cristo".
    func matches(title otherTitle: String, author otherAuthor: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        return normalized(title) == normalized(otherTitle)
            && normalized(author) == normalized(otherAuthor)
    }

    /// Progress as a whole percent, for display.
    var progressPercent: Int {
        Int((readingProgress * 100).rounded())
    }

    /// The background the tutor is given about this book, or nil when the lookup found
    /// nothing it was confident about.
    var aboutBlock: String? {
        var parts: [String] = []
        if let aboutBook, !aboutBook.isEmpty {
            parts.append("About “\(title)”: \(aboutBook)")
        }
        if let aboutAuthor, !aboutAuthor.isEmpty {
            parts.append("About \(author): \(aboutAuthor)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// How the book announces itself to VoiceOver.
    ///
    /// Everything the card shows visually, in a single phrase. A cover made of separate
    /// text elements is read out as a stream of disconnected fragments — title, then
    /// author, then a bare number — with no indication they describe one book.
    var accessibilityDescription: String {
        var parts = [title, "by \(author)"]
        if lastReadDate != nil, readingProgress > 0 {
            parts.append("\(progressPercent) percent read")
        }
        return parts.joined(separator: ", ")
    }
}

/// Reader layout options
enum LayoutMode: String, CaseIterable {
    case sideBySide = "Side by Side"
    case interleaved = "Interleaved"
}
