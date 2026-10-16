import Foundation
import GRDB
import Testing
@testable import SeyrileoKit

@Suite struct OrganizationTests {
    let bed: TestBed
    let organization: OrganizationStore
    let source: ProviderSource

    init() throws {
        bed = try TestBed()
        organization = OrganizationStore(database: bed.database)
        source = try bed.addSource()
    }

    func load(_ channels: [(id: String, name: String, categories: [String])] = CatalogFixtures.standard) async throws {
        try await bed.catalog.refresh(sourceID: source.id) { CatalogFixtures.snapshot(source.id, channels: channels) }
    }

    func key(_ id: String) -> MediaKey { MediaKey(providerID: source.id, kind: .live, remoteID: id) }

    func names(_ category: String = "1", includeHidden: Bool = false) async throws -> [String] {
        try await bed.catalog.channels(sourceID: source.id, categoryID: category, includeHidden: includeHidden).map(\.displayName)
    }

    @Test func aliasKeepsProviderNameAndIsSearchable() async throws {
        try await load()
        try await organization.setAlias("  Babamın Kanalı ", for: key("10"))
        let channel = try #require(try await bed.catalog.channel(key("10")))
        #expect(channel.displayName == "Babamın Kanalı")
        #expect(channel.name == "|TR| TRT 1 HD")
        // Both the alias (Turkish-insensitive) and the provider name find it.
        #expect(try await bed.catalog.search(sourceID: source.id, query: "babamin").channels.map(\.key) == [key("10")])
        #expect(try await bed.catalog.search(sourceID: source.id, query: "trt").channels.map(\.key) == [key("10")])
        // Clearing restores the provider name and removes the alias from search.
        try await organization.setAlias("   ", for: key("10"))
        #expect(try await bed.catalog.channel(key("10"))?.displayName == "|TR| TRT 1 HD")
        #expect(try await bed.catalog.search(sourceID: source.id, query: "babamin").channels.isEmpty)
        #expect(try await bed.database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM channelOverride") } == 0)
    }

