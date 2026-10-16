import Foundation
import Testing
@testable import SeyrileoKit

@Suite struct XtreamClientTests {
    @Test func parsesActiveAccountAndIgnoresServerInfoHost() async throws {
        let transport = StubTransport.body(try TestFixtures.data("auth-active.json"))
        let client = try XtreamClient.stub(transport)
        let info = try await client.authenticate()
        #expect(info.status == .active)
        #expect(info.expiresAt == Date(timeIntervalSince1970: 1_924_992_000))
        #expect(info.activeConnections == 1)
        #expect(info.maxConnections == 2)
        #expect(info.isTrial == false)
        #expect(info.allowedOutputFormats == ["m3u8", "ts", "rtmp"])
        #expect(info.serverTimezone == "Europe/Istanbul")
        #expect(info.preferredLiveFormat == .hls)
        // Requests go to the user-entered host only, never to server_info.url.
        #expect(transport.requests.allSatisfy { $0.host == "provider.example" })
        #expect(client.liveStreamURL(for: Self.channel("5", client), format: .hls).host == "provider.example")
    }

    @Test func toleratesTypeVariantsAndTreatsMissingAsUnknown() async throws {
        let client = try XtreamClient.stub(StubTransport.body(try TestFixtures.data("auth-variant-types.json")))
        let info = try await client.authenticate()
        #expect(info.status == .expired)
        #expect(info.status.blocksPlayback)
        #expect(info.expiresAt == nil)
        #expect(info.maxConnections == nil)
        #expect(info.activeConnections == 0)
        #expect(info.isTrial == false)
        #expect(info.allowedOutputFormats.isEmpty)
        #expect(info.preferredLiveFormat == .hls)
    }

    @Test(arguments: [
        #"{"user_info":{"auth":0}}"#,
        #"{"user_info":{"auth":"0","status":"Active"}}"#,
    ])
    func rejectedCredentials(json: String) async throws {
        let client = try XtreamClient.stub(StubTransport.json(json))
        await #expect(throws: XtreamError.authenticationRejected) { try await client.authenticate() }
    }

