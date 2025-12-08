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
    var currentPageIndex: Int?
    
    init(title: String, author: String, epubData: Data, coverData: Data? = nil) {
        self.id = UUID()
        self.title = title
        self.author = author
        self.epubData = epubData
        self.coverData = coverData
        self.dateAdded = Date()
        self.currentChapterIndex = 0
        self.currentPageIndex = 0
    }
    
    /// Returns the cover as a platform-appropriate image
    var coverImage: PlatformImage? {
        guard let data = coverData else { return nil }
        return PlatformImage.from(data: data)
    }
}
