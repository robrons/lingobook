import SwiftUI

/// Top toolbar for the reader view
struct ReaderToolbar: View {
    let bookTitle: String
    let theme: BookTheme
    let onBack: () -> Void
    let onShowTOC: () -> Void
    let onShowSummary: () -> Void
    @Binding var showThemeSettings: Bool
    
    var body: some View {
        HStack(spacing: 0) {
            // Left side: Back + TOC
            HStack(spacing: 16) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textColor.opacity(0.7))
                
                Button(action: onShowTOC) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textColor.opacity(0.7))
            }
            
            Spacer()
            
            // Center: Book title
            Text(bookTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textColor.opacity(0.8))
                .lineLimit(1)
            
            Spacer()
            
            // Right side: Summarize + AA
            HStack(spacing: 16) {
                Button(action: onShowSummary) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textColor.opacity(0.7))
                
                Button { showThemeSettings.toggle() } label: {
                    Text("AA")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textColor.opacity(0.7))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

#Preview {
    ReaderToolbar(
        bookTitle: "Le Comte de Monte-Cristo",
        theme: .paper,
        onBack: {},
        onShowTOC: {},
        onShowSummary: {},
        showThemeSettings: .constant(false)
    )
}
