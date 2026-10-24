import Foundation

/// Shape check for list endpoints that have no domain model yet (movies, series arrive in
/// Milestone 3). Counts decodable JSON objects without interpreting provider fields.
public struct XtreamListProbe: Equatable, Sendable {
    public static let supportedActions: Set<String> = [
        "get_live_categories", "get_live_streams", "get_vod_categories", "get_vod_streams",
        "get_series_categories", "get_series",
    ]

    public let action: String
    public let itemCount: Int
    public let droppedCount: Int
    public let byteCount: Int
}

struct AnyJSONObject: Decodable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: Key.self)
    }
}

extension XtreamClient {
    /// Fetches one list action and reports counts only. Never opens a stream.
    public func probeList(action: String) async throws -> XtreamListProbe {
        precondition(XtreamListProbe.supportedActions.contains(action), "Unsupported probe action")
        let data = try await fetchList(action: action)
        let list = try Self.decodeList(AnyJSONObject.self, from: data)
        return XtreamListProbe(
            action: action, itemCount: list.elements.count, droppedCount: list.droppedCount, byteCount: data.count)
    }
}

/// Shape of one detail answer (`get_vod_info` / `get_series_info`): key names of `info` and
/// whether any external-id-looking field is present. Never reports values (except id formats).
public struct XtreamDetailProbe: Equatable, Sendable {
    public let infoKeys: [String]
    /// Keys whose name mentions imdb/tmdb/kinopoisk, with the shape of their value.
    public let externalIDs: [String: String]
}

extension XtreamClient {
    public func probeDetail(_ key: MediaKey) async throws -> XtreamDetailProbe {
        let (action, parameter) = key.kind == .series ? ("get_series_info", "series_id") : ("get_vod_info", "vod_id")
        let data = try await fetchObject(action: action, parameters: [(parameter, key.remoteID)])
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let info = root["info"] as? [String: Any] ?? [:]
        var external: [String: String] = [:]
        for (name, value) in info.merging(root.filter { !($0.value is [Any]) && !($0.value is [String: Any]) }, uniquingKeysWith: { a, _ in a }) {
            let lower = name.lowercased()
            guard lower.contains("imdb") || lower.contains("tmdb") || lower.contains("kinopoisk") else { continue }
            let text = "\(value)"
            let shape: String
            if text.isEmpty || value is NSNull { shape = "empty" }
            else if text.range(of: #"^tt\d{5,10}$"#, options: .regularExpression) != nil { shape = "tt-id" }
            else if text.range(of: #"^\d+$"#, options: .regularExpression) != nil { shape = "number" }
            else if text.lowercased().contains("imdb.com/title/tt") { shape = "imdb-url" }
            else { shape = "other(\(text.count) chars)" }
            external[name] = shape
        }
        return XtreamDetailProbe(infoKeys: info.keys.sorted(), externalIDs: external)
    }
}
