import SwiftUI

/// The reader's top bar, as Apple TV lays it out: Library and Contents on the left, the
/// title centred over the page, Ask and Aa on the right — quiet capsules in the theme's
/// ink that fill in under the pointer, the way the TV's fill in under focus. The Mac
/// keeps read-aloud and voice commands beside Ask, since it has no Play/Pause button.
struct ReaderToolbar: View {
    let bookTitle: String
    let theme: BookTheme
    let onBack: () -> Void
    let isContentsOpen: Bool
    let onToggleContents: () -> Void
    let isReading: Bool
    let onToggleRead: () -> Void
    let isListening: Bool
    let onToggleListening: () -> Void
    let isAskOpen: Bool
    let onToggleAsk: () -> Void
    let isSettingsOpen: Bool
    let onToggleSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Label("Library", systemImage: "chevron.left")
            }
            .buttonStyle(ChromeButtonStyle(theme: theme))

            Button(action: onToggleContents) {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(ChromeButtonStyle(theme: theme, isCircular: true, isOn: isContentsOpen))
            .accessibilityLabel("Contents")

            Spacer()

            Button(action: onToggleListening) {
                Image(systemName: isListening ? "mic.fill" : "mic")
            }
            .buttonStyle(ChromeButtonStyle(theme: theme, isCircular: true, isOn: isListening))
            .accessibilityLabel(isListening ? "Stop voice commands" : "Voice commands")

            Button(action: onToggleRead) {
                Image(systemName: isReading ? "pause.fill" : "play.fill")
            }
            .buttonStyle(ChromeButtonStyle(theme: theme, isCircular: true, isOn: isReading))
            .accessibilityLabel(isReading ? "Stop reading" : "Read aloud")

            Button(action: onToggleAsk) {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(ChromeButtonStyle(theme: theme, isCircular: true, isOn: isAskOpen))
            .accessibilityLabel(isAskOpen ? "Close Ask" : "Ask Claude about this page")

            Button(action: onToggleSettings) {
                Image(systemName: "textformat.size")
            }
            .buttonStyle(ChromeButtonStyle(theme: theme, isCircular: true, isOn: isSettingsOpen))
            .accessibilityLabel("Themes & Settings")
        }
        // Centred on the page, not between buttons of different widths — the same centre
        // line as the spread's gutter below it.
        .overlay {
            Text(bookTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(theme.textColor.opacity(0.8))
                .frame(maxWidth: 420)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

/// Reader chrome: quiet until the pointer is on it, then filled in the theme's ink, so
/// the controls belong to the page rather than sitting on it as system buttons.
private struct ChromeButtonStyle: ButtonStyle {
    let theme: BookTheme
    var isCircular = false
    /// Its panel is open, or what it starts is under way.
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, theme: theme, isCircular: isCircular, isOn: isOn)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let theme: BookTheme
        let isCircular: Bool
        let isOn: Bool
        @State private var isHovered = false

        private var isFilled: Bool { isHovered || isOn }

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isFilled ? theme.pageColor : theme.textColor.opacity(0.85))
                .padding(.horizontal, isCircular ? 0 : 14)
                #if os(iOS)
                .frame(width: isCircular ? 44 : nil, height: 44)
                #else
                .frame(width: isCircular ? 32 : nil, height: 32)
                #endif
                .background {
                    Capsule().fill(isFilled ? theme.textColor : theme.textColor.opacity(0.08))
                }
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isFilled)
        }
    }
}

#Preview {
    ReaderToolbar(
        bookTitle: "Le Comte de Monte-Cristo",
        theme: .calm,
        onBack: {},
        isContentsOpen: false,
        onToggleContents: {},
        isReading: false,
        onToggleRead: {},
        isListening: false,
        onToggleListening: {},
        isAskOpen: false,
        onToggleAsk: {},
        isSettingsOpen: false,
        onToggleSettings: {}
    )
}
