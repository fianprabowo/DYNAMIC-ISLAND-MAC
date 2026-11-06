import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Turns a picture picked for a chat into a JPEG small enough for the poke-images bucket. It's
/// scaled down and saved again, which also leaves out its metadata, like where a photo was taken.
nonisolated enum PokeImage {
    /// Below the bucket's 5 MB limit (5,242,880 bytes).
    static let maxBytes = 5_000_000
    /// Longest side, in pixels.
    private static let maxPixels = 3072
    /// Bigger files aren't read at all.
    private static let maxFileBytes = 50_000_000

    enum Problem: Error, LocalizedError {
        case unreadable, tooBig

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file isn't a picture"
            case .tooBig: "That picture is too big"
            }
        }
    }

    static func jpeg(from url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else { throw Problem.tooBig }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Problem.unreadable }
        return try jpeg(from: source)
    }

    static func jpeg(from data: Data) throws -> Data {
        guard data.count <= maxFileBytes else { throw Problem.tooBig }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Problem.unreadable }
        return try jpeg(from: source)
    }

    private static func jpeg(from source: CGImageSource) throws -> Data {
        var pixels = maxPixels
        while pixels >= 400 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw Problem.unreadable
            }
            for quality in [0.85, 0.7, 0.55, 0.4] {
                if let data = encode(image, quality: quality), data.count <= maxBytes {
                    return data
                }
            }
            pixels = pixels * 3 / 4
        }
        throw Problem.tooBig
    }

    /// A small copy to show in the chat: drawing the full picture there, scaled down on every frame
    /// of the notch opening, makes it stutter.
    static func thumbnail(from data: Data, maxPixels: Int = 360) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The thumbnail at half its pixels in points, sharp on a Retina screen.
    @MainActor static func image(_ thumbnail: CGImage) -> NSImage {
        NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width / 2, height: thumbnail.height / 2))
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
