import Foundation
import Testing
@testable import SeyrileoKit

@Suite struct RedactorTests {
    static let credentials = XtreamCredentials(username: "bob smith", password: "p@ss/w#rd?&+%")

    @Test func redactsCredentialBearingStreamPathNotJustQuery() throws {
        let endpoint = try XtreamEndpoint(serverAddress: "http://tv.example.com:8080")
        let url = endpoint.liveStreamURL(credentials: Self.credentials, streamID: "7", format: .mpegts)
        let redacted = Redactor(secrets: Self.credentials.secrets).redact("Failed to load \(url.absoluteString) after 3 tries")
        #expect(redacted == "Failed to load http://tv.example.com:8080/[redacted] after 3 tries")
    }

    @Test func redactsAPIURLsAndRawSecretsInAnyEncoding() throws {
        let endpoint = try XtreamEndpoint(serverAddress: "https://tv.example.com")
        let api = endpoint.apiURL(credentials: Self.credentials, action: "get_live_streams")
        let redactor = Redactor(secrets: Self.credentials.secrets)
        let text = """
            url=\(api.absoluteString) raw=\(Self.credentials.password) \
            pct=\(XtreamEndpoint.encode(Self.credentials.password)) plus=bob+smith user=Bob Smith
            """
        let output = redactor.redact(text)
        for secret in [Self.credentials.password, XtreamEndpoint.encode(Self.credentials.password), "bob smith", "bob+smith", "Bob Smith", "w#rd"] {
            #expect(!output.contains(secret), "leaked \(secret)")
        }
        #expect(output.contains("https://tv.example.com/[redacted]"))
    }

    @Test func redactionIsIdempotent() throws {
        let redactor = Redactor(secrets: Self.credentials.secrets)
        let once = redactor.redact("Play X — http://tv.example.com:8080/live/a/b/1.m3u8 (and https://h.example/x?y=1)")
        #expect(once == "Play X — http://tv.example.com:8080/[redacted] (and https://h.example/[redacted])")
        #expect(redactor.redact(once) == once)
        #expect(redactor.redact(redactor.redact(once)) == once)
    }

    @Test func describeKeepsOnlyOrigin() throws {
        let url = try #require(URL(string: "https://u:p@host.example:99/live/u/p/1.ts?token=abc#f"))
        #expect(Redactor.describe(url) == "https://host.example:99/[redacted]")
        #expect(Redactor.describe(URL(string: "https://host.example")!) == "https://host.example")
    }

    @Test func sanitizedErrorDropsUserInfoURLs() throws {
        let failing = "http://tv.example.com/live/bob/secret-pass/1.m3u8"
        let underlying = NSError(domain: "CoreMediaErrorDomain", code: -12938, userInfo: [NSURLErrorFailingURLStringErrorKey: failing])
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSLocalizedDescriptionKey: "The request timed out. (\(failing))",
            NSURLErrorFailingURLStringErrorKey: failing,
            NSUnderlyingErrorKey: underlying,
        ])
        let sanitized = SanitizedError(error, redactor: Redactor(secrets: ["bob", "secret-pass"]))
        #expect(!sanitized.description.contains("secret-pass"))
        #expect(!sanitized.description.contains("/live/"))
        #expect(sanitized.identifier == "NSURLErrorDomain#-1001")
        #expect(sanitized.underlying == ["CoreMediaErrorDomain#-12938"])
    }

    @Test func credentialsNeverPrint() {
        let text = "\(Self.credentials) \(String(reflecting: Self.credentials)) \(String(describing: [Self.credentials]))"
        #expect(!text.contains("p@ss"))
        #expect(!text.contains("bob"))
        var dumped = ""
        dump(Self.credentials, to: &dumped)
        #expect(!dumped.contains("p@ss"))
    }

    @Test func playbackItemDescriptionIsRedacted() throws {
        let endpoint = try XtreamEndpoint(serverAddress: "http://tv.example.com")
        let url = endpoint.liveStreamURL(credentials: Self.credentials, streamID: "1", format: .hls)
        let item = PlaybackItem(
            id: MediaKey(providerID: UUID(), kind: .live, remoteID: "1"), title: "One", sourceName: "S", url: url,
            isLive: true, redactor: Redactor(secrets: Self.credentials.secrets))
        #expect(!"\(item)".contains("p%40ss"))
        #expect(!"\(item)".contains("bob"))
    }
}
