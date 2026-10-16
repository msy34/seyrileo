import Foundation

// VOD and series DTOs. Panels differ widely: numbers as strings, `info` as `[]` when empty,
// `episodes` keyed by season number or as nested arrays. Unknown means nil.

struct VODStreamDTO: Decodable {
    let streamID: String
    let name: String
    let icon: String?
    let rating: String?
    let added: Int?
    let categoryID: String?
    let categoryIDs: [String]
    let containerExtension: String?

    enum CodingKeys: String, CodingKey {
        case name, rating, added
        case streamID = "stream_id"
        case icon = "stream_icon"
        case categoryID = "category_id"
        case categoryIDs = "category_ids"
        case containerExtension = "container_extension"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(.streamID), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.streamID, .init(codingPath: c.codingPath, debugDescription: "stream_id"))
        }
        streamID = id
        name = c.lenientString(.name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        icon = c.lenientString(.icon)
        rating = c.lenientString(.rating).flatMap { $0.isEmpty ? nil : $0 }
        added = c.lenientInt(.added)
        categoryID = c.lenientString(.categoryID)
        categoryIDs = c.lenientStringArray(.categoryIDs)
        containerExtension = c.lenientString(.containerExtension)
    }
}

struct SeriesDTO: Decodable {
    let seriesID: String
    let name: String
    let cover: String?
    let plot: String?
    let genre: String?
    let rating: String?
    let releaseDate: String?
    let categoryID: String?
    let categoryIDs: [String]

    enum CodingKeys: String, CodingKey {
        case name, cover, plot, genre, rating, releaseDate, release_date
        case seriesID = "series_id"
        case categoryID = "category_id"
        case categoryIDs = "category_ids"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(.seriesID), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.seriesID, .init(codingPath: c.codingPath, debugDescription: "series_id"))
        }
        seriesID = id
        name = c.lenientString(.name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cover = c.lenientString(.cover)
        plot = c.lenientString(.plot).nonEmpty
        genre = c.lenientString(.genre).nonEmpty
        rating = c.lenientString(.rating).nonEmpty
        releaseDate = (c.lenientString(.releaseDate) ?? c.lenientString(.release_date)).nonEmpty
        categoryID = c.lenientString(.categoryID)
        categoryIDs = c.lenientStringArray(.categoryIDs)
    }
}

/// `info` object shared by vod_info and series_info. Decodes `[]`/null as all-nil.
struct MediaInfoDTO: Decodable {
    var name: String?
    var plot: String?
    var genre: String?
    var cast: String?
    var director: String?
    var releaseDate: String?
    var country: String?
    var durationSeconds: Int?
    var rating: String?
    var poster: String?
    var backdrop: String?

    enum CodingKeys: String, CodingKey {
        case name, plot, description, genre, cast, actors, director, country, rating, cover
        case releasedate, releaseDate, release_date
        case durationSecs = "duration_secs"
        case movieImage = "movie_image"
        case coverBig = "cover_big"
        case backdropPath = "backdrop_path"
    }

    init() {}

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }  // `[]` or null
        name = c.lenientString(.name).nonEmpty
        plot = (c.lenientString(.plot) ?? c.lenientString(.description)).nonEmpty
        genre = c.lenientString(.genre).nonEmpty
        cast = (c.lenientString(.cast) ?? c.lenientString(.actors)).nonEmpty
        director = c.lenientString(.director).nonEmpty
        releaseDate = (c.lenientString(.releasedate) ?? c.lenientString(.releaseDate) ?? c.lenientString(.release_date)).nonEmpty
        country = c.lenientString(.country).nonEmpty
        durationSeconds = c.lenientInt(.durationSecs).flatMap { $0 > 0 ? $0 : nil }
        rating = c.lenientString(.rating).nonEmpty
        poster = (c.lenientString(.movieImage) ?? c.lenientString(.coverBig) ?? c.lenientString(.cover)).nonEmpty
        backdrop = c.lenientStringArray(.backdropPath).first ?? c.lenientString(.backdropPath).nonEmpty
    }
}

struct VODInfoDTO: Decodable {
    let info: MediaInfoDTO
    let containerExtension: String?

    enum CodingKeys: String, CodingKey {
        case info
        case movieData = "movie_data"
    }

    enum MovieDataKeys: String, CodingKey {
        case containerExtension = "container_extension"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = (try? c.decodeIfPresent(MediaInfoDTO.self, forKey: .info)) ?? MediaInfoDTO()
        let movieData = try? c.nestedContainer(keyedBy: MovieDataKeys.self, forKey: .movieData)
        containerExtension = movieData?.lenientString(.containerExtension)
    }
}

struct EpisodeDTO: Decodable {
    let id: String
    let episodeNumber: Int?
    let title: String
    let season: Int?
    let containerExtension: String?
    let info: MediaInfoDTO

    enum CodingKeys: String, CodingKey {
        case id, title, season, info
        case episodeNumber = "episode_num"
        case containerExtension = "container_extension"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(.id), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "id"))
        }
        self.id = id
        episodeNumber = c.lenientInt(.episodeNumber)
        title = c.lenientString(.title)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        season = c.lenientInt(.season)
        containerExtension = c.lenientString(.containerExtension)
        info = (try? c.decodeIfPresent(MediaInfoDTO.self, forKey: .info)) ?? MediaInfoDTO()
    }
}

struct SeriesInfoDTO: Decodable {
    struct SeasonDTO: Decodable {
        let number: Int?
        let name: String?
        enum CodingKeys: String, CodingKey { case name; case number = "season_number" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            number = c.lenientInt(.number)
            name = c.lenientString(.name).nonEmpty
        }
    }

    let info: MediaInfoDTO
    let seasons: [SeasonDTO]
    /// (season key from the payload, episodes) in payload order.
    let episodeGroups: [(season: Int?, episodes: LossyArray<EpisodeDTO>)]

    enum CodingKeys: String, CodingKey { case info, seasons, episodes }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = (try? c.decodeIfPresent(MediaInfoDTO.self, forKey: .info)) ?? MediaInfoDTO()
        seasons = (try? c.decodeIfPresent(LossyArray<SeasonDTO>.self, forKey: .seasons))?.elements ?? []
        var groups: [(Int?, LossyArray<EpisodeDTO>)] = []
        if let keyed = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: .episodes) {
            // {"1": [...], "2": [...]} — keys are season numbers.
            for key in keyed.allKeys.sorted(by: { (Int($0.stringValue) ?? .max) < (Int($1.stringValue) ?? .max) }) {
                if let list = try? keyed.decode(LossyArray<EpisodeDTO>.self, forKey: key) {
                    groups.append((Int(key.stringValue), list))
                }
            }
        } else if var outer = try? c.nestedUnkeyedContainer(forKey: .episodes) {
            // [[...], [...]] — season comes from each episode's `season` field.
            while !outer.isAtEnd {
                if let list = try? outer.decode(LossyArray<EpisodeDTO>.self) {
                    groups.append((nil, list))
                } else {
                    _ = try? outer.decode(AnyDecodable.self)
                }
            }
        }
        episodeGroups = groups
    }
}

private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
