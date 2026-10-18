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

    // MARK: - Saved translations

    /// Every translation made for this book, encoded `TranslationMemory`.
    ///
    /// Filled a page at a time as you read on a Mac or iPad, or all at once by "Send to
    /// Apple TV" — the TV can't translate, so it reads only what arrives here.
    @Attribute(.externalStorage) var translationsData: Data?

    /// Where this book stands with the Apple TV. Raw `AppleTVStatus`; only the Mac sets it.
    var appleTVStatusRaw: String = AppleTVStatus.none.rawValue

    var appleTVStatus: AppleTVStatus {
        get { AppleTVStatus(rawValue: appleTVStatusRaw) ?? .none }
        set { appleTVStatusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        epubData: Data,
        coverData: Data? = nil,
        language: String? = nil
    ) {
        self.id = id
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
        #if os(tvOS)
        // Read from the sofa, not from arm's length.
        self.savedFontSize = 34.0
        #else
        self.savedFontSize = 17.0
        #endif
        self.savedThemeName = BookTheme.calm.rawValue
        #if os(macOS)
        self.savedLayoutMode = LayoutMode.sideBySide.rawValue
        #else
        self.savedLayoutMode = LayoutMode.interleaved.rawValue
        #endif
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

/// A book's journey to the Apple TV, as the Mac sees it.
enum AppleTVStatus: String {
    /// Never sent.
    case none
    /// Translating the whole book before it can go.
    case preparing
    /// Translated; goes the next time an Apple TV running LingoBook is on the network.
    case waiting
    /// The TV confirmed it has the book.
    case sent
}

/// Reader layout options
enum LayoutMode: String, CaseIterable {
    case sideBySide = "Side by Side"
    case interleaved = "Interleaved"
}
