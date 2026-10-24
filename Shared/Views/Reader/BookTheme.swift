import SwiftUI

/// Theme options for the book reader.
///
/// Preview colours are derived from the real page/text colours rather than hand-picked,
/// so a swatch can never drift from the page it promises.
///
/// The Mac offers the original five. Apple TV offers Books' six — Original, Quiet, Paper,
/// Bold, Calm, Focus — each in a light and a dark version, the way Books pairs every
/// theme with a dark appearance. `paper`, `calm`, `night` and `gray` serve both lists, so
/// a book read on one keeps a sensible look on the other.
enum BookTheme: String, CaseIterable {
    case paper, calm, sepia, gray, night
    case original, quiet, bold, focus
    case paperDark, boldDark, calmDark, focusDark

    /// What the Mac's theme popover offers.
    static let macChoices: [BookTheme] = [.paper, .calm, .sepia, .gray, .night]

    /// Books' six, in Books' order, as they look on a light page.
    static let families: [BookTheme] = [.original, .quiet, .paper, .bold, .calm, .focus]

    /// The light theme this one is a version of.
    var family: BookTheme {
        switch self {
        case .original, .night: return .original
        case .quiet, .gray: return .quiet
        case .paper, .paperDark: return .paper
        case .bold, .boldDark: return .bold
        case .calm, .calmDark, .sepia: return .calm
        case .focus, .focusDark: return .focus
        }
    }

    /// This theme's family, on a light or a dark page.
    func appearance(dark: Bool) -> BookTheme {
        switch family {
        case .original: return dark ? .night : .original
        case .quiet: return dark ? .gray : .quiet
        case .paper: return dark ? .paperDark : .paper
        case .bold: return dark ? .boldDark : .bold
        case .focus: return dark ? .focusDark : .focus
        default: return dark ? .calmDark : .calm
        }
    }

    var name: String {
        switch self {
        case .paperDark, .boldDark, .calmDark, .focusDark: return family.name
        default: return rawValue.capitalized
        }
    }

    /// Books' Bold theme sets heavier type, not just darker ink.
    var setsBoldText: Bool { self == .bold || self == .boldDark }

    /// The key a theme's customizations are kept under: light and dark share one.
    var styleKey: String { family.rawValue }

    // Background color for reading
    var pageColor: Color { colors.page }

    // Text color when reading
    var textColor: Color { colors.text }

