import SwiftUI

/// Book card for library grid display.
///
/// Follows Books' shelf: the cover is the whole card — no title or author beneath,
/// because the cover itself carries them (real art, or the generated board with the
/// title set on it). Below sits only a small reading-progress percent, as in Books.
struct BookCard: View {
    let book: Book

    @State private var isHovered = false

    /// Only meaningful once you've actually opened the book — a "0%" on every unread
    /// cover would be noise.
    private var hasStarted: Bool {
        book.lastReadDate != nil && book.readingProgress > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BookCover(book: book)
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(isHovered ? 0.3 : 0.15), radius: isHovered ? 12 : 6, y: isHovered ? 6 : 3)
                .scaleEffect(isHovered ? 1.03 : 1.0)
                .animation(.easeOut(duration: 0.2), value: isHovered)

            Text(hasStarted ? "\(book.progressPercent)%" : " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.accessibilityDescription)
    }
}
