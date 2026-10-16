import Foundation
import Observation

/// Debounced local channel search. Each keystroke cancels the pending search; only the last
/// query after `debounce` runs against the index. Stale results never overwrite newer ones.
@MainActor
@Observable
public final class ChannelSearchController {
    public enum Phase: Equatable {
        /// Nothing to search (empty or punctuation-only query).
        case idle
        case searching
        case results([LiveChannel], truncated: Bool)
        case failed
    }

    public private(set) var phase: Phase = .idle
    public var query: String = "" { didSet { if query != oldValue { schedule() } } }
    public var categoryID: String? { didSet { if categoryID != oldValue { schedule() } } }

    @ObservationIgnored private let sourceID: UUID
    @ObservationIgnored private let store: CatalogStore
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let sleeper: Sleeper
    @ObservationIgnored private(set) var pending: Task<Void, Never>?
    @ObservationIgnored private(set) var executedQueries: [String] = []

    public init(
        sourceID: UUID, store: CatalogStore, debounce: Duration = .milliseconds(250),
        sleeper: @escaping Sleeper = RetryPolicy.taskSleeper
    ) {
        self.sourceID = sourceID
        self.store = store
        self.debounce = debounce
        self.sleeper = sleeper
    }

    /// Re-runs the current query (e.g. after a catalogue refresh).
    public func refresh() { schedule() }

    private func schedule() {
        pending?.cancel()
        let query = query
        let categoryID = categoryID
        guard SearchText.ftsPrefixQuery(query) != nil else {
            pending = nil
            phase = .idle
            return
        }
        phase = .searching
        pending = Task { [weak self, sleeper, debounce, store, sourceID] in
            do { try await sleeper(debounce) } catch { return }
            guard !Task.isCancelled else { return }
            self?.executedQueries.append(query)
            let result = try? await store.search(sourceID: sourceID, query: query, categoryID: categoryID)
            guard !Task.isCancelled, let self else { return }
            if let result {
                self.phase = .results(result.channels, truncated: result.isTruncated)
            } else {
                self.phase = .failed
            }
        }
    }
}
