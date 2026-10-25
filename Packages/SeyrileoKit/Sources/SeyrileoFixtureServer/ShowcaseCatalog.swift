import Foundation

/// A tidy, fictional catalogue for App Store screenshots and demos (`FixtureServer.Catalog.showcase`).
/// Every channel, programme, film and series name is invented; artwork and video come from
/// `scripts/generate-showcase-art.sh` (ffmpeg generators only). Streams all play the showcase loop.
enum ShowcaseCatalog {
    struct Channel {
        let id: Int
        let name: String
        let category: Int
        let shows: [String]
    }

    static let liveCategories: [(Int, String)] = [
        (1, "News & Talk"), (2, "Documentaries"), (3, "Kids & Family"), (4, "Sports"), (5, "Music"),
    ]

    static let channels: [Channel] = [
        Channel(id: 601, name: "Harbor News 24", category: 1,
                shows: ["Morning Brief", "Harbor Today", "World Desk", "Market Hour", "The Evening Edition", "Late Brief"]),
        Channel(id: 602, name: "Open Table Talk", category: 1,
                shows: ["Coffee & Questions", "The Long Interview", "City Voices", "Open Table", "Night Notes"]),
        Channel(id: 603, name: "Wild North", category: 2,
                shows: ["Fjords at Dawn", "Wolves of the Pines", "Ice Rivers", "The Quiet Tundra", "Northern Lights Live"]),
        Channel(id: 604, name: "Ocean Atlas", category: 2,
                shows: ["Reef Builders", "Deep Blue Cities", "Whale Roads", "Tide Pools", "The Kelp Forest"]),
        Channel(id: 605, name: "Star Lab", category: 2,
                shows: ["Moons of Saturn", "How Stars Die", "Backyard Sky", "Comet Hunters", "Living on Mars"]),
        Channel(id: 612, name: "Mountain Rails", category: 2,
                shows: ["Railways of the Alps", "The Night Train", "Bridges in the Clouds", "Station Stories", "Slow Journeys"]),
        Channel(id: 613, name: "Desert Bloom", category: 2,
                shows: ["After the Rain", "Sand Sea", "Oasis Life", "Desert Nights", "The Salt Flats"]),
        Channel(id: 606, name: "Whisker Kids", category: 3,
                shows: ["Paws & Puzzles", "The Tiny Explorers", "Story Lantern", "Draw Along", "Bedtime Tales"]),
        Channel(id: 607, name: "Little Lantern", category: 3,
                shows: ["Sing with Pip", "Garden Friends", "Counting Clouds", "Build It!", "Sleepy Songs"]),
        Channel(id: 608, name: "Arena One", category: 4,
                shows: ["Match Day Live", "Goal Review", "Track & Field", "The Locker Room", "Final Whistle"]),
        Channel(id: 609, name: "Court Side", category: 4,
                shows: ["Hoops Tonight", "Serve & Volley", "Classic Finals", "Training Ground", "Court Side Recap"]),
        Channel(id: 610, name: "Velvet Music TV", category: 5,
                shows: ["Morning Mix", "Acoustic Sessions", "Top 20 Countdown", "Studio Live", "Velvet Nights"]),
        Channel(id: 611, name: "Night Groove", category: 5,
                shows: ["Chill Hour", "Jazz Corner", "Vinyl Stories", "Late Lounge", "Deep Night Mix"]),
    ]

    struct Film {
        let id: Int
        let name: String
        let category: Int
        let genre: String
        let year: Int
        let minutes: Int
        let rating: String
        let plot: String
        let director: String
        let cast: String
    }

    static let vodCategories: [(Int, String)] = [(10, "New this week"), (11, "Drama"), (12, "Family")]

