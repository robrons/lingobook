import Foundation

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Cross-platform clipboard operations
public enum Clipboard {
    /// Copy text to system clipboard
    public static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
    
    /// Get text from system clipboard
    public static func paste() -> String? {
        #if os(iOS)
        return UIPasteboard.general.string
        #else
        return NSPasteboard.general.string(forType: .string)
        #endif
    }
}
