import Foundation

/// A movie or series category (Xtream VOD / series categories).
public struct MediaCategory: Identifiable, Hashable, Sendable {
    public let providerID: UUID
    public let kind: MediaKind
    public let remoteID: String
    public let name: String

    public var id: String { remoteID }

    public init(providerID: UUID, kind: MediaKind, remoteID: String, name: String) {
        self.providerID = providerID
        self.kind = kind
        self.remoteID = remoteID
        self.name = name
    }
}

public struct Movie: Identifiable, Hashable, Sendable {
    public let key: MediaKey
    public let name: String
    public let posterURL: URL?
    /// Provider rating text (scale varies by provider); shown as-is, never converted.
    public let rating: String?
    public let addedAt: Date?
    public let categoryIDs: [String]
    /// Container reported by the provider (e.g. "mp4", "mkv"). nil means unknown.
    public let containerExtension: String?

    public var id: MediaKey { key }

    public init(
        key: MediaKey, name: String, posterURL: URL?, rating: String?, addedAt: Date?, categoryIDs: [String],
        containerExtension: String?
    ) {
        self.key = key
        self.name = name
        self.posterURL = posterURL
        self.rating = rating
        self.addedAt = addedAt
        self.categoryIDs = categoryIDs
        self.containerExtension = containerExtension
    }
}

/// Optional metadata from `get_vod_info`. Every field may be missing.
public struct MovieDetail: Sendable, Equatable {
    public let key: MediaKey
    public let name: String?
    public let plot: String?
    public let genre: String?
    public let cast: String?
    public let director: String?
    public let releaseDate: String?
    public let country: String?
    public let durationSeconds: Int?
    public let rating: String?
    public let posterURL: URL?
    public let backdropURL: URL?
    public let containerExtension: String?

    public init(
        key: MediaKey, name: String?, plot: String?, genre: String?, cast: String?, director: String?,
        releaseDate: String?, country: String?, durationSeconds: Int?, rating: String?, posterURL: URL?,
        backdropURL: URL?, containerExtension: String?
    ) {
        self.key = key
        self.name = name
        self.plot = plot
        self.genre = genre
        self.cast = cast
        self.director = director
        self.releaseDate = releaseDate
        self.country = country
        self.durationSeconds = durationSeconds
        self.rating = rating
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.containerExtension = containerExtension
    }
}

public struct Series: Identifiable, Hashable, Sendable {
    public let key: MediaKey
    public let name: String
    public let posterURL: URL?
    public let plot: String?
    public let genre: String?
    public let rating: String?
    public let releaseDate: String?
    public let categoryIDs: [String]

    public var id: MediaKey { key }

    public init(
        key: MediaKey, name: String, posterURL: URL?, plot: String?, genre: String?, rating: String?,
        releaseDate: String?, categoryIDs: [String]
    ) {
        self.key = key
        self.name = name
        self.posterURL = posterURL
        self.plot = plot
        self.genre = genre
        self.rating = rating
        self.releaseDate = releaseDate
        self.categoryIDs = categoryIDs
    }
}

public struct Episode: Identifiable, Hashable, Sendable {
    /// kind `.episode`, remoteID = the provider's episode stream id.
    public let key: MediaKey
    public let seriesKey: MediaKey
    public let seasonNumber: Int
    /// nil when the provider did not number the episode.
    public let episodeNumber: Int?
    public let title: String
    public let plot: String?
    public let durationSeconds: Int?
    public let stillURL: URL?
    public let containerExtension: String?

    public var id: MediaKey { key }

    public init(
        key: MediaKey, seriesKey: MediaKey, seasonNumber: Int, episodeNumber: Int?, title: String, plot: String?,
        durationSeconds: Int?, stillURL: URL?, containerExtension: String?
    ) {
        self.key = key
        self.seriesKey = seriesKey
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.title = title
        self.plot = plot
        self.durationSeconds = durationSeconds
        self.stillURL = stillURL
        self.containerExtension = containerExtension
    }
}

public struct Season: Identifiable, Hashable, Sendable {
    public let number: Int
    public let name: String?
    public let episodes: [Episode]

    public var id: Int { number }

    public init(number: Int, name: String?, episodes: [Episode]) {
        self.number = number
        self.name = name
        self.episodes = episodes
    }
}

/// `get_series_info` result: seasons in ascending order, episodes in provider episode order.
public struct SeriesDetail: Sendable, Equatable {
    public let key: MediaKey
    public let name: String?
    public let plot: String?
    public let genre: String?
    public let cast: String?
    public let director: String?
    public let releaseDate: String?
    public let rating: String?
    public let posterURL: URL?
    public let backdropURL: URL?
    public let seasons: [Season]
    /// Episode entries that could not be read (e.g. missing id).
    public let droppedEpisodes: Int

    public init(
        key: MediaKey, name: String?, plot: String?, genre: String?, cast: String?, director: String?,
        releaseDate: String?, rating: String?, posterURL: URL?, backdropURL: URL?, seasons: [Season], droppedEpisodes: Int
    ) {
        self.key = key
        self.name = name
        self.plot = plot
        self.genre = genre
        self.cast = cast
        self.director = director
        self.releaseDate = releaseDate
        self.rating = rating
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.seasons = seasons
        self.droppedEpisodes = droppedEpisodes
    }

    public var allEpisodes: [Episode] { seasons.flatMap(\.episodes) }

    /// The episode after `key` in season/episode order, if any.
    public func episode(after key: MediaKey) -> Episode? {
        let episodes = allEpisodes
        guard let index = episodes.firstIndex(where: { $0.key == key }), index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }
}

/// Container extensions are interpolated into stream paths; only short alphanumeric values
/// are accepted, anything else is treated as unknown.
enum ContainerExtension {
    static func sanitize(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              (1...5).contains(value.count),
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return value
    }
}
