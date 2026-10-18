import SwiftUI

/// Top toolbar for the reader view
struct ReaderToolbar: View {
    let bookTitle: String
    let theme: BookTheme
    let onBack: () -> Void
    let onShowTOC: () -> Void
    let isReading: Bool
    let onToggleRead: () -> Void
    let isListening: Bool
    let onToggleListening: () -> Void
    @Binding var showThemeSettings: Bool
    
    var body: some View {
        HStack(spacing: 0) {
            // Left side: Back + TOC
            HStack(spacing: 16) {
                // No pill: Books gives the back affordance no more weight than the text
                // it sits above.
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Library")
                            .font(.system(size: 15, weight: .regular))
                    }
                    .padding(.vertical, 6)
                    .readerTouchTarget()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textColor.opacity(0.8))
                
                Button(action: onShowTOC) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14))
                        .readerTouchTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textColor.opacity(0.7))
                .accessibilityLabel("Table of contents")
            }
            
            Spacer()
            
            // Center: Book title
            Text(bookTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textColor.opacity(0.8))
                .lineLimit(1)
            
            Spacer()
            
            // Right side: Mic + Audio + AA
            HStack(spacing: 16) {
                Button(action: onToggleListening) {
                    Image(systemName: isListening ? "mic.fill" : "mic")
                        .font(.system(size: 14))
                        .foregroundStyle(isListening ? .red : theme.textColor.opacity(0.7))
                        .readerTouchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isListening ? "Stop voice commands" : "Voice commands")
                
                Button(action: onToggleRead) {
                    Image(systemName: isReading ? "stop.circle.fill" : "speaker.wave.2")
                        .font(.system(size: 14))
                        .foregroundStyle(isReading ? .red : theme.textColor.opacity(0.7))
                        .readerTouchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isReading ? "Stop reading" : "Read aloud")

                Button { showThemeSettings.toggle() } label: {
                    Text("AA")
                        .font(.system(size: 14, weight: .medium))
                        .readerTouchTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textColor.opacity(0.7))
                .accessibilityLabel("Reading appearance")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // The bar floats over the page now, so it needs just enough of the page colour
        // behind it to stay legible over text — and a hairline to sit on.
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                theme.pageColor.opacity(0.9)
                Rectangle()
                    .fill(theme.textColor.opacity(0.08))
                    .frame(height: 1)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func readerTouchTarget() -> some View {
        #if os(iOS)
        self.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        #else
        self
        #endif
    }
}

#Preview {
    ReaderToolbar(
        bookTitle: "Le Comte de Monte-Cristo",
        theme: .calm,
        onBack: {},
        onShowTOC: {},
        isReading: false,
        onToggleRead: {},
        isListening: false,
        onToggleListening: {},
        showThemeSettings: .constant(false)
    )
}
