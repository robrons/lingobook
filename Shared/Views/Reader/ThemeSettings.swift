import SwiftUI

/// Themes & Settings, as Apple TV lays it out: a panel down the right of the page, so
/// every change shows on the text beside it as you make it.
///
/// Size, light or dark, the six themes, then Customize — font, bold, spacing, margins,
/// justification — kept per theme with the book. Then, for a book with a translation,
/// how it's shown. Read-aloud language and the voice live in Settings (⌘,).
struct ThemeSettings: View {
    @Binding var fontSize: CGFloat
    @Binding var currentTheme: BookTheme
    @Binding var layoutMode: LayoutMode
    @Binding var readingStyle: ReadingStyle
    /// Every theme's customizations, so each tile previews its theme as it would set the page.
    let themeStyles: ThemeStyles
    let isThemeCustomized: Bool
    let onResetTheme: () -> Void
    /// An English book has nothing to translate, so no translation choices either.
    let needsTranslation: Bool

    /// Light, Dark, or following the device — for every book, as in Books.
    @AppStorage(ReaderAppearance.key) private var appearanceRaw = ReaderAppearance.automatic.rawValue
    private var appearance: ReaderAppearance { ReaderAppearance(rawValue: appearanceRaw) ?? .automatic }

    /// Books' size ladder: fine steps where most people read, bigger ones at the top.
    static let fontSizes: [CGFloat] = [12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 26, 28, 32]

    static let width: CGFloat = 340

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Themes & Settings")
                    .font(.system(size: 18, weight: .bold))
                sizeRow
                appearanceRow
                themeGrid
                customize
                if needsTranslation {
                    translationRows
                }
            }
            .padding(22)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        // Follows the page: Night stays night instead of a bright slab over the text.
        .environment(\.colorScheme, currentTheme.isDark ? .dark : .light)
    }

    // MARK: - Size, appearance, themes

    private var sizeIndex: Int {
        Self.fontSizes.lastIndex { $0 <= fontSize } ?? 0
    }

    private var sizeRow: some View {
        HStack(spacing: 10) {
            Button {
                fontSize = Self.fontSizes[max(0, sizeIndex - 1)]
            } label: {
                Text("A").font(.system(size: 14, design: .serif))
            }
            .disabled(sizeIndex == 0)
            .accessibilityLabel("Smaller text")

            // Where you are on the ladder, as Books marks it.
            HStack(spacing: 5) {
                ForEach(Self.fontSizes.indices, id: \.self) { index in
                    Circle()
                        .fill(Color.primary.opacity(index <= sizeIndex ? 0.75 : 0.18))
                        .frame(width: 5, height: 5)
                }
            }
            .fixedSize()
            .accessibilityHidden(true)

            Button {
                fontSize = Self.fontSizes[min(Self.fontSizes.count - 1, sizeIndex + 1)]
            } label: {
                Text("A").font(.system(size: 22, design: .serif))
            }
            .disabled(sizeIndex == Self.fontSizes.count - 1)
            .accessibilityLabel("Larger text")
        }
        .buttonStyle(PanelRowButtonStyle())
    }

    /// Light, Dark, or Automatic — the device's own setting.
    private var appearanceRow: some View {
        HStack(spacing: 8) {
            ForEach(ReaderAppearance.allCases, id: \.self) { option in
                Button {
                    appearanceRaw = option.rawValue
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 15, weight: .medium))
                        Text(option.name)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .overlay(alignment: .topTrailing) {
                        if option == appearance {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .padding(-6)
                        }
                    }
                }
                .buttonStyle(PanelRowButtonStyle(isSelected: option == appearance))
                .accessibilityLabel(option.name)
                .accessibilityAddTraits(option == appearance ? .isSelected : [])
            }
        }
    }

    private var themeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(BookTheme.families, id: \.self) { family in
                let option = family.appearance(dark: currentTheme.isDark)
                Button {
                    currentTheme = option
                } label: {
                    ThemeTile(theme: option, style: themeStyles.style(for: option), isSelected: option == currentTheme)
                }
                .buttonStyle(SwatchButtonStyle())
                .accessibilityLabel("\(family.name) theme")
                .accessibilityAddTraits(option == currentTheme ? [.isSelected] : [])
            }
        }
    }

    // MARK: - Customize

    private var customize: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Customize")

            ForEach(ReaderFont.available, id: \.self) { font in
                Button {
                    readingStyle.font = font
                } label: {
                    HStack {
                        Text(font.name)
                            .font(Font(font.platformFont(size: 15, weight: .regular, italic: false) as CTFont))
                        Spacer()
                        if readingStyle.font == font {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(PanelRowButtonStyle(alignment: .leading))
            }

            toggleRow("Bold Text", isOn: readingStyle.boldText) {
                readingStyle.boldText.toggle()
            }

            stepRow("Line Spacing", value: \.lineSpacing)
            stepRow("Character Spacing", value: \.characterSpacing)
            stepRow("Word Spacing", value: \.wordSpacing)
            stepRow("Margins", value: \.margins)

            toggleRow("Justify Text", isOn: readingStyle.justified) {
                readingStyle.justified.toggle()
            }

            Button("Reset Theme", action: onResetTheme)
                .buttonStyle(PanelRowButtonStyle())
                .disabled(!isThemeCustomized)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func toggleRow(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(isOn ? "On" : "Off")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(PanelRowButtonStyle(alignment: .leading))
    }

    /// Books uses a slider; this is the TV's row of notches, clicked down and up.
    private func stepRow(_ title: String, value: WritableKeyPath<ReadingStyle, Int>) -> some View {
        let current = readingStyle[keyPath: value]
        return HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Button {
                readingStyle[keyPath: value] = max(0, current - 1)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(current == 0)
            .accessibilityLabel("Less \(title.lowercased())")

            HStack(spacing: 3) {
                ForEach(0..<ReadingStyle.steps, id: \.self) { step in
                    Capsule()
                        .fill(Color.primary.opacity(step <= current ? 0.75 : 0.18))
                        .frame(width: 9, height: 4)
                }
            }
            .fixedSize()
            .accessibilityHidden(true)

            Button {
                readingStyle[keyPath: value] = min(ReadingStyle.steps - 1, current + 1)
            } label: {
                Image(systemName: "plus")
            }
            .disabled(current == ReadingStyle.steps - 1)
            .accessibilityLabel("More \(title.lowercased())")
        }
        .buttonStyle(PanelRowButtonStyle(compact: true))
        .padding(.leading, 14)
        .padding(.vertical, 2)
    }

    // MARK: - Translation

    private var translationRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Translation")
            translationOption("Off", mode: .original)
            translationOption("Under Each Sentence", mode: .interleaved)
            translationOption("Side by Side", mode: .sideBySide)
        }
    }

    private func translationOption(_ title: String, mode: LayoutMode) -> some View {
        Button {
            layoutMode = mode
        } label: {
            HStack {
                Text(title)
                Spacer()
                if layoutMode == mode {
                    Image(systemName: "checkmark")
                }
            }
        }
        .buttonStyle(PanelRowButtonStyle(alignment: .leading))
    }
}