    /// Page and ink. On Apple TV these are Books' own, sampled from Books itself — pages
    /// and the theme tiles of its Themes & Settings panel, light and dark. The Mac keeps
    /// the reader's original palette.
    private var colors: (page: Color, text: Color) {
        #if os(tvOS)
        switch self {
        case .original: return (Self.hex(0xFFFFFF), Self.hex(0x121212))
        case .night: return (Self.hex(0x000000), Self.hex(0xF4F4F4))
        case .quiet: return (Self.hex(0x525355), Self.hex(0xBFBFC2))
        case .gray: return (Self.hex(0x000000), Self.hex(0xAAAAAD))
        case .paper: return (Self.hex(0xEFEEEF), Self.hex(0x161516))
        case .paperDark: return (Self.hex(0x252528), Self.hex(0xEDEDED))
        case .bold: return (Self.hex(0xFFFFFF), Self.hex(0x000000))
        case .boldDark: return (Self.hex(0x000000), Self.hex(0xFFFFFF))
        case .calm, .sepia: return (Self.hex(0xF3E4CD), Self.hex(0x1A0F06))
        case .calmDark: return (Self.hex(0x4A4337), Self.hex(0xF8F2E6))
        case .focus: return (Self.hex(0xFFFCF5), Self.hex(0x0D0C08))
        case .focusDark: return (Self.hex(0x1E1D14), Self.hex(0xF7F5EC))
        }
        #else
        switch self {
        case .paper: return (.white, Color(red: 0.1, green: 0.1, blue: 0.1))
        case .calm: return (Color(red: 0.976, green: 0.949, blue: 0.898), Color(red: 0.25, green: 0.2, blue: 0.15))
        case .sepia: return (Color(red: 0.94, green: 0.89, blue: 0.78), Color(red: 0.30, green: 0.22, blue: 0.12))
        case .gray: return (Color(red: 0.165, green: 0.165, blue: 0.18), Color(red: 0.784, green: 0.784, blue: 0.8))
        case .night: return (.black, Color(red: 0.88, green: 0.88, blue: 0.88))
        case .original: return (.white, Color(red: 0.07, green: 0.07, blue: 0.07))
        case .quiet: return (Color(red: 0.29, green: 0.29, blue: 0.30), Color(red: 0.80, green: 0.80, blue: 0.81))
        case .bold: return (.white, .black)
        case .focus: return (Color(red: 0.996, green: 0.973, blue: 0.898), Color(red: 0.12, green: 0.11, blue: 0.08))
        case .paperDark: return (Color(red: 0.11, green: 0.11, blue: 0.118), Color(red: 0.80, green: 0.80, blue: 0.80))
        case .boldDark: return (.black, .white)
        case .calmDark: return (Color(red: 0.165, green: 0.141, blue: 0.11), Color(red: 0.85, green: 0.78, blue: 0.66))
        case .focusDark: return (Color(red: 0.13, green: 0.12, blue: 0.09), Color(red: 0.91, green: 0.87, blue: 0.76))
        }
        #endif
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// How a theme sets type until you customize it — Books' themes are a font and a
    /// spacing as much as a colour. Where Books uses a font Apple TV doesn't have, the
    /// nearest one it does: Iowan Old Style for Calm's Canela, Avenir Next for Focus's
    /// Proxima Nova, Georgia for Paper's Charter. The Mac's themes all start plain.
    var defaultStyle: ReadingStyle {
        var style = ReadingStyle()
        #if os(tvOS)
        switch family {
        case .paper:
            style.font = .georgia
            style.justified = false
        case .bold:
            style.boldText = true
        case .calm:
            style.font = .iowan
            style.justified = false
            style.lineSpacing = 3
        case .focus:
            style.font = .avenirNext
            style.justified = false
            style.lineSpacing = 3
        default:
            break
        }
        #endif
        return style
    }

    // Preview swatch colors — taken straight from the theme so they can't disagree with it.
    var previewBgColor: Color { pageColor }
    var previewTextColor: Color { textColor }

    var colorScheme: ColorScheme? {
        switch self {
        case .paper, .calm, .sepia, .original, .bold, .focus: return .light
        case .gray, .night, .quiet, .paperDark, .boldDark, .calmDark, .focusDark: return .dark
        }
    }

    /// True for themes whose page is dark, when a caller needs to pick a matching material.
    var isDark: Bool {
        colorScheme == .dark
    }
}

/// A typeface the reader can set a book in.
enum ReaderFont: String, CaseIterable, Codable {
    case newYork, sanFrancisco, timesNewRoman, avenirNext, georgia, palatino, charter, iowan

    var name: String {
        switch self {
        case .newYork: return "New York"
        case .sanFrancisco: return "San Francisco"
        case .timesNewRoman: return "Times New Roman"
        case .avenirNext: return "Avenir Next"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .charter: return "Charter"
        case .iowan: return "Iowan Old Style"
        }
    }

    /// PostScript names for the regular and bold faces; nil for the system families.
    private var faces: (regular: String, bold: String)? {
        switch self {
        case .newYork, .sanFrancisco: return nil
        case .timesNewRoman: return ("TimesNewRomanPSMT", "TimesNewRomanPS-BoldMT")
        case .avenirNext: return ("AvenirNext-Regular", "AvenirNext-DemiBold")
        case .georgia: return ("Georgia", "Georgia-Bold")
        case .palatino: return ("Palatino-Roman", "Palatino-Bold")
        case .charter: return ("Charter-Roman", "Charter-Bold")
        case .iowan: return ("IowanOldStyle-Roman", "IowanOldStyle-Bold")
        }
    }

