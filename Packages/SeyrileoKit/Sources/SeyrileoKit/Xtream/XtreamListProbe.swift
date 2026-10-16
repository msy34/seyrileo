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
