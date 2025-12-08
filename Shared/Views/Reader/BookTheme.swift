import SwiftUI

/// Theme options for the book reader (Apple Books inspired)
enum BookTheme: String, CaseIterable {
    case original, quiet, paper, bold, calm, focus
    
    var name: String {
        rawValue.capitalized
    }
    
    // Background color for reading
    var pageColor: Color {
        switch self {
        case .original: return .white
        case .quiet: return Color(red: 0.29, green: 0.29, blue: 0.30)
        case .paper: return Color(red: 0.91, green: 0.89, blue: 0.85)
        case .bold: return .white
        case .calm: return Color(red: 0.976, green: 0.949, blue: 0.898)
        case .focus: return .white
        }
    }
    
    // Text color when reading
    var textColor: Color {
        switch self {
        case .original: return .black
        case .quiet: return .white
        case .paper: return Color(red: 0.2, green: 0.2, blue: 0.2)
        case .bold: return .black
        case .calm: return Color(red: 0.25, green: 0.2, blue: 0.15)
        case .focus: return .black
        }
    }
    
    // Preview button background color
    var previewBgColor: Color {
        switch self {
        case .original: return .white
        case .quiet: return Color(red: 0.29, green: 0.29, blue: 0.30)
        case .paper: return Color(red: 0.87, green: 0.85, blue: 0.82)
        case .bold: return .white
        case .calm: return Color(red: 0.976, green: 0.937, blue: 0.867)
        case .focus: return .white
        }
    }
    
    // Preview button text color
    var previewTextColor: Color {
        switch self {
        case .original: return .black
        case .quiet: return .white
        case .paper: return .black
        case .bold: return .black
        case .calm: return .black
        case .focus: return .black
        }
    }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .original, .paper, .bold, .calm, .focus: return .light
        case .quiet: return .dark
        }
    }
}
