import Foundation

/// The audio and subtitle choice a user made for a title, remembered by track *name*:
/// track numbers differ between episodes and files, names and languages usually do not.
public struct TrackPreference: Codable, Equatable, Sendable {
    public var audio: String?
    public var subtitle: String?
    /// The user turned subtitles off.
    public var subtitlesOff: Bool

    public init(audio: String? = nil, subtitle: String? = nil, subtitlesOff: Bool = false) {
        self.audio = audio
        self.subtitle = subtitle
        self.subtitlesOff = subtitlesOff
    }

    /// Storage key: a series' episodes share one choice; movies and channels have their own.
    public static func storageKey(for key: MediaKey) -> String {
        "tracks|\(key.kind.rawValue)|\(key.remoteID)"
    }
}

public enum TrackMatcher {
    /// Picks the track that best matches a remembered name: the same name first, then the same
    /// language (VLC names tracks like "Track 2 - [English]" or "Türkçe - [Turkish]").
    /// Returns nil when nothing matches, so the player keeps its own default.
    public static func bestMatch(_ preferred: String, among tracks: [(index: Int32, name: String)]) -> Int32? {
        let candidates = tracks.filter { $0.index >= 0 }
        let wanted = SearchText.normalize(preferred)
        if let exact = candidates.first(where: { SearchText.normalize($0.name) == wanted }) { return exact.index }
        guard let language = language(in: preferred) else { return nil }
        if let same = candidates.first(where: { Self.language(in: $0.name) == language }) { return same.index }
        return candidates.first(where: { SearchText.normalize($0.name).split(separator: " ").contains(Substring(language)) })?.index
    }

    /// The language part of a track name: the text in [brackets], else the whole name if it is a
    /// single word (e.g. "Türkçe"), normalized.
    static func language(in name: String) -> String? {
        if let open = name.lastIndex(of: "["), let close = name.lastIndex(of: "]"), open < close {
            let inside = SearchText.normalize(String(name[name.index(after: open)..<close]))
            return inside.isEmpty ? nil : inside
        }
        let normalized = SearchText.normalize(name)
        return normalized.isEmpty || normalized.contains(" ") ? nil : normalized
    }
}
