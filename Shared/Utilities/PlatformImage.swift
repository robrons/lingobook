import Foundation

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

/// Image handling
public extension PlatformImage {
    /// Create image from data
    static func from(data: Data) -> PlatformImage? {
        return PlatformImage(data: data)
    }
}
