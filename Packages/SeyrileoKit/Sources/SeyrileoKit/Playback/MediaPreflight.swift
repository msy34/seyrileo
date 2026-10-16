import Foundation

/// A cheap check before opening a movie or episode: reads the first 16 bytes. Some providers
/// answer a missing file with "200 OK" and an empty HTML page; both players then fail with
/// misleading format errors. Only a clear "this is not media" answer blocks playback —
/// errors, timeouts and non-2xx statuses are left to the players and their own messages.
public struct MediaPreflight: Sendable {
    public enum Result: Equatable, Sendable {
        case media
        case notMedia
        case inconclusive
    }

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let fetch: Fetch

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public init(timeout: TimeInterval = 8) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        self.init { request in try await session.data(for: request) }
    }

    public func check(_ url: URL) async -> Result {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        guard let (body, response) = try? await fetch(request), let http = response as? HTTPURLResponse else {
            return .inconclusive
        }
        return Self.classify(status: http.statusCode, body: body)
    }

    static func classify(status: Int, body: Data) -> Result {
        guard (200..<300).contains(status) else { return .inconclusive }
        guard let first = body.first(where: { !Self.whitespace.contains($0) }) else { return .notMedia }  // empty page
        // An HTML or JSON document instead of a file. Media containers never start with these.
        return first == UInt8(ascii: "<") || first == UInt8(ascii: "{") ? .notMedia : .media
    }

    private static let whitespace: Set<UInt8> = [0x20, 0x09, 0x0a, 0x0d]
}
