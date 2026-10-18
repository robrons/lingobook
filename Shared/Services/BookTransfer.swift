import Foundation
import Network

/// A book on its way from the Mac to the Apple TV: the EPUB plus everything the Mac
/// translated, since the TV has no way to translate it itself.
///
/// The wire format is deliberately dull. The Mac connects, sends one length-prefixed
/// binary plist, and waits for a single byte back saying the TV saved it.
struct BookTransfer: Codable {
    var id: UUID
    var title: String
    var author: String
    var language: String?
    var epubData: Data
    var coverData: Data?
    var translationsData: Data?

    static let serviceType = "_lingobook._tcp"

    /// Sent back once the book is safely in the TV's library.
    static let acknowledgement: UInt8 = 0x06

    /// Generous: a book with images can run to tens of megabytes. Anything past this is
    /// not a book, and refusing it keeps a stray connection from exhausting memory.
    static let maximumSize = 512 * 1024 * 1024

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let body = try encoder.encode(self)
        var length = UInt64(body.count).bigEndian
        return Data(bytes: &length, count: MemoryLayout<UInt64>.size) + body
    }

    static func decode(body: Data) throws -> BookTransfer {
        try PropertyListDecoder().decode(BookTransfer.self, from: body)
    }

    static func length(fromHeader header: Data) -> Int? {
        guard header.count == MemoryLayout<UInt64>.size else { return nil }
        let value = header.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard value > 0, value <= UInt64(maximumSize) else { return nil }
        return Int(value)
    }
}
