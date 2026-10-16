import Foundation
import Testing
@testable import SeyrileoKit

/// Optional validation against a real, authorized provider. Never commit credentials:
/// export them in your shell for a single run, e.g.
///   SEYRILEO_XTREAM_URL=… SEYRILEO_XTREAM_USER=… SEYRILEO_XTREAM_PASS=… swift test --filter RealProvider
/// Output only includes counts and redacted descriptions.
enum RealProviderConfiguration {
    static var value: (String, XtreamCredentials)? {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SEYRILEO_XTREAM_URL"], let user = env["SEYRILEO_XTREAM_USER"], let pass = env["SEYRILEO_XTREAM_PASS"]
        else { return nil }
        return (url, XtreamCredentials(username: user, password: pass))
    }
}

@Suite(.enabled(if: RealProviderConfiguration.value != nil, "Set SEYRILEO_XTREAM_URL/USER/PASS to run"))
struct RealProviderTests {
    @Test func authenticatesAndListsLiveCatalogue() async throws {
        let (address, credentials) = try #require(RealProviderConfiguration.value)
        let client = XtreamClient(
            providerID: UUID(), endpoint: try XtreamEndpoint(serverAddress: address), credentials: credentials,
            transport: URLSessionTransport())
        let account = try await client.authenticate()
        print("status=\(account.status) formats=\(account.allowedOutputFormats) max=\(String(describing: account.maxConnections))")
        let categories = try await client.liveCategories()
        print("categories=\(categories.items.count) dropped=\(categories.droppedCount)")
        let first = try #require(categories.items.first)
        let channels = try await client.liveStreams(categoryID: first.remoteID)
        print("channels(first category)=\(channels.items.count) dropped=\(channels.droppedCount)")
        #expect(!categories.items.isEmpty)
    }
}
