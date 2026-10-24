import SwiftUI

/// The "AA" popover: choices about *reading this book right now*.
///
/// Deliberately not a settings screen. Anything you set once and forget — TTS engine,
/// API key, voice — lives in Settings (⌘,). Read language appears in both, because it's
/// both a preference and a reading choice;
/// they share one AppStorage key, so they can't disagree.
struct ThemeSettings: View {
    @Binding var fontSize: CGFloat
    @Binding var currentTheme: BookTheme
    @Binding var layoutMode: LayoutMode

    @AppStorage("ttsLanguage") private var ttsLanguageRaw = TTSLanguage.both.rawValue

    var body: some View {
        VStack(spacing: 16) {
            // Font size
            HStack(spacing: 0) {
                Button { if fontSize > 12 { fontSize -= 2 } } label: {
                    Text("A")
                        .font(.system(size: 14, weight: .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.plain)
                .disabled(fontSize <= 12)

                Divider().frame(height: 26)

                Button { if fontSize < 28 { fontSize += 2 } } label: {
                    Text("A")
                        .font(.system(size: 20, weight: .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.plain)
                .disabled(fontSize >= 28)
            }
            // Was a hardcoded beige, which turned into a bright slab in Night theme.
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            // Themes
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 72), spacing: 10)],
                spacing: 12
            ) {
                ForEach(BookTheme.macChoices, id: \.self) { theme in
                    themeButton(theme)
                }
            }

            Divider().padding(.horizontal, -20)

            VStack(alignment: .leading, spacing: 10) {
                Text("Layout")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("Layout", selection: $layoutMode) {
                    ForEach(LayoutMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Read Aloud")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("Read Language", selection: $ttsLanguageRaw) {
                    ForEach(TTSLanguage.allCases) { lang in
                        Text(lang.rawValue).tag(lang.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(20)
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        // No hardcoded cream, no forced .light: the popover follows the reader's theme,
        // so Night stays night instead of flashing a bright rectangle over the page.
        .background(.regularMaterial)
        .environment(\.colorScheme, currentTheme.isDark ? .dark : .light)
    }

    private func themeButton(_ theme: BookTheme) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                currentTheme = theme
            }
        } label: {
            VStack(spacing: 6) {
                Text("Aa")
                    .font(.system(size: 20, weight: .regular, design: .serif))
                    .foregroundStyle(theme.previewTextColor)
                    .frame(width: 72, height: 52)
                    .background(theme.previewBgColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            // Hairline on every swatch so Paper and White don't vanish
                            // into a light popover.
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                currentTheme == theme ? Color.accentColor : .clear,
                                lineWidth: 2
                            )
                    )

                Text(theme.name)
                    .font(.system(size: 11, weight: currentTheme == theme ? .medium : .regular))
                    .foregroundStyle(currentTheme == theme ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(currentTheme == theme ? [.isSelected] : [])
    }
}

#Preview {
    ThemeSettings(
        fontSize: .constant(17),
        currentTheme: .constant(.calm),
        layoutMode: .constant(.sideBySide)
    )
}
