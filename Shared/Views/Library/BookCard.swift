import SwiftUI

/// Book card for library grid display
struct BookCard: View {
    let book: Book

    #if os(macOS)
    @State private var isHovered = false
    #endif

    /// Only meaningful once you've actually opened the book — a "0%" on every unread
    /// cover would be noise.
    private var hasStarted: Bool {
        book.lastReadDate != nil && book.readingProgress > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            BookCover(book: book)
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
            #if os(macOS)
                .shadow(color: .black.opacity(isHovered ? 0.3 : 0.15), radius: isHovered ? 12 : 6, y: isHovered ? 6 : 3)
                .scaleEffect(isHovered ? 1.03 : 1.0)
                .animation(.easeOut(duration: 0.2), value: isHovered)
                .overlay(alignment: .bottom) {
                    if isHovered {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title)
                                .font(.caption.bold())
                                .lineLimit(2)

                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(book.author)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.75))
                                    .lineLimit(1)

                                if hasStarted {
                                    Spacer(minLength: 0)
                                    Text("\(book.progressPercent)%")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.75))
                                        .monospacedDigit()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .foregroundStyle(.white)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8))
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            #else
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            #endif

            // iOS: Always show title
            #if os(iOS)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.caption.bold())
                    .lineLimit(2)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(book.author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if hasStarted {
                        Spacer(minLength: 0)
                        Text("\(book.progressPercent)%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            #endif
        }
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(book.accessibilityDescription)
    }
}