    static let films: [Film] = [
        Film(id: 701, name: "The Saffron Lighthouse", category: 10, genre: "Drama", year: 2025, minutes: 112, rating: "7.9",
             plot: "A lighthouse keeper's daughter returns to the island she left, and finds the lamp still burning for her.",
             director: "Ilse Marten", cast: "Nora Vale, Teo Brandt, Amira Kaye"),
        Film(id: 702, name: "Copper Kites", category: 10, genre: "Adventure", year: 2025, minutes: 98, rating: "7.4",
             plot: "Two brothers build kites from scrap copper to win the windiest festival on the coast.",
             director: "Rafael Ostin", cast: "Kip Moreau, Jun Halley"),
        Film(id: 703, name: "Tuesday the Cat", category: 12, genre: "Family", year: 2024, minutes: 89, rating: "8.1",
             plot: "Every Tuesday a ginger cat visits a different neighbour — until the whole street sets out to find out why.",
             director: "Mina Sorell", cast: "Ada Quill, Ben Arlo, Tuesday"),
        Film(id: 704, name: "Glass Orchard", category: 11, genre: "Drama", year: 2024, minutes: 121, rating: "7.6",
             plot: "An apple grower bets her last season on a greenhouse made of salvaged windows.",
             director: "Pavel Ren", cast: "Lena Ostrova, Sam Idris"),
        Film(id: 705, name: "Seven Small Harbors", category: 10, genre: "Documentary", year: 2025, minutes: 94, rating: "8.3",
             plot: "A year on the water with the people who keep seven tiny harbours alive.",
             director: "Ione Leclair", cast: ""),
        Film(id: 706, name: "The Winter Tram", category: 11, genre: "Romance", year: 2023, minutes: 104, rating: "7.2",
             plot: "Strangers share the last tram of every night through one snowy winter.",
             director: "Hugo Brenner", cast: "Clara Weiss, Omar Talib"),
        Film(id: 707, name: "Paperlight", category: 12, genre: "Animation", year: 2025, minutes: 86, rating: "7.8",
             plot: "A paper lantern comes alive and has one night to light its way home.",
             director: "Yuna Hale", cast: "Voices of Iris Lane, Max Corin"),
        Film(id: 708, name: "Hollow Bay", category: 11, genre: "Mystery", year: 2024, minutes: 109, rating: "7.0",
             plot: "When the tide goes out further than ever before, a quiet bay gives up an old secret.",
             director: "Daria Voss", cast: "Eli Stroud, June Navarro"),
    ]

    struct Show {
        let id: Int
        let name: String
        let genre: String
        let year: Int
        let rating: String
        let plot: String
        let seasons: [Int]  // episodes per season
    }

    static let episodeTitles = [
        "First Light", "The Late Bus", "Small Hours", "Borrowed Keys", "Rain on Tin", "The Open Door",
        "Lanterns", "Second Chances", "The Quiet Room", "Snowfall", "Paper Boats", "Homecoming",
    ]

    static let shows: [Show] = [
        Show(id: 801, name: "Night Shift Diaries", genre: "Drama", year: 2024, rating: "8.4",
             plot: "Nurses, cabbies and bakers: the city's night workers, one shift at a time.", seasons: [8, 8]),
        Show(id: 802, name: "The Lighthouse Kitchen", genre: "Comedy", year: 2025, rating: "7.9",
             plot: "A chef opens a tiny restaurant inside a working lighthouse.", seasons: [6]),
        Show(id: 803, name: "Moonlit Market", genre: "Mystery", year: 2023, rating: "7.7",
             plot: "Stallholders of a night market solve the small mysteries of their customers.", seasons: [10, 10, 8]),
        Show(id: 804, name: "Cat Café Chronicles", genre: "Family", year: 2025, rating: "8.2",
             plot: "Six cats, one café and the regulars who can't stay away.", seasons: [12]),
    ]

    // MARK: - JSON

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func art(_ base: String, _ file: String) -> String { "\(base)/fixture-media/showcase/\(file)" }

