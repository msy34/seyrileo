import Foundation
import Testing
@testable import SeyrileoFixtureServer
@testable import SeyrileoKit

/// End-to-end over real loopback HTTP: URLSessionTransport + XtreamClient + FixtureServer.
@Suite(.serialized) struct FixtureServerIntegrationTests {
    static let credentials = XtreamCredentials(username: FixtureServer.username, password: FixtureServer.password)

    func withServer(_ body: (FixtureServer, URL) async throws -> Void) async throws {
        let server = try FixtureServer(port: 0)
        try await server.start()
        defer { server.stop() }
        try await body(server, try #require(server.baseURL))
    }

    func client(_ base: URL, credentials: XtreamCredentials = credentials) throws -> XtreamClient {
        XtreamClient(
            providerID: UUID(), endpoint: try XtreamEndpoint(baseURL: base), credentials: credentials,
            transport: URLSessionTransport(requestTimeout: 5), retryPolicy: .none)
    }

    @Test func fullLiveFlowWithReservedCharacterPassword() async throws {
        try await withServer { _, base in
            let client = try client(base)
            let account = try await client.authenticate()
            #expect(account.status == .active)
            #expect(account.maxConnections == 1)
            #expect(account.preferredLiveFormat == .hls)

            let categories = try await client.liveCategories()
            #expect(categories.items.map(\.remoteID) == ["1", "2"])
            #expect(categories.droppedCount == 1)

            let pattern = try await client.liveStreams(categoryID: "1")
            #expect(pattern.items.map(\.key.remoteID) == ["101", "102"])
            let diagnostics = try await client.liveStreams(categoryID: "2")
            #expect(diagnostics.droppedCount == 1)

            // The credential-bearing stream URL round-trips through real HTTP parsing.
            let url = client.liveStreamURL(for: pattern.items[0], format: .hls)
            #expect(!url.absoluteString.contains(" "))
            let response = try await URLSessionTransport().get(url, maxBytes: 1 << 20)
            #expect(response.statusCode == 200)
            let playlist = String(decoding: response.body, as: UTF8.self)
            #expect(playlist.hasPrefix("#EXTM3U"))
            #expect(!playlist.contains("#EXT-X-ENDLIST"))

            let segmentPath = try #require(playlist.split(separator: "\n").first { $0.hasPrefix("/fixture-media/") })
            let segment = try await URLSessionTransport().get(URL(string: base.absoluteString + segmentPath)!, maxBytes: 1 << 20)
            #expect(segment.statusCode == 200)
            #expect(segment.body.first == 0x47)  // MPEG-TS sync byte
        }
    }

    @Test func wrongPasswordIsRejectedNotRetried() async throws {
        try await withServer { _, base in
            let client = try client(base, credentials: XtreamCredentials(username: FixtureServer.username, password: "wrong"))
            await #expect(throws: XtreamError.authenticationRejected) { try await client.authenticate() }
        }
    }

    @Test func expiredAccountIsReportedAsAdvisoryState() async throws {
        try await withServer { _, base in
            let client = try client(base, credentials: XtreamCredentials(username: FixtureServer.expiredUsername, password: FixtureServer.password))
            let account = try await client.authenticate()
            #expect(account.status == .expired)
            #expect(account.status.blocksPlayback)
        }
    }

    @Test func failureScenariosReturnRealHTTPStatuses() async throws {
        try await withServer { _, base in
            let endpoint = try XtreamEndpoint(baseURL: base)
            let transport = URLSessionTransport()
            for (channel, status) in [(FixtureServer.Channel.offline, 404), (.forbidden, 403)] {
                let url = endpoint.liveStreamURL(credentials: Self.credentials, streamID: channel.rawValue, format: .hls)
                #expect(try await transport.get(url, maxBytes: 1 << 20).statusCode == status)
            }
            let ts = endpoint.liveStreamURL(credentials: Self.credentials, streamID: FixtureServer.Channel.mpegTSOnly.rawValue, format: .hls)
            let response = try await transport.get(ts, maxBytes: 8 << 20)
            #expect(response.contentType == "video/mp2t")
            #expect(response.body.count > 0)
        }
    }

    @Test func responseSizeCapIsEnforced() async throws {
        try await withServer { _, base in
            let endpoint = try XtreamEndpoint(baseURL: base)
            let url = endpoint.liveStreamURL(credentials: Self.credentials, streamID: FixtureServer.Channel.mpegTSOnly.rawValue, format: .mpegts)
            await #expect(throws: XtreamError.responseTooLarge(limitBytes: 1024)) {
                try await URLSessionTransport().get(url, maxBytes: 1024)
            }
        }
    }

    @Test func unreachableHostIsTransportFailure() async throws {
        let server = try FixtureServer(port: 0)
        let port = try await server.start()
        server.stop()
        let client = try client(URL(string: "http://localhost:\(port)")!)
        await #expect(throws: XtreamError.transport(.cannotConnect)) { try await client.authenticate() }
    }
}

@Suite struct FixturePlaylistTests {
    let durations = [2.0, 2.0, 2.0, 2.0, 2.0]

    @Test func slidingWindowAdvancesWithTime() {
        let early = FixtureMedia.livePlaylist(durations: durations, directory: "d", time: 7)
        #expect(early.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        #expect(early.contains("/fixture-media/d/seg3.ts"))
        #expect(!early.contains("seg4.ts"))
        #expect(!early.contains("#EXT-X-ENDLIST"))
        let later = FixtureMedia.livePlaylist(durations: durations, directory: "d", time: 9)
        #expect(later.contains("#EXT-X-MEDIA-SEQUENCE:1"))
    }

    @Test func loopBoundaryInsertsDiscontinuityAndCountsSequence() throws {
        // time 23s → latest absolute segment 11 (loop 2, index 1), window 8...11.
        let playlist = FixtureMedia.livePlaylist(durations: durations, directory: "d", time: 23)
        #expect(playlist.contains("#EXT-X-MEDIA-SEQUENCE:8"))
        #expect(playlist.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1"))
        let lines = playlist.split(separator: "\n").map(String.init)
        let discontinuity = try #require(lines.firstIndex(of: "#EXT-X-DISCONTINUITY"))
        #expect(lines[discontinuity + 2] == "/fixture-media/d/seg0.ts")
    }

    @Test func byteRanges() {
        #expect(FixtureServer.parseRange("bytes=0-1", length: 10) == 0...1)
        #expect(FixtureServer.parseRange("bytes=5-", length: 10) == 5...9)
        #expect(FixtureServer.parseRange("bytes=-3", length: 10) == 7...9)
        #expect(FixtureServer.parseRange("bytes=8-100", length: 10) == 8...9)
        #expect(FixtureServer.parseRange("bytes=10-", length: 10) == nil)
        #expect(FixtureServer.parseRange("bytes=0-1,4-5", length: 10) == nil)
    }

    @Test func queryParsingUsesPHPSemantics() {
        let parsed = FixtureServer.parseQuery("username=a+b&password=p%2Bq%26r&action=x")
        #expect(parsed == ["username": "a b", "password": "p+q&r", "action": "x"])
    }
}
