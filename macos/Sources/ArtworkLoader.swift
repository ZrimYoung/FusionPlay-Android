import Foundation
import ImageIO

enum ArtworkLoader {
    // This non-actor async function performs downloading and decoding away
    // from the UI executor. Nothing is persisted outside the project.
    static func load(_ url: URL) async throws -> CGImage? {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.expectedContentLength <= 4_000_000 else { return nil }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4_000_000 else { return nil }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 40_000_000 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 800,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }
}