    static var liveCategoriesJSON: String {
        "[" + liveCategories.map { #"{"category_id":"\#($0.0)","category_name":"\#(escape($0.1))","parent_id":0}"# }
            .joined(separator: ",") + "]"
    }

    static func liveStreamsJSON(categoryID: String?) -> String {
        let selected = channels.filter { categoryID == nil || String($0.category) == categoryID }
        return "[" + selected.enumerated().map { index, channel in
            #"{"num":\#(index + 1),"name":"\#(escape(channel.name))","stream_type":"live","stream_id":\#(channel.id),"stream_icon":"","epg_channel_id":"showcase.\#(channel.id)","category_id":"\#(channel.category)","tv_archive":0}"#
        }.joined(separator: ",") + "]"
    }

    /// Programmes from 12 hours ago to 36 hours ahead, 30–90 minutes each, aligned to half hours.
    static func epgJSON(streamID: String, now: Date, limit: Int?) -> String {
        guard let channel = channels.first(where: { String($0.id) == streamID }) else { return #"{"epg_listings":[]}"# }
        let slot: TimeInterval = 1800
        var start = (now.timeIntervalSince1970 / slot).rounded(.down) * slot - 12 * 3600
        let horizon = now.timeIntervalSince1970 + 36 * 3600
        var listings: [String] = []
        var index = (Int(start / slot) + channel.id) % channel.shows.count
        while start < horizon {
            let length = TimeInterval([2, 1, 3, 2][(index + channel.id) % 4]) * slot
            let end = start + length
            if limit == nil || end > now.timeIntervalSince1970 {
                let title = Data(channel.shows[index % channel.shows.count].utf8).base64EncodedString()
                let description = Data("A fictional programme on \(channel.name).".utf8).base64EncodedString()
                listings.append(#"{"title":"\#(title)","description":"\#(description)","start_timestamp":"\#(Int(start))","stop_timestamp":"\#(Int(end))"}"#)
            }
            start = end
            index += 1
        }
        if let limit { listings = Array(listings.prefix(limit)) }
        return #"{"epg_listings":["# + listings.joined(separator: ",") + "]}"
    }

    static var vodCategoriesJSON: String {
        "[" + vodCategories.map { #"{"category_id":"\#($0.0)","category_name":"\#(escape($0.1))","parent_id":0}"# }
            .joined(separator: ",") + "]"
    }

    static func vodStreamsJSON(base: String, now: Date) -> String {
        "[" + films.enumerated().map { index, film in
            let added = Int(now.timeIntervalSince1970) - index * 86_400
            return #"{"num":\#(index + 1),"name":"\#(escape(film.name))","stream_type":"movie","stream_id":\#(film.id),"stream_icon":"\#(art(base, "poster-\(film.id).jpg"))","rating":"\#(film.rating)","added":"\#(added)","category_id":"10","category_ids":[\#(film.category == 10 ? "10" : "10,\(film.category)")],"container_extension":"mp4"}"#
        }.joined(separator: ",") + "]"
    }

    static func vodInfoJSON(id: String, base: String) -> String {
        guard let film = films.first(where: { String($0.id) == id }) else { return "[]" }
        return #"{"info":{"name":"\#(escape(film.name))","plot":"\#(escape(film.plot))","genre":"\#(film.genre)","cast":"\#(escape(film.cast))","director":"\#(escape(film.director))","releasedate":"\#(film.year)-03-14","duration_secs":"\#(film.minutes * 60)","rating":"\#(film.rating)","movie_image":"\#(art(base, "poster-\(film.id).jpg"))","backdrop_path":["\#(art(base, "backdrop-\(film.id).jpg"))"]},"movie_data":{"stream_id":\#(film.id),"name":"\#(escape(film.name))","container_extension":"mp4"}}"#
    }

    static let seriesCategoriesJSON = #"[{"category_id":"20","category_name":"Popular series","parent_id":0}]"#

    static func seriesJSON(base: String) -> String {
        "[" + shows.enumerated().map { index, show in
            #"{"num":\#(index + 1),"name":"\#(escape(show.name))","series_id":\#(show.id),"cover":"\#(art(base, "poster-\(show.id).jpg"))","plot":"\#(escape(show.plot))","genre":"\#(show.genre)","releaseDate":"\#(show.year)-09-01","rating":"\#(show.rating)","category_id":"20"}"#
        }.joined(separator: ",") + "]"
    }

    /// Episode ids: series id × 1000 + season × 100 + episode.
    static func seriesInfoJSON(id: String, base: String) -> String {
        guard let show = shows.first(where: { String($0.id) == id }) else { return "[]" }
        let seasons = show.seasons.indices.map { #"{"season_number":\#($0 + 1),"name":"Season \#($0 + 1)"}"# }
        let groups = show.seasons.enumerated().map { seasonIndex, count in
            let season = seasonIndex + 1
            let episodes = (1...count).map { number in
                #"{"id":"\#(show.id * 1000 + season * 100 + number)","episode_num":\#(number),"title":"\#(episodeTitles[(number - 1 + season) % episodeTitles.count])","container_extension":"mp4","season":\#(season),"info":{"duration_secs":"\#(2400 + (number % 4) * 180)","plot":"\#(escape(show.plot))"}}"#
            }
            return #""\#(season)":[\#(episodes.joined(separator: ","))]"#
        }
        return #"{"seasons":[\#(seasons.joined(separator: ","))],"info":{"name":"\#(escape(show.name))","plot":"\#(escape(show.plot))","genre":"\#(show.genre)","rating":"\#(show.rating)","cover":"\#(art(base, "poster-\(show.id).jpg"))","backdrop_path":["\#(art(base, "backdrop-\(show.id).jpg"))"]},"episodes":{\#(groups.joined(separator: ","))}}"#
    }

    static func isFilm(_ id: Int) -> Bool { films.contains { $0.id == id } }
    static func isEpisode(_ id: Int) -> Bool {
        let show = id / 1000, season = (id % 1000) / 100, episode = id % 100
        guard let match = shows.first(where: { $0.id == show }), season >= 1, season <= match.seasons.count else { return false }
        return episode >= 1 && episode <= match.seasons[season - 1]
    }
}
