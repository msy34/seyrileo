import Foundation
import Testing
@testable import SeyrileoKit

@Suite struct XtreamEndpointTests {
    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("  http://Example.COM:8080/  ", "http://example.com:8080"),
        ("https://example.com/base/path/player_api.php?username=a&password=b", "https://example.com/base/path"),
        ("http://example.com:25461/get.php?username=a&password=b&type=m3u_plus", "http://example.com:25461"),
        ("https://example.com/xtream/#frag", "https://example.com/xtream"),
    ])
    func normalizesServerAddress(input: String, expected: String) throws {
        #expect(try XtreamEndpoint(serverAddress: input).baseURL.absoluteString == expected)
    }

    @Test func rejectsInvalidAddresses() {
        #expect(throws: XtreamEndpoint.ValidationError.empty) { try XtreamEndpoint(serverAddress: "   ") }
        #expect(throws: XtreamEndpoint.ValidationError.unsupportedScheme("rtmp")) {
            try XtreamEndpoint(serverAddress: "rtmp://example.com")
        }
        #expect(throws: XtreamEndpoint.ValidationError.containsUserInfo) {
            try XtreamEndpoint(serverAddress: "https://user:pass@example.com")
        }
        #expect(throws: (any Error).self) { try XtreamEndpoint(serverAddress: "https://") }
    }

    @Test func missingSchemeDefaultsToHTTPS() throws {
        #expect(try XtreamEndpoint(serverAddress: "tv.example.org:8080").usesHTTPS)
    }

    @Test func apiQueryEncodesReservedCharacters() throws {
        let endpoint = try XtreamEndpoint(serverAddress: "https://example.com/base")
        let credentials = XtreamCredentials(username: "user name&x=1", password: "p+a/s?s#w%rd=")
        let url = endpoint.apiURL(credentials: credentials, action: "get_live_streams", parameters: [("category_id", "1 2")])
        #expect(url.absoluteString == "https://example.com/base/player_api.php?username=user%20name%26x%3D1&password=p%2Ba%2Fs%3Fs%23w%25rd%3D&action=get_live_streams&category_id=1%202")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "password" }?.value == "p+a/s?s#w%rd=")
        #expect(items.first { $0.name == "username" }?.value == "user name&x=1")
        #expect(url.fragment == nil)
    }

    @Test func streamPathEncodesCredentialsAsSingleSegments() throws {
        let endpoint = try XtreamEndpoint(serverAddress: "http://example.com:8080")
        let credentials = XtreamCredentials(username: "a/b", password: "../x?y#z")
        let url = endpoint.liveStreamURL(credentials: credentials, streamID: "42", format: .hls)
        #expect(url.absoluteString == "http://example.com:8080/live/a%2Fb/..%2Fx%3Fy%23z/42.m3u8")
        #expect(url.query == nil)
        #expect(url.fragment == nil)
        #expect(url.host == "example.com")
    }

    @Test func linkParserSplitsPastedLinks() throws {
        let result = try #require(XtreamLinkParser.parse("http://tv.example.com:8080/get.php?username=bob&password=p%2B1&type=m3u_plus"))
        #expect(result == .init(serverAddress: "http://tv.example.com:8080", username: "bob", password: "p+1"))
        #expect(XtreamLinkParser.parse("https://tv.example.com") == nil)
    }
}