    @Test func aliasIsValidated() async throws {
        await #expect(throws: OrganizationError.nameTooLong) {
            try await organization.setAlias(String(repeating: "x", count: OrganizationStore.maxNameLength + 1), for: key("10"))
        }
    }

    @Test func hiddenChannelsLeaveListsSearchAndGuideButCanBeRestored() async throws {
        try await load()
        try await organization.setHidden(true, channel: key("11"))
        #expect(try await names() == ["|TR| TRT 1 HD", "İZMİR TV", "Beın Haber"])
        #expect(try await names(includeHidden: true).count == 4)
        #expect(try await bed.catalog.search(sourceID: source.id, query: "cagri").channels.isEmpty)
        #expect(try await bed.catalog.hiddenChannels(sourceID: source.id).map(\.key) == [key("11")])
        #expect(try await bed.catalog.channel(key("11"))?.isHidden == true)
        try await organization.setHidden(false, channel: key("11"))
        #expect(try await names().count == 4)
        #expect(try await bed.catalog.hiddenChannels(sourceID: source.id).isEmpty)
    }

    @Test func personalOrderSurvivesRefreshAndNewChannelsGoLast() async throws {
        try await load()
        try await organization.setChannelOrder(sourceID: source.id, categoryID: "1", orderedRemoteIDs: ["21", "12", "10", "11"])
        try await organization.setAlias("Haber", for: key("21"))
        try await organization.setHidden(true, channel: key("12"))
        // A refresh replaces every channel row; personal data is keyed by provider ID.
        try await load(CatalogFixtures.standard + [("13", "Yeni Kanal", ["1"])])
        #expect(try await names() == ["Haber", "|TR| TRT 1 HD", "|TR| Çağrı TV", "Yeni Kanal"])
        #expect(try await organization.hasCustomChannelOrder(sourceID: source.id, categoryID: "1"))
        try await organization.resetChannelOrder(sourceID: source.id, categoryID: "1")
        #expect(try await names() == ["|TR| TRT 1 HD", "|TR| Çağrı TV", "Haber", "Yeni Kanal"])
    }

    @Test func categoriesCanBeHiddenAndReordered() async throws {
        try await load()
        try await organization.setCategoryOrder(sourceID: source.id, orderedRemoteIDs: ["2", "1"])
        #expect(try await bed.catalog.categories(sourceID: source.id).map(\.id) == ["2", "1"])
        try await organization.setHidden(true, categoryID: "2", sourceID: source.id)
        #expect(try await bed.catalog.categories(sourceID: source.id).map(\.id) == ["1"])
        let all = try await bed.catalog.categories(sourceID: source.id, includeHidden: true)
        #expect(all.map(\.id) == ["2", "1"])
        #expect(all.first?.category.isHidden == true)
        try await organization.setHidden(false, categoryID: "2", sourceID: source.id)
        try await organization.resetCategoryOrder(sourceID: source.id)
        #expect(try await bed.catalog.categories(sourceID: source.id).map(\.id) == ["1", "2"])
    }

    @Test func collectionsHoldOrderedItemsAndKeepUnavailableOnes() async throws {
        try await load()
        let sports = try await organization.createCollection(named: " Akşam Spor ", sourceID: source.id)
        #expect(sports.name == "Akşam Spor")
        try await organization.add(key("20"), title: "BEIN SPORTS 1", to: sports.id)
        try await organization.add(key("22"), title: "ışık fm", to: sports.id)
        try await organization.add(key("20"), title: "BEIN SPORTS 1", to: sports.id)  // no duplicate
        try await organization.reorderItems(in: sports.id, orderedKeys: [key("22"), key("20")])
        #expect(try await organization.items(in: sports.id).map(\.key) == [key("22"), key("20")])
        #expect(try await organization.collectionIDs(containing: key("20")) == [sports.id])
        #expect(try await organization.collections(sourceID: source.id).first?.itemCount == 2)

        // The provider drops channel 22: the item stays, marked unavailable, with its saved title.
        try await load(CatalogFixtures.standard.filter { $0.id != "22" })
        let items = try await organization.items(in: sports.id)
        #expect(items.map(\.isAvailable) == [false, true])
        #expect(items.first?.title == "ışık fm")

        try await organization.remove(key("22"), from: sports.id)
        #expect(try await organization.items(in: sports.id).count == 1)
    }

    @Test func collectionNamesAndOwnershipAreChecked() async throws {
        await #expect(throws: OrganizationError.emptyName) {
            try await organization.createCollection(named: "   ", sourceID: source.id)
        }
        let first = try await organization.createCollection(named: "A", sourceID: source.id)
        let second = try await organization.createCollection(named: "B", sourceID: source.id)
        try await organization.reorderCollections(sourceID: source.id, orderedIDs: [second.id, first.id])
        try await organization.renameCollection(first.id, to: "Çocuklar")
        #expect(try await organization.collections(sourceID: source.id).map(\.name) == ["B", "Çocuklar"])
        // An item of another source can't be added.
        let other = MediaKey(providerID: UUID(), kind: .live, remoteID: "10")
        await #expect(throws: OrganizationError.collectionNotFound) {
            try await organization.add(other, title: "x", to: first.id)
        }
        try await organization.deleteCollection(second.id)
        #expect(try await organization.collections(sourceID: source.id).map(\.id) == [first.id])
    }

    @Test func removingTheSourceRemovesAllPersonalData() async throws {
        try await load()
        try await organization.setAlias("Takma", for: key("10"))
        try await organization.setHidden(true, channel: key("11"))
        try await organization.setChannelOrder(sourceID: source.id, categoryID: "1", orderedRemoteIDs: ["11", "10"])
        try await organization.setHidden(true, categoryID: "2", sourceID: source.id)
        let collection = try await organization.createCollection(named: "X", sourceID: source.id)
        try await organization.add(key("10"), title: "T", to: collection.id)

        try bed.sources.saveSources([])
        let leftovers = try await bed.database.writer.read { db in
            try ["channelOverride", "channelAliasSearch", "channelOrder", "categoryOverride", "userCollection", "collectionItem"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        #expect(leftovers == [0, 0, 0, 0, 0, 0])
    }

    @Test func favoritesAndRecentsShowTheAlias() async throws {
        try await load()
        try await organization.setAlias("Spor", for: key("20"))
        try await bed.library.toggleFavorite(key("20"), title: "BEIN SPORTS 1")
        #expect(try await bed.library.favorites(sourceID: source.id).first?.channel?.displayName == "Spor")
    }
}