/// A theme as Books shows it in Themes & Settings: "Aa" in the theme's own type, on its
/// own page, named beneath.
private struct ThemeTile: View {
    let theme: BookTheme
    let style: ReadingStyle
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text("Aa")
                .font(Font(style.font.platformFont(
                    size: 22,
                    weight: style.boldText ? .bold : .regular,
                    italic: false
                ) as CTFont))
            // Books names a theme the same in light and dark.
            Text(theme.family.name)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(theme.textColor)
        .frame(maxWidth: .infinity)
        .frame(height: 66)
        .background(theme.pageColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                              lineWidth: isSelected ? 2.5 : 1)
        }
    }
}

/// Rows and keys inside the reader's panels: the TV's quiet filled rows, lifting under
/// the pointer where the TV lifts them under focus.
struct PanelRowButtonStyle: ButtonStyle {
    var alignment: Alignment = .center
    var compact = false
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, alignment: alignment, compact: compact, isSelected: isSelected)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let alignment: Alignment
        let compact: Bool
        let isSelected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, compact ? 0 : 14)
                .frame(width: compact ? 30 : nil, height: compact ? 26 : nil)
                .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 26 : 38, alignment: alignment)
                .background {
                    RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                        .fill(Color.primary.opacity(
                            configuration.isPressed ? 0.2 : (isHovered && isEnabled) || isSelected ? 0.14 : 0.07
                        ))
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.35)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

private struct SwatchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.96 : isHovered ? 1.04 : 1)
                .shadow(color: .black.opacity(isHovered ? 0.18 : 0), radius: 8, y: 4)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isHovered)
        }
    }
}

#Preview {
    ThemeSettings(
        fontSize: .constant(17),
        currentTheme: .constant(.calm),
        layoutMode: .constant(.sideBySide),
        readingStyle: .constant(ReadingStyle()),
        themeStyles: ThemeStyles(),
        isThemeCustomized: false,
        onResetTheme: {},
        needsTranslation: true
    )
}
