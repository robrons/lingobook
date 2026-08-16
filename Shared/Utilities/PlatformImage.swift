import Foundation

import AppKit
public typealias PlatformImage = NSImage

/// Image handling
public extension PlatformImage {
    /// Create image from data
    static func from(data: Data) -> PlatformImage? {
        return NSImage(data: data)
    }
}
