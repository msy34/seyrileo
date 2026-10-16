import Foundation

public enum MediaKind: String, Codable, Sendable {
    case live, movie, series, episode
}

/// Stable, namespaced identity for any provider item: provider UUID + media kind + remote ID.
/// Never derived from display names, so user data is never attached to a different stream.
public struct MediaKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let providerID: UUID
    public let kind: MediaKind
    public let remoteID: String

    public init(providerID: UUID, kind: MediaKind, remoteID: String) {
        self.providerID = providerID
        self.kind = kind
        self.remoteID = remoteID
    }

    public var description: String { "\(providerID.uuidString)/\(kind.rawValue)/\(remoteID)" }
}

public struct LiveCategory: Identifiable, Hashable, Sendable {
    public let providerID: UUID
    public let remoteID: String
    public let name: String
    /// The user hid this category on this device.
    public let isHidden: Bool

    public var id: String { remoteID }

    public init(providerID: UUID, remoteID: String, name: String, isHidden: Bool = false) {
        self.providerID = providerID
        self.remoteID = remoteID
        self.name = name
        self.isHidden = isHidden
    }
}

public struct LiveChannel: Identifiable, Hashable, Sendable {
    public let key: MediaKey
    public let name: String
    public let number: Int?
    public let categoryIDs: [String]
    /// Provider-supplied icon URL. Not loaded in Milestone 1 (no bounded image loader yet).
    public let iconURL: URL?
    public let epgChannelID: String?
    /// Advisory only: provider metadata, not a verified catch-up capability.
    public let advertisesArchive: Bool
    /// The user's local name for this channel. `name` always keeps the provider's name.
    public let alias: String?
    /// The user hid this channel on this device.
    public let isHidden: Bool

    public var id: MediaKey { key }

    /// What the UI shows: the alias when set, otherwise the provider's name.
    public var displayName: String { alias ?? name }

    public init(
        key: MediaKey, name: String, number: Int?, categoryIDs: [String], iconURL: URL?,
        epgChannelID: String?, advertisesArchive: Bool, alias: String? = nil, isHidden: Bool = false
    ) {
        self.key = key
        self.name = name
        self.number = number
        self.categoryIDs = categoryIDs
        self.iconURL = iconURL
        self.epgChannelID = epgChannelID
        self.advertisesArchive = advertisesArchive
        self.alias = alias
        self.isHidden = isHidden
    }
}

/// Result of decoding a provider list. Items that could not be decoded are counted rather
/// than silently swallowed, so the UI can say "N entries could not be read".
public struct CatalogPage<Item: Sendable>: Sendable {
    public let items: [Item]
    public let droppedCount: Int

    public init(items: [Item], droppedCount: Int) {
        self.items = items
        self.droppedCount = droppedCount
    }
}

public enum StreamFormat: String, Sendable, CaseIterable {
    case hls = "m3u8"
    case mpegts = "ts"
}
