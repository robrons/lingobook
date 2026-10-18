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
        #if !os(tvOS)
        .onHover { isHovered = $0 }
        #endif
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.accessibilityDescription)
    }
}

extension Color {
    /// A shelf-friendly tint chosen by hashing the title.
    ///
    /// Hashing rather than randomising so the same book is the same colour every
    /// launch; the palette is Books-ish board colours, dark enough for white text.
    static func generatedCoverTint(for title: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.13, green: 0.42, blue: 0.22),  // bottle green
            Color(red: 0.16, green: 0.32, blue: 0.52),  // ink blue
            Color(red: 0.52, green: 0.20, blue: 0.16),  // brick
            Color(red: 0.36, green: 0.26, blue: 0.47),  // plum
            Color(red: 0.55, green: 0.38, blue: 0.12),  // ochre
            Color(red: 0.14, green: 0.38, blue: 0.40)   // teal
        ]
        // A stable hash: Swift's hashValue is seeded per-launch, which would repaint
        // the shelf on every start.
        let stable = title.unicodeScalars.reduce(5381 as UInt64) { ($0 << 5) &+ $0 &+ UInt64($1.value) }
        return palette[Int(stable % UInt64(palette.count))]
    }
}

/// The cover art, or a stand-in when the EPUB didn't carry one.
struct BookCover: View {
    let book: Book

    var body: some View {
        if let coverImage = book.coverImage {
            #if os(macOS)
            Image(nsImage: coverImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
            #else
            Image(uiImage: coverImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
            #endif
        } else {
            // Books' treatment of a coverless book: a solid tinted board with the title
            // set on it in serif caps, so the cover itself says which book this is. The
            // tint is derived from the title, stable across launches, so each book keeps
            // its own colour and a shelf of stand-ins doesn't read as one orange blur.
            let tint = Color.generatedCoverTint(for: book.title)

            LinearGradient(
                colors: [tint, tint.opacity(0.75)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                GeometryReader { geo in
                    VStack(spacing: geo.size.height * 0.04) {
                        Spacer()

                        Text(book.title)
                            .font(.system(size: geo.size.height * 0.11, design: .serif))
                            .fontWeight(.medium)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .minimumScaleFactor(0.6)

                        Spacer()

                        Text(book.author)
                            .font(.system(size: geo.size.height * 0.055, design: .serif))
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, geo.size.width * 0.1)
                    .padding(.vertical, geo.size.height * 0.08)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            // The card announces title and author itself; repeating them here would make
            // VoiceOver read every book twice.
            .accessibilityHidden(true)
        }
    }
}
