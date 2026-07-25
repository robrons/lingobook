import SwiftUI

/// Theme options for the book reader.
///
/// Preview colours are derived from the real page/text colours rather than hand-picked,
/// so a swatch can never drift from the page it promises.
enum BookTheme: String, CaseIterable {
    case paper, calm, sepia, gray, night

    var name: String {
        rawValue.capitalized
    }

    // Background color for reading
    var pageColor: Color {
        switch self {
        case .paper: return .white
        case .calm: return Color(red: 0.976, green: 0.949, blue: 0.898)
        case .sepia: return Color(red: 0.94, green: 0.89, blue: 0.78)
        case .gray: return Color(red: 0.165, green: 0.165, blue: 0.18)
        case .night: return .black
        }
    }

    // Text color when reading
    var textColor: Color {
        switch self {
        case .paper: return Color(red: 0.1, green: 0.1, blue: 0.1)
        case .calm: return Color(red: 0.25, green: 0.2, blue: 0.15)
        case .sepia: return Color(red: 0.30, green: 0.22, blue: 0.12)
        case .gray: return Color(red: 0.784, green: 0.784, blue: 0.8)
        case .night: return .white
        }
    }

    // Preview swatch colors — taken straight from the theme so they can't disagree with it.
    var previewBgColor: Color { pageColor }
    var previewTextColor: Color { textColor }

    var colorScheme: ColorScheme? {
        switch self {
        case .paper, .calm, .sepia: return .light
        case .gray, .night: return .dark
        }
    }

    /// True for themes whose page is dark, when a caller needs to pick a matching material.
    var isDark: Bool {
        colorScheme == .dark
    }
}