    /// The fonts this device actually has. Apple TV ships far fewer than a Mac — Georgia,
    /// Palatino, Charter and Iowan aren't there — so the menu only offers what will draw.
    static var available: [ReaderFont] {
        allCases.filter { font in
            guard let faces = font.faces else { return true }
            return PlatformFont(name: faces.regular, size: 12) != nil
        }
    }

    func platformFont(size: CGFloat, weight: PlatformFont.Weight, italic: Bool) -> PlatformFont {
        let heavy = weight != .regular && weight != .light
        if let faces, let named = PlatformFont(name: heavy ? faces.bold : faces.regular, size: size) {
            return italic ? named.withItalic() : named
        }
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor
        if self == .newYork, let serif = descriptor.withDesign(.serif) {
            descriptor = serif
        }
        #if os(macOS)
        let font = NSFont(descriptor: descriptor, size: size) ?? base
        #else
        let font = UIFont(descriptor: descriptor, size: size)
        #endif
        return italic ? font.withItalic() : font
    }
}

private extension PlatformFont {
    func withItalic() -> PlatformFont {
        #if os(macOS)
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
        #else
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.traitItalic)) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
        #endif
    }
}

/// Each theme's customizations, as Books keeps them: change Calm's font and Calm keeps
/// it, while every other theme stays as it was. A theme with no entry is as it ships.
struct ThemeStyles: Codable, Equatable {
    var custom: [String: ReadingStyle] = [:]

    init() {}

    init(data: Data?) {
        guard let data else { return }
        if let decoded = try? JSONDecoder().decode(Self.self, from: data) {
            self = decoded
        }
        // Saved before themes kept their own: dropped, so each theme starts as it ships.
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    func style(for theme: BookTheme) -> ReadingStyle {
        custom[theme.styleKey] ?? theme.defaultStyle
    }

    mutating func set(_ style: ReadingStyle, for theme: BookTheme) {
        custom[theme.styleKey] = style == theme.defaultStyle ? nil : style
    }
}

/// How the text is set, beyond its size and colours: Books' Customize settings.
///
/// The paginator and the renderer both read this, so a page is always measured with
/// exactly the type it will be drawn in. The defaults reproduce the reader as it was
/// before these settings existed.
struct ReadingStyle: Codable, Equatable {
    var font: ReaderFont = .newYork
    var boldText = false
    var justified = true
    /// Each spacing is a step on Books' slider, 0 through `steps - 1`.
    var lineSpacing = 2
    var characterSpacing = 0
    var wordSpacing = 0
    var margins = 0

    static let steps = 5

    init() {}

    init(data: Data?) {
        guard let data, let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return }
        self = decoded
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Line spacing for body text: the default step is the reader's long-standing spacing.
    var lineSpacingScale: CGFloat { [0.4, 0.7, 1.0, 1.5, 2.1][clamped(lineSpacing)] }

    func kern(size: CGFloat) -> CGFloat { size * [0, 0.015, 0.03, 0.05, 0.07][clamped(characterSpacing)] }

    /// Extra width given to each space, as a fraction of the type size.
    func wordGap(size: CGFloat) -> CGFloat { size * [0, 0.08, 0.16, 0.26, 0.36][clamped(wordSpacing)] }

    /// Extra margin on each side of the text, on top of the layout's own.
    var extraMargin: CGFloat {
        #if os(tvOS)
        [0, 50, 100, 160, 230][clamped(margins)]
        #else
        [0, 24, 48, 80, 112][clamped(margins)]
        #endif
    }

    func weight(_ requested: PlatformFont.Weight) -> PlatformFont.Weight {
        guard boldText else { return requested }
        return requested == .regular ? .semibold : .bold
    }

    /// Distinguishes measurements made under different settings.
    var cacheKey: String {
        "\(font.rawValue)|\(boldText)|\(justified)|\(lineSpacing)|\(characterSpacing)|\(wordSpacing)"
    }

    private func clamped(_ step: Int) -> Int { min(max(step, 0), Self.steps - 1) }
}
