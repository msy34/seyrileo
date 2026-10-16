import Foundation
import Testing
@testable import SeyrileoKit

@Suite struct MediaPreflightTests {
    static let url = URL(string: "http://media.example.com/series/a/b/1.mkv")!

    func preflight(status: Int, body: Data, error: Bool = false, seen: Box? = nil) -> MediaPreflight {
        MediaPreflight { request in
            seen?.range = request.value(forHTTPHeaderField: "Range")
            if error { throw URLError(.timedOut) }
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    final class Box: @unchecked Sendable { var range: String? }

    @Test func matroskaAndMP4AreMedia() async {
        let box = Box()
        #expect(await preflight(status: 206, body: Data([0x1a, 0x45, 0xdf, 0xa3, 1, 0, 0, 0]), seen: box).check(Self.url) == .media)
        #expect(box.range == "bytes=0-15")
        #expect(await preflight(status: 200, body: Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8)).check(Self.url) == .media)
    }

    @Test func emptyOrHTMLPagesAreNotMedia() async {
        // Measured on a real provider: 302 → "200 text/html" with an empty body for a missing file.
        #expect(await preflight(status: 200, body: Data()).check(Self.url) == .notMedia)
        #expect(await preflight(status: 200, body: Data("  \n<html><body>Not found</body>".utf8)).check(Self.url) == .notMedia)
        #expect(await preflight(status: 200, body: Data(#"{"error":"x"}"#.utf8)).check(Self.url) == .notMedia)
    }

    @Test func errorsAndOtherStatusesAreLeftToThePlayer() async {
        #expect(await preflight(status: 404, body: Data()).check(Self.url) == .inconclusive)
        #expect(await preflight(status: 403, body: Data("<html>".utf8)).check(Self.url) == .inconclusive)
        #expect(await preflight(status: 200, body: Data(), error: true).check(Self.url) == .inconclusive)
    }
}
