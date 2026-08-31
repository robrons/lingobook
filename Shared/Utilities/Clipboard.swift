import Foundation

import AppKit

/// Clipboard operations
public enum Clipboard {
    /// Copy text to system clipboard
    public static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    /// Get text from system clipboard
    public static func paste() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }
}
