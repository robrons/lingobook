import SwiftUI

/// Book card for library grid display
struct BookCard: View {
    let book: Book
    
    #if os(macOS)
    @State private var isHovered = false
    #endif
    
    var body: some View {
        VStack(spacing: 0) {
            // Cover image
            ZStack {
                if let coverImage = book.coverImage {
                    #if os(iOS)
                    Image(uiImage: coverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    #else
                    Image(nsImage: coverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    #endif
                } else {
                    // Fallback gradient cover
                    LinearGradient(
                        colors: [.orange, .orange.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: "book.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
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
                        
                        Text(book.author)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
                
                Text(book.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            #endif
        }
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .contentShape(Rectangle())
    }
}
