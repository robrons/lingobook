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

/// Whether an image is a single flat colour — some EPUBs ship a blank white page as their
/// "cover". Books shows its own titled cover then, rather than an empty white card.
public extension PlatformImage {
    var isNearlyBlank: Bool {
        #if os(macOS)
        guard let image = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        #else
        guard let image = cgImage else { return false }
        #endif

        // Shrunk to 8×8, a real cover still has light and dark in it; a blank one doesn't.
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var lowest = 255, highest = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let brightness = (Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])) / 3
            lowest = min(lowest, brightness)
            highest = max(highest, brightness)
        }
        return highest - lowest < 12
    }
}
