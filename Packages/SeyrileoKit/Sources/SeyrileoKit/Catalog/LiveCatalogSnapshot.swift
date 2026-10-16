import Foundation

/// Everything a live-catalogue refresh downloads before anything is written locally.
public struct LiveCatalogSnapshot: Sendable {
    public let account: AccountInfo
    public let categories: CatalogPage<LiveCategory>
    public let channels: CatalogPage<LiveChannel>

    public init(account: AccountInfo, categories: CatalogPage<LiveCategory>, channels: CatalogPage<LiveChannel>) {
        self.account = account
        self.categories = categories
        self.channels = channels
    }
}

extension XtreamClient {
    /// Three requests in sequence: auth, categories, all live streams. One full stream list is
    /// lighter on the provider than one request per category.
    public func fetchLiveSnapshot() async throws -> LiveCatalogSnapshot {
        let account = try await authenticate()
        try Task.checkCancellation()
        let categories = try await liveCategories()
        try Task.checkCancellation()
        let channels = try await liveStreams()
        return LiveCatalogSnapshot(account: account, categories: categories, channels: channels)
    }
}
