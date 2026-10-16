import Foundation

/// Lazy, bounded EPG loading. Guide data is requested only for channels that are on screen,
/// at most `maxConcurrent` requests at a time, identical requests are shared, and results
/// (including "no data") are cached for `ttl`. Nothing is downloaded for all channels.
public actor EPGService {
    public typealias Fetch = @Sendable (MediaKey) async throws -> EPGPage

    private struct Entry {
        let programs: [EPGProgram]
        let fetchedAt: Date
    }

    private let fetchShort: Fetch
    private let fetchFull: Fetch
    private let ttl: TimeInterval
    private let failureTTL: TimeInterval
    private let maxConcurrent: Int
    private let now: @Sendable () -> Date

    private var shortCache: [MediaKey: Entry] = [:]
    private var fullCache: [MediaKey: Entry] = [:]
    private var failures: [MediaKey: Date] = [:]
    private var inFlight: [String: Task<[EPGProgram], Error>] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0
    private(set) var maxObservedConcurrency = 0

    public init(
        ttl: TimeInterval = 15 * 60, failureTTL: TimeInterval = 5 * 60, maxConcurrent: Int = 3,
        now: @escaping @Sendable () -> Date = Date.init, fetchShort: @escaping Fetch, fetchFull: @escaping Fetch
    ) {
        self.ttl = ttl
        self.failureTTL = failureTTL
        self.maxConcurrent = maxConcurrent
        self.now = now
        self.fetchShort = fetchShort
        self.fetchFull = fetchFull
    }

    /// Now/next for a channel; nil when the provider has no guide data for it.
    public func nowNext(for channel: MediaKey) async -> NowNext? {
        let date = now()
        // The day table, if already loaded, answers without another request.
        if let full = fullCache[channel], date.timeIntervalSince(full.fetchedAt) < ttl {
            let result = NowNext(programs: full.programs, at: date)
            if !result.isEmpty { return result }
        }
        if let cached = shortCache[channel], date.timeIntervalSince(cached.fetchedAt) < ttl,
           cached.programs.contains(where: { $0.end > date }) || cached.programs.isEmpty {
            let result = NowNext(programs: cached.programs, at: date)
            return result.isEmpty ? nil : result
        }
        if let failed = failures[channel], date.timeIntervalSince(failed) < failureTTL { return nil }
        guard let programs = try? await load("short|\(channel)", channel: channel, fetch: fetchShort, full: false) else {
            failures[channel] = now()
            return nil
        }
        let result = NowNext(programs: programs, at: now())
        return result.isEmpty ? nil : result
    }

    /// The provider's full listing (several days), cached like now/next.
    public func guide(for channel: MediaKey) async throws -> [EPGProgram] {
        if let cached = fullCache[channel], now().timeIntervalSince(cached.fetchedAt) < ttl { return cached.programs }
        return try await load("full|\(channel)", channel: channel, fetch: fetchFull, full: true)
    }

    public func invalidate() {
        shortCache.removeAll()
        fullCache.removeAll()
        failures.removeAll()
    }

    private func load(
        _ key: String, channel: MediaKey, fetch: @escaping Fetch, full: Bool
    ) async throws -> [EPGProgram] {
        if let task = inFlight[key] { return try await task.value }
        let task = Task<[EPGProgram], Error> {
            await self.acquire()
            defer { self.release() }
            return try await fetch(channel).programs
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let programs = try await task.value
        let entry = Entry(programs: programs, fetchedAt: now())
        if full { fullCache[channel] = entry } else { shortCache[channel] = entry }
        return programs
    }

    private func acquire() async {
        requestCount += 1
        if active < maxConcurrent {
            active += 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
        maxObservedConcurrency = max(maxObservedConcurrency, active)
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
