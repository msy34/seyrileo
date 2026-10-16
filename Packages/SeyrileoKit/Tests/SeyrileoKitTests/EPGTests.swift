import Foundation
import Testing
@testable import SeyrileoKit

@Suite struct EPGDecodingTests {
    let channel = MediaKey(providerID: UUID(), kind: .live, remoteID: "1")
    let istanbul = TimeZone(identifier: "Europe/Istanbul")!

    @Test func base64TitlesAndEpochTimes() throws {
        let title = Data("Hoffenheim - Beşiktaş".utf8).base64EncodedString()
        let json = #"{"epg_listings":[{"title":"\#(title)","description":"","start":"2026-10-15 20:00:00","end":"2026-10-15 22:00:00","start_timestamp":"1760547600","stop_timestamp":1760554800}]}"#
        let page = try EPGDecoding.programs(from: Data(json.utf8), channelKey: channel, serverTimeZone: istanbul, offset: 0)
        #expect(page.programs.count == 1)
        #expect(page.programs[0].title == "Hoffenheim - Beşiktaş")
        #expect(page.programs[0].summary == nil)
        #expect(page.programs[0].start == Date(timeIntervalSince1970: 1_760_547_600))
        #expect(page.programs[0].end.timeIntervalSince(page.programs[0].start) == 7200)
    }

    @Test func placeholderEntriesAreDropped() throws {
        let filler = Data("No Data".utf8).base64EncodedString()
        let real = Data("Teşkilat".utf8).base64EncodedString()
        let json = #"{"epg_listings":[{"title":"\#(filler)","start_timestamp":"1760547600","stop_timestamp":"1760554800"},{"title":"\#(real)","start_timestamp":"1760554800","stop_timestamp":"1760562000"}]}"#
        let page = try EPGDecoding.programs(from: Data(json.utf8), channelKey: channel, serverTimeZone: istanbul, offset: 0)
        #expect(page.programs.map(\.title) == ["Teşkilat"])
        #expect(page.droppedCount == 1)
    }

    @Test func plainTitlesStayAsIs() {
        #expect(EPGDecoding.text("Haber") == "Haber")
        #expect(EPGDecoding.text("  ") == nil)
        #expect(EPGDecoding.text(Data("Çocuk".utf8).base64EncodedString()) == "Çocuk")
    }

    @Test func localStringsUseServerZoneAcrossDST() throws {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        // 2026-03-29 02:00 → 03:00 CET→CEST. A 01:30–03:30 local programme lasts one real hour.
        let start = try #require(EPGDecoding.date(epoch: nil, local: "2026-03-29 01:30:00", timeZone: berlin, offset: 0))
        let end = try #require(EPGDecoding.date(epoch: nil, local: "2026-03-29 03:30:00", timeZone: berlin, offset: 0))
        #expect(end.timeIntervalSince(start) == 3600)
        // Istanbul has no DST: UTC+3 all year.
        let istanbulTime = try #require(EPGDecoding.date(epoch: nil, local: "2026-07-01 12:00:00", timeZone: istanbul, offset: 0))
        #expect(istanbulTime == Date(timeIntervalSince1970: 1_782_896_400))
    }

    @Test func manualOffsetShiftsTimes() throws {
        let shifted = try #require(EPGDecoding.date(epoch: 1_760_547_600, local: nil, timeZone: istanbul, offset: -3600))
        #expect(shifted == Date(timeIntervalSince1970: 1_760_544_000))
    }