    @Test func unknownStatusIsKeptRaw() async throws {
        let client = try XtreamClient.stub(StubTransport.json(#"{"user_info":{"auth":1,"status":"Paused"}}"#))
        #expect(try await client.authenticate().status == .unknown("Paused"))
    }

    @Test func tsOnlyProviderPrefersTS() {
        #expect(AccountInfo(status: .active, allowedOutputFormats: ["TS"]).preferredLiveFormat == .mpegts)
    }

    @Test func htmlBodyIsReportedNotSwallowed() async throws {
        let html = try TestFixtures.data("html-error.html")
        let client = try XtreamClient.stub(StubTransport.body(html, contentType: "text/html"))
        await #expect(throws: XtreamError.htmlInsteadOfJSON) { try await client.authenticate() }
        // Even when mislabeled as JSON.
        let mislabeled = try XtreamClient.stub(StubTransport.body(html, contentType: "application/json"))
        await #expect(throws: XtreamError.htmlInsteadOfJSON) { try await mislabeled.liveCategories() }
    }

    @Test func malformedEmptyAndUnexpectedBodies() async throws {
        await #expect(throws: XtreamError.malformedJSON) {
            try await XtreamClient.stub(StubTransport.json(#"[{"category_id":"1""#)).liveCategories()
        }
        await #expect(throws: XtreamError.emptyResponse) {
            try await XtreamClient.stub(StubTransport.json("  \n")).liveStreams()
        }
        await #expect(throws: XtreamError.unexpectedShape("expected list")) {
            try await XtreamClient.stub(StubTransport.json(#"{"error":"nope"}"#)).liveStreams()
        }
        await #expect(throws: XtreamError.unexpectedShape("auth: missing user_info")) {
            try await XtreamClient.stub(StubTransport.json(#"{"server_info":{}}"#)).authenticate()
        }
        await #expect(throws: XtreamError.unexpectedShape("auth: expected object")) {
            try await XtreamClient.stub(StubTransport.json("[]")).authenticate()
        }
    }

    @Test(arguments: ["{}", "null", "false", "[]"])
    func emptyListVariants(body: String) async throws {
        let page = try await XtreamClient.stub(StubTransport.json(body)).liveStreams()
        #expect(page.items.isEmpty)
        #expect(page.droppedCount == 0)
    }

    @Test func non2xxIsAnHTTPStatusError() async throws {
        for status in [401, 403, 404, 500] {
            let client = try XtreamClient.stub(StubTransport.json(#"{"user_info":{"auth":1}}"#, status: status))
            await #expect(throws: XtreamError.httpStatus(status)) { try await client.authenticate() }
        }
    }

    @Test func lossyStreamDecodingKeepsGoodEntriesAndCountsBadOnes() async throws {
        let client = try XtreamClient.stub(StubTransport.body(try TestFixtures.data("live-streams-mixed.json")))
        let page = try await client.liveStreams(categoryID: "3")
        #expect(page.items.map(\.key.remoteID) == ["11", "12", "13", "14"])
        #expect(page.droppedCount == 2)
        let first = page.items[0]
        #expect(first.number == 1)
        #expect(first.epgChannelID == "one.tr")
        #expect(first.advertisesArchive)
        #expect(first.iconURL?.host == "img.invalid")
        let second = page.items[1]
        #expect(second.name == "Çağrı Ğüşİö")
        #expect(second.number == 2)
        #expect(second.epgChannelID == nil)
        #expect(second.iconURL == nil)
        #expect(second.categoryIDs == ["3"])
        #expect(page.items[2].name == "")
        #expect(page.items[3].categoryIDs == ["3", "7"])
        #expect(page.items[3].advertisesArchive)
        #expect(page.items.allSatisfy { $0.key.kind == .live && $0.key.providerID == client.providerID })
    }

    @Test func categoriesDropEntriesWithoutID() async throws {
        let json = #"[{"category_id":1,"category_name":" Spor "},{"category_name":"x"},{"category_id":"","category_name":"y"}]"#
        let page = try await XtreamClient.stub(StubTransport.json(json)).liveCategories()
        #expect(page.items.map(\.remoteID) == ["1"])
        #expect(page.items.first?.name == "Spor")
        #expect(page.droppedCount == 2)
    }

    @Test func categoryQueryIsSent() async throws {
        let transport = StubTransport.json("[]")
        _ = try await XtreamClient.stub(transport).liveStreams(categoryID: "7")
        let url = try #require(transport.requests.first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "action", value: "get_live_streams")))
        #expect(items.contains(URLQueryItem(name: "category_id", value: "7")))
        #expect(url.path == "/base/player_api.php")
    }

    @Test func listProbeCountsObjectsOnly() async throws {
        let transport = StubTransport.json(#"[{"stream_id":1},{"name":"x"},"bad",[],{}]"#)
        let probe = try await XtreamClient.stub(transport).probeList(action: "get_vod_streams")
        #expect(probe.itemCount == 3)
        #expect(probe.droppedCount == 2)
        let items = URLComponents(url: try #require(transport.requests.first), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "action", value: "get_vod_streams")))
        #expect(try await XtreamClient.stub(StubTransport.json("{}")).probeList(action: "get_series").itemCount == 0)
    }

    static func channel(_ id: String, _ client: XtreamClient) -> LiveChannel {
        LiveChannel(
            key: MediaKey(providerID: client.providerID, kind: .live, remoteID: id), name: "", number: nil,
            categoryIDs: [], iconURL: nil, epgChannelID: nil, advertisesArchive: false)
    }
}

@Suite struct RetryTests {
    static let ok = HTTPResponse(statusCode: 200, contentType: "application/json", body: Data("[]".utf8))

    @Test func transientFailuresRetryWithBoundedBackoff() async throws {
        let transport = StubTransport([.failure(.transport(.timedOut)), .success(HTTPResponse(statusCode: 503, contentType: nil, body: Data())), .success(Self.ok)])
        let sleeper = RecordingSleeper()
        let client = try XtreamClient.stub(transport, retry: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(100), maxDelay: .seconds(1)), sleeper: sleeper.sleeper)
        _ = try await client.liveCategories()
        #expect(transport.requestCount == 3)
        #expect(sleeper.recorded == [.milliseconds(100), .milliseconds(200)])
    }

    @Test func givesUpAfterMaxAttempts() async throws {
        let transport = StubTransport([.failure(.transport(.connectionLost))])
        let sleeper = RecordingSleeper()
        let client = try XtreamClient.stub(transport, retry: RetryPolicy(maxAttempts: 3), sleeper: sleeper.sleeper)
        await #expect(throws: XtreamError.transport(.connectionLost)) { try await client.liveCategories() }
        #expect(transport.requestCount == 3)
        #expect(sleeper.recorded.count == 2)
    }

    @Test(arguments: [
        XtreamError.transport(.offline), .transport(.insecureHTTPBlocked), .transport(.tlsFailure), .httpStatus(401),
        .httpStatus(403), .httpStatus(404), .unsafeRedirectBlocked, .cancelled,
    ])
    func nonTransientFailuresAreNotRetried(error: XtreamError) async throws {
        let transport = StubTransport([.failure(error)])
        let client = try XtreamClient.stub(transport, retry: RetryPolicy(maxAttempts: 5))
        await #expect(throws: error) { try await client.liveCategories() }
        #expect(transport.requestCount == 1)
    }

    @Test func rejectedCredentialsAreNeverRetried() async throws {
        let transport = StubTransport.json(#"{"user_info":{"auth":0}}"#)
        let client = try XtreamClient.stub(transport, retry: RetryPolicy(maxAttempts: 5))
        await #expect(throws: XtreamError.authenticationRejected) { try await client.authenticate() }
        #expect(transport.requestCount == 1)
    }

    @Test func cancellationDuringBackoffStopsRetrying() async throws {
        let transport = StubTransport([.failure(.transport(.timedOut))])
        let client = try XtreamClient.stub(
            transport, retry: RetryPolicy(maxAttempts: 10),
            sleeper: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await client.liveCategories() }
        #expect(transport.requestCount == 1)
    }

    @Test func delayIsCapped() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: .seconds(1), maxDelay: .seconds(4))
        #expect((1...6).map(policy.delay(beforeRetry:)) == [.seconds(1), .seconds(2), .seconds(4), .seconds(4), .seconds(4), .seconds(4)])
    }
}
