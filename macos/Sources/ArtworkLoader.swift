import Foundation
import ImageIO

enum ArtworkError: Error {
    case unsupportedSource, invalidData, tooLarge, httpStatus(Int), invalidImage
    var diagnosticCode: String {
        switch self {
        case .unsupportedSource: return "unsupported_source"
        case .invalidData: return "invalid_inline_data"
        case .tooLarge: return "size_limit"
        case .httpStatus(let status): return "http_\(status)"
        case .invalidImage: return "invalid_image"
        }
    }
    var retryable: Bool {
        if case .httpStatus(let status) = self { return status == 408 || status == 429 || status >= 500 }
        return false
    }
}

private final class ArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(ArtworkLoader.isNetworkURL) == true ? request : nil)
    }
}

enum ArtworkLoader {
    static let maximumBytes = 4_000_000
    static let maximumEncodedCharacters = ((maximumBytes + 2) / 3) * 4
    static func normalized(_ source: String) -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.utf8.count <= maximumEncodedCharacters + 256,
           let data = value.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.hasPrefix("//") { return "https:" + value }
        return value
    }
    static func rawImageData(_ value: String) -> Data? {
        guard value.utf8.count <= maximumEncodedCharacters, value.count >= 16,
              !value.contains(":"), !value.hasPrefix("/") || value.hasPrefix("/9j/") else { return nil }
        let encoded = value.filter { !$0.isWhitespace }
        return Data(base64Encoded: encoded)
    }
    static func kind(of source: String) -> String {
        let value = normalized(source)
        if value.isEmpty { return "missing" }
        if value.lowercased().hasPrefix("data:image/") { return "inline" }
        if let url = URL(string: value), isNetworkURL(url) { return url.scheme!.lowercased() }
        if rawImageData(value) != nil { return "raw_base64" }
        if value.hasPrefix("content:") { return "phone_content_uri" }
        if value.hasPrefix("file:") || value.hasPrefix("/") { return "phone_file_path" }
        if value.hasPrefix("android.resource:") { return "phone_resource_uri" }
        return "unsupported"
    }
    static func isNetworkURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
            url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
    // Runs on the generic executor. Downloads, decoding and retries never run
    // in the audio callback, and images/cookies/credentials are never persisted.
    static func load(_ source: String, configuration: URLSessionConfiguration? = nil) async throws -> CGImage {
        let value = normalized(source)
        guard value.utf8.count <= maximumEncodedCharacters + 256 else { throw ArtworkError.tooLarge }
        let data: Data
        if value.lowercased().hasPrefix("data:image/") {
            guard let comma = value.firstIndex(of: ","),
                  value[..<comma].lowercased().hasSuffix(";base64") else { throw ArtworkError.invalidData }
            let encoded = value[value.index(after: comma)...]
            guard encoded.utf8.count <= maximumEncodedCharacters else { throw ArtworkError.tooLarge }
            guard let decoded = Data(base64Encoded: String(encoded)) else { throw ArtworkError.invalidData }
            data = decoded
        } else if let decoded = rawImageData(value) {
            data = decoded
        } else {
            guard let url = URL(string: value), isNetworkURL(url) else { throw ArtworkError.unsupportedSource }
            let config = configuration ?? .ephemeral
            config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
            let session = URLSession(configuration: config, delegate: ArtworkRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.url.map(isNetworkURL) == true else { throw ArtworkError.unsupportedSource }
            guard response.statusCode == 200 else { throw ArtworkError.httpStatus(response.statusCode) }
            guard response.expectedContentLength <= maximumBytes else { throw ArtworkError.tooLarge }
            var received = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard received.count < maximumBytes else { throw ArtworkError.tooLarge }
                received.append(byte)
            }
            data = received
        }
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw ArtworkError.tooLarge }
        guard let image = decode(data) else { throw ArtworkError.invalidImage }
        return image
    }
    static func decode(_ data: Data) -> CGImage? {
        guard data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
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