    @Test func invalidListingsAreDroppedAndEmptyAnswersAreEmpty() throws {
        let json = #"{"epg_listings":[{"title":"x"},{"title":"y","start_timestamp":200,"stop_timestamp":100},{"title":"z","start_timestamp":100,"stop_timestamp":999999}]}"#
        let page = try EPGDecoding.programs(from: Data(json.utf8), channelKey: channel, serverTimeZone: istanbul, offset: 0)
        #expect(page.programs.isEmpty)
        #expect(page.droppedCount == 3)
        #expect(throws: XtreamError.malformedJSON) {
            try EPGDecoding.programs(from: Data("{".utf8), channelKey: channel, serverTimeZone: istanbul, offset: 0)
        }
    }

    @Test func nowNextAtBoundaries() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = EPGProgram(channelKey: channel, title: "A", summary: nil, start: base, end: base + 3600)
        let b = EPGProgram(channelKey: channel, title: "B", summary: nil, start: base + 3600, end: base + 7200)
        #expect(NowNext(programs: [b, a], at: base + 10).now?.title == "A")
        #expect(NowNext(programs: [b, a], at: base + 10).next?.title == "B")
        #expect(NowNext(programs: [a, b], at: base + 3600).now?.title == "B")  // end is exclusive
        #expect(NowNext(programs: [a, b], at: base - 60).now == nil)
        #expect(NowNext(programs: [a, b], at: base - 60).next?.title == "A")
        #expect(NowNext(programs: [a, b], at: base + 9000).isEmpty)
        #expect(a.progress(at: base + 1800) == 0.5)
    }
}

@Suite struct EPGServiceTests {
    let channels = (0..<12).map { MediaKey(providerID: UUID(), kind: .live, remoteID: "\($0)") }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    static func page(_ key: MediaKey, at date: Date) -> EPGPage {
        EPGPage(programs: [
            EPGProgram(channelKey: key, title: "Now", summary: nil, start: date - 600, end: date + 600),
            EPGProgram(channelKey: key, title: "Next", summary: nil, start: date + 600, end: date + 1800),
        ], droppedCount: 0)
    }

    @Test func boundedConcurrencyAndSharedRequests() async {
        let date = Date()
        let gate = AsyncGate()
        let counter = Counter()
        let service = EPGService(now: { date }, fetchShort: { key in
            counter.increment()
            await gate.wait()
            return Self.page(key, at: date)
        }, fetchFull: { _ in EPGPage(programs: [], droppedCount: 0) })
        await withTaskGroup(of: NowNext?.self) { group in
            for channel in channels { group.addTask { await service.nowNext(for: channel) } }
            for _ in 0..<3 { group.addTask { await service.nowNext(for: channels[0]) } }  // duplicates
            try? await Task.sleep(for: .milliseconds(50))
            await gate.open()
            for await result in group { #expect(result?.now?.title == "Now") }
        }
        #expect(counter.count == channels.count)
        #expect(await service.maxObservedConcurrency <= 3)
    }

    @Test func cachesResultsAndMissingData() async {
        let clock = Clock()
        let counter = Counter()
        let service = EPGService(ttl: 900, now: { clock.date }, fetchShort: { key in
            counter.increment()
            return key.remoteID == "0" ? Self.page(key, at: clock.date) : EPGPage(programs: [], droppedCount: 0)
        }, fetchFull: { _ in EPGPage(programs: [], droppedCount: 0) })
        #expect(await service.nowNext(for: channels[0])?.now?.title == "Now")
        #expect(await service.nowNext(for: channels[1]) == nil)
        _ = await service.nowNext(for: channels[0])
        _ = await service.nowNext(for: channels[1])
        #expect(counter.count == 2)
        clock.date += 1000  // past TTL
        _ = await service.nowNext(for: channels[0])
        #expect(counter.count == 3)
    }

    @Test func failuresAreNotRetriedImmediately() async {
        let counter = Counter()
        let service = EPGService(now: { Date() }, fetchShort: { _ in
            counter.increment()
            throw XtreamError.httpStatus(503)
        }, fetchFull: { _ in throw XtreamError.httpStatus(503) })
        #expect(await service.nowNext(for: channels[0]) == nil)
        #expect(await service.nowNext(for: channels[0]) == nil)
        #expect(counter.count == 1)
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000_000)
        var date: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}
