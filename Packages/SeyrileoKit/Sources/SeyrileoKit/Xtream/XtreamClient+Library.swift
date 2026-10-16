import Foundation

/// Why a movie or episode cannot be played. Never guessed: these are only raised when the
/// provider did not supply what is needed.
public enum LibraryPlaybackError: Error, Equatable, Sendable {
    /// The provider did not report a container extension, so the stream address is unknown.
    case unknownContainer
    /// The server answered with a page (often empty HTML) instead of a video file: the file is
    /// missing on the provider's side. Measured, not guessed (see `MediaPreflight`).
    case providerReturnedNoMedia
}

extension XtreamClient {
    public func vodCategories() async throws -> CatalogPage<MediaCategory> {
        try await mediaCategories(action: "get_vod_categories", kind: .movie)
    }

    public func seriesCategories() async throws -> CatalogPage<MediaCategory> {
        try await mediaCategories(action: "get_series_categories", kind: .series)
    }

    private func mediaCategories(action: String, kind: MediaKind) async throws -> CatalogPage<MediaCategory> {
        let data = try await fetchList(action: action)
        let list = try Self.decodeList(CategoryDTO.self, from: data)
        return CatalogPage(
            items: list.elements.map { MediaCategory(providerID: providerID, kind: kind, remoteID: $0.id, name: $0.name) },
            droppedCount: list.droppedCount)
    }

    /// All movies in one request (lighter on the provider than one request per category).
    public func vodStreams() async throws -> CatalogPage<Movie> {
        let list = try Self.decodeList(VODStreamDTO.self, from: try await fetchList(action: "get_vod_streams"))
        return CatalogPage(items: list.elements.map { dto in
            Movie(
                key: MediaKey(providerID: providerID, kind: .movie, remoteID: dto.streamID),
                name: dto.name,
                posterURL: Self.url(dto.icon),
                rating: dto.rating,
                addedAt: dto.added.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                categoryIDs: dto.categoryIDs.isEmpty ? dto.categoryID.map { [$0] } ?? [] : dto.categoryIDs,
                containerExtension: ContainerExtension.sanitize(dto.containerExtension))
        }, droppedCount: list.droppedCount)
    }

    public func seriesList() async throws -> CatalogPage<Series> {
        let list = try Self.decodeList(SeriesDTO.self, from: try await fetchList(action: "get_series"))
        return CatalogPage(items: list.elements.map { dto in
            Series(
                key: MediaKey(providerID: providerID, kind: .series, remoteID: dto.seriesID),
                name: dto.name, posterURL: Self.url(dto.cover), plot: dto.plot, genre: dto.genre,
                rating: dto.rating, releaseDate: dto.releaseDate,
                categoryIDs: dto.categoryIDs.isEmpty ? dto.categoryID.map { [$0] } ?? [] : dto.categoryIDs)
        }, droppedCount: list.droppedCount)
    }

    public func movieDetail(_ key: MediaKey) async throws -> MovieDetail {
        let data = try await fetchObject(action: "get_vod_info", parameters: [("vod_id", key.remoteID)])
        let dto: VODInfoDTO
        do { dto = try JSONDecoder().decode(VODInfoDTO.self, from: data) } catch { throw XtreamError.malformedJSON }
        let info = dto.info
        return MovieDetail(
            key: key, name: info.name, plot: info.plot, genre: info.genre, cast: info.cast, director: info.director,
            releaseDate: info.releaseDate, country: info.country, durationSeconds: info.durationSeconds,
            rating: info.rating, posterURL: Self.url(info.poster), backdropURL: Self.url(info.backdrop),
            containerExtension: ContainerExtension.sanitize(dto.containerExtension))
    }

    public func seriesDetail(_ key: MediaKey) async throws -> SeriesDetail {
        let data = try await fetchObject(action: "get_series_info", parameters: [("series_id", key.remoteID)])
        let dto: SeriesInfoDTO
        do { dto = try JSONDecoder().decode(SeriesInfoDTO.self, from: data) } catch { throw XtreamError.malformedJSON }
        var bySeason: [Int: [Episode]] = [:]
        var dropped = 0
        for group in dto.episodeGroups {
            dropped += group.episodes.droppedCount
            for episode in group.episodes.elements {
                let season = episode.season ?? group.season ?? 1
                bySeason[season, default: []].append(Episode(
                    key: MediaKey(providerID: providerID, kind: .episode, remoteID: episode.id),
                    seriesKey: key, seasonNumber: season, episodeNumber: episode.episodeNumber,
                    title: episode.title.isEmpty ? (episode.info.name ?? "") : episode.title,
                    plot: episode.info.plot, durationSeconds: episode.info.durationSeconds,
                    stillURL: Self.url(episode.info.poster),
                    containerExtension: ContainerExtension.sanitize(episode.containerExtension)))
            }
        }
        let seasonNames = Dictionary(dto.seasons.compactMap { s in s.number.map { ($0, s.name) } }, uniquingKeysWith: { a, _ in a })
        let seasons = bySeason.keys.sorted().map { number in
            Season(
                number: number, name: seasonNames[number] ?? nil,
                episodes: bySeason[number]!.enumerated().sorted { lhs, rhs in
                    // Episode number when present, otherwise payload order.
                    switch (lhs.element.episodeNumber, rhs.element.episodeNumber) {
                    case let (l?, r?) where l != r: l < r
                    default: lhs.offset < rhs.offset
                    }
                }.map(\.element))
        }
        let info = dto.info
        return SeriesDetail(
            key: key, name: info.name, plot: info.plot, genre: info.genre, cast: info.cast, director: info.director,
            releaseDate: info.releaseDate, rating: info.rating, posterURL: Self.url(info.poster),
            backdropURL: Self.url(info.backdrop), seasons: seasons, droppedEpisodes: dropped)
    }

    /// Credential-bearing stream URL. Treat as a secret: never log or persist it.
    public func movieStreamURL(_ key: MediaKey, containerExtension: String?) throws -> URL {
        guard let ext = ContainerExtension.sanitize(containerExtension) else { throw LibraryPlaybackError.unknownContainer }
        return endpoint.movieStreamURL(credentials: credentials, streamID: key.remoteID, containerExtension: ext)
    }

    public func episodeStreamURL(_ episode: Episode) throws -> URL {
        guard let ext = episode.containerExtension else { throw LibraryPlaybackError.unknownContainer }
        return endpoint.episodeStreamURL(credentials: credentials, episodeID: episode.key.remoteID, containerExtension: ext)
    }

    static func url(_ string: String?) -> URL? {
        guard let string = string.nonEmpty, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }
}
