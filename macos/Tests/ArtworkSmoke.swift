import AppKit
import Foundation
import ImageIO

final class ArtworkFixtureProtocol: URLProtocol {
    static let png: Data = {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return bitmap.representation(using: .png, properties: [:])!
    }()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "artwork.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        let path = request.url!.path
        let status = path == "/unavailable" ? 503 : 200
        let body = path == "/invalid" ? Data("not an image".utf8) : Self.png
        let length = path == "/too-large" ? ArtworkLoader.maximumBytes + 1 : body.count
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type":"image/png", "Content-Length":"\(length)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ArtworkSmoke {
    static func checkFailure(_ code: String, source: String, configuration: URLSessionConfiguration? = nil) async throws {
        do {
            _ = try await ArtworkLoader.load(source, configuration: configuration)
            preconditionFailure("Unexpectedly accepted \(code) fixture")
        } catch let error as ArtworkError {
            precondition(error.diagnosticCode == code, "\(error.diagnosticCode) != \(code)")
        }
    }
    static func main() async throws {
        let png = ArtworkFixtureProtocol.png
        let inline = "data:image/png;base64," + png.base64EncodedString()
        let image = try await ArtworkLoader.load(inline)
        precondition(image.width == 8 && image.height == 8)
        precondition(ArtworkLoader.kind(of: inline) == "inline")
        let rawImage = try await ArtworkLoader.load(png.base64EncodedString())
        precondition(rawImage.width == 8)
        precondition(ArtworkLoader.kind(of: png.base64EncodedString()) == "raw_base64")
        let quoted = String(data: try JSONSerialization.data(withJSONObject: inline, options: [.fragmentsAllowed]), encoding: .utf8)!
        let quotedImage = try await ArtworkLoader.load(quoted)
        precondition(quotedImage.width == 8)
        precondition(ArtworkLoader.kind(of: "//artwork.test/image") == "https")
        precondition(ArtworkLoader.kind(of: "content://media/external/audio/1") == "phone_content_uri")
        precondition(ArtworkLoader.kind(of: "  ") == "missing")
        try await checkFailure("invalid_inline_data", source: "data:image/png;base64,!")
        try await checkFailure("size_limit", source: "data:image/png;base64," + String(repeating: "A", count: ArtworkLoader.maximumEncodedCharacters + 1))
        for value in ["file:///etc/hosts", "http://user:password@artwork.test/image", "ftp://artwork.test/image"] {
            try await checkFailure("unsupported_source", source: value)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkFixtureProtocol.self]
        for scheme in ["http", "https"] {
            let image = try await ArtworkLoader.load("\(scheme)://artwork.test/image", configuration: config)
            precondition(image.width == 8)
        }
        try await checkFailure("http_503", source: "http://artwork.test/unavailable", configuration: config)
        try await checkFailure("size_limit", source: "http://artwork.test/too-large", configuration: config)
        try await checkFailure("invalid_image", source: "http://artwork.test/invalid", configuration: config)
        precondition(ArtworkError.httpStatus(503).retryable)
        precondition(!ArtworkError.httpStatus(404).retryable)
        if CommandLine.arguments.count > 1 {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            try png.write(to: root.appendingPathComponent("fixture.png"))
        }
        if let base = ProcessInfo.processInfo.environment["ARTWORK_FIXTURE_URL"] {
            let image = try await ArtworkLoader.load(base + "/fixture.png")
            precondition(image.width == 8)
            print("Real HTTP artwork GET with bundled ATS policy: PASS")
        }
        print("Inline PNG, HTTP/HTTPS, missing/invalid/oversized images, error classification: PASS")
    }
}
