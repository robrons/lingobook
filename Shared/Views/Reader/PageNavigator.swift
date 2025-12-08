import SwiftUI

/// Bottom page navigation bar with previous/next buttons and page info
struct PageNavigator: View {
    let currentPage: Int
    let totalPages: Int
    let chapterTitle: String
    let hasChapters: Bool
    let canGoPrevious: Bool
    let canGoNext: Bool
    let theme: BookTheme
    let onPrevious: () -> Void
    let onNext: () -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            // Previous Page Button
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    onPrevious()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("Previous")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(canGoPrevious ? theme.textColor.opacity(0.7) : theme.textColor.opacity(0.25))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(canGoPrevious ? theme.textColor.opacity(0.05) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canGoPrevious)
            
            Spacer()
            
            // Page Info
            VStack(spacing: 2) {
                Text("Page \(currentPage) of \(max(1, totalPages))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textColor.opacity(0.5))
                
                if hasChapters {
                    Text(chapterTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textColor.opacity(0.35))
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Next Page Button
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    onNext()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Next")
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(canGoNext ? theme.textColor.opacity(0.7) : theme.textColor.opacity(0.25))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(canGoNext ? theme.textColor.opacity(0.05) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canGoNext)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(theme.pageColor.opacity(0.95))
    }
}

#Preview {
    PageNavigator(
        currentPage: 5,
        totalPages: 42,
        chapterTitle: "Chapter 1: The Beginning",
        hasChapters: true,
        canGoPrevious: true,
        canGoNext: true,
        theme: .paper,
        onPrevious: {},
        onNext: {}
    )
}
