import Foundation

/// Xtream EPG listing: `get_short_epg` / `get_simple_data_table` entries. Titles and
/// descriptions are usually base64; timestamps come both as epoch seconds and as local
/// "yyyy-MM-dd HH:mm:ss" strings in the panel's time zone.
struct EPGListingDTO: Decodable {
    let title: String?
    let description: String?
    let startTimestamp: Int?
    let stopTimestamp: Int?
    let start: String?
    let end: String?

    enum CodingKeys: String, CodingKey {
        case title, description, start, end
        case startTimestamp = "start_timestamp"
        case stopTimestamp = "stop_timestamp"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.lenientString(.title)
        description = c.lenientString(.description)
        startTimestamp = c.lenientInt(.startTimestamp)
        stopTimestamp = c.lenientInt(.stopTimestamp)
        start = c.lenientString(.start)
        end = c.lenientString(.end)
    }
}

struct EPGListingsDTO: Decodable {
    let listings: LossyArray<EPGListingDTO>
    enum CodingKeys: String, CodingKey { case listings = "epg_listings" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try? c.decode(LossyArray<EPGListingDTO>.self, forKey: .listings) {
            listings = decoded
        } else {
            listings = try JSONDecoder().decode(LossyArray<EPGListingDTO>.self, from: Data("[]".utf8))
        }
    }
}

public struct EPGPage: Sendable {
    public let programs: [EPGProgram]
    /// Listings without usable times.
    public let droppedCount: Int
}

public enum EPGDecoding {
    /// Base64 text when it decodes to UTF-8, otherwise the raw value.
    static func text(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.count % 4 == 0, let data = Data(base64Encoded: raw), let decoded = String(data: data, encoding: .utf8) {
            let value = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return raw
    }

    /// Epoch seconds first; the local string only when the epoch is missing, interpreted in the
    /// panel's time zone (DST-correct via the zone identifier), then shifted by `offset`.
    static func date(epoch: Int?, local: String?, timeZone: TimeZone, offset: TimeInterval) -> Date? {
        if let epoch, epoch > 0 { return Date(timeIntervalSince1970: TimeInterval(epoch) + offset) }
        guard let local else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: local).map { $0.addingTimeInterval(offset) }
    }

    static func programs(
        from data: Data, channelKey: MediaKey, serverTimeZone: TimeZone, offset: TimeInterval
    ) throws -> EPGPage {
        let dto: EPGListingsDTO
        do { dto = try JSONDecoder().decode(EPGListingsDTO.self, from: data) } catch { throw XtreamError.malformedJSON }
        var dropped = dto.listings.droppedCount
        var programs: [EPGProgram] = []
        for listing in dto.listings.elements {
            guard let start = date(epoch: listing.startTimestamp, local: listing.start, timeZone: serverTimeZone, offset: offset),
                  let end = date(epoch: listing.stopTimestamp, local: listing.end, timeZone: serverTimeZone, offset: offset),
                  end > start, end.timeIntervalSince(start) <= 24 * 3600
            else {
                dropped += 1
                continue
            }
            let title = text(listing.title)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Panels fill gaps with filler entries ("No Data"); they are not programmes.
            guard !isPlaceholder(title) else {
                dropped += 1
                continue
            }
            programs.append(EPGProgram(
                channelKey: channelKey, title: title, summary: text(listing.description),
                start: start, end: end))
        }
        programs.sort { $0.start < $1.start }
        return EPGPage(programs: programs, droppedCount: dropped)
    }

    static func isPlaceholder(_ title: String) -> Bool {
        let folded = title.lowercased()
        return folded.isEmpty || ["no data", "no information", "no info", "no epg", "no programme", "no program", "n/a"]
            .contains(folded)
    }
}

extension XtreamClient {
    /// Current and upcoming programmes for one channel (`get_short_epg`).
    public func shortEPG(
        for channel: MediaKey, limit: Int = 4, serverTimeZone: TimeZone = .current, offset: TimeInterval = 0
    ) async throws -> EPGPage {
        let data = try await fetchEPG(action: "get_short_epg", parameters: [("stream_id", channel.remoteID), ("limit", String(limit))])
        return try EPGDecoding.programs(from: data, channelKey: channel, serverTimeZone: serverTimeZone, offset: offset)
    }

    /// The provider's full listing for one channel (`get_simple_data_table`, usually several days).
    public func fullEPG(
        for channel: MediaKey, serverTimeZone: TimeZone = .current, offset: TimeInterval = 0
    ) async throws -> EPGPage {
        let data = try await fetchEPG(action: "get_simple_data_table", parameters: [("stream_id", channel.remoteID)])
        return try EPGDecoding.programs(from: data, channelKey: channel, serverTimeZone: serverTimeZone, offset: offset)
    }

    private func fetchEPG(action: String, parameters: [(String, String)]) async throws -> Data {
        let data = try await fetchList(action: action, parameters: parameters, maxBytes: 4 * 1024 * 1024)
        // Panels answer `[]` or `{}` when a channel has no guide data.
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           (object as? [Any])?.isEmpty == true || (object as? [String: Any])?.isEmpty == true {
            return Data(#"{"epg_listings":[]}"#.utf8)
        }
        return data
    }
}
