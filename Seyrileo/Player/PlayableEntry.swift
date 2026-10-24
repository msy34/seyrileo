import Foundation
import SeyrileoKit

/// Anything the player can open. The player's previous/next controls walk a list of these.
enum PlayableEntry: Hashable, Identifiable {
    case channel(LiveChannel)
    case movie(Movie)
    case episode(Episode, seriesTitle: String, seriesPosterURL: URL?)

    var id: MediaKey { key }

    var key: MediaKey {
        switch self {
        case .channel(let channel): channel.key
        case .movie(let movie): movie.key
        case .episode(let episode, _, _): episode.key
        }
    }

    /// Whose audio/subtitle choice applies: the whole series for an episode.
    var trackPreferenceKey: MediaKey {
        switch self {
        case .episode(let episode, _, _): episode.seriesKey
        default: key
        }
    }

    var isLive: Bool { if case .channel = self { true } else { false } }
    var isEpisode: Bool { if case .episode = self { true } else { false } }

    var title: String {
        switch self {
        case .channel(let channel): SourceCatalogModel.title(channel)
        case .movie(let movie): movie.name.isEmpty ? String(app: "Untitled movie") : movie.name
        case .episode(let episode, let seriesTitle, _): PlayableEntry.episodeTitle(episode, seriesTitle: seriesTitle)
        }
    }

    static func episodeLabel(_ episode: Episode) -> String {
        if let number = episode.episodeNumber {
            return String(app: "S\(episode.seasonNumber) E\(number)")
        }
        return String(app: "Season \(episode.seasonNumber)")
    }

    static func episodeTitle(_ episode: Episode, seriesTitle: String) -> String {
        let label = episodeLabel(episode)
        return episode.title.isEmpty ? "\(seriesTitle) · \(label)" : "\(seriesTitle) · \(label) · \(episode.title)"
    }
}

enum StartPreference {
    /// Saved position if resumable, otherwise the beginning.
    case resumeIfPossible
    case beginning
}
