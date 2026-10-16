import Foundation

/// One programme from the provider's guide. Times are absolute instants (UTC); display code
/// formats them in the user's time zone.
public struct EPGProgram: Identifiable, Hashable, Sendable {
    public let channelKey: MediaKey
    public let title: String
    public let summary: String?
    public let start: Date
    public let end: Date

    public var id: String { "\(channelKey)|\(start.timeIntervalSince1970)" }

    public init(channelKey: MediaKey, title: String, summary: String?, start: Date, end: Date) {
        self.channelKey = channelKey
        self.title = title
        self.summary = summary
        self.start = start
        self.end = end
    }

    public func isOnAir(at date: Date) -> Bool { start <= date && date < end }

    /// 0...1 progress at `date`.
    public func progress(at date: Date) -> Double {
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / length, 0), 1)
    }
}

/// Now and next for one channel at a given instant.
public struct NowNext: Equatable, Sendable {
    public let now: EPGProgram?
    public let next: EPGProgram?

    public init(programs: [EPGProgram], at date: Date) {
        let sorted = programs.sorted { $0.start < $1.start }
        let current = sorted.last { $0.isOnAir(at: date) }
        let boundary = current?.end ?? date
        now = current
        next = sorted.first { $0.start >= boundary }
    }

    public var isEmpty: Bool { now == nil && next == nil }
}
