#if DEBUG
import Foundation
import SeyrileoKit

/// Debug-only real-provider check, started with the launch argument `-SeyrileoProviderProbe`.
/// Uses the active (non-fixture) source's Keychain credentials, requests list endpoints only
/// (never opens a stream) and writes a redacted report to Caches/provider-probe.txt.
/// The report contains no credentials, URLs or host names.
enum ProviderProbe {
    static let argument = "-SeyrileoProviderProbe"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// `-SeyrileoMediaProbe <series name>`: additionally reads the first 16 bytes of season 1
    /// episode 2 of that series (one small ranged request; the stream is never played).
    static var mediaQuery: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-SeyrileoMediaProbe"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func probeSeriesEpisode(query: String, client: XtreamClient, into lines: inout [String]) async {
        do {
            let list = try await client.seriesList()
            let needle = SearchText.normalize(query)
            guard let series = list.items.first(where: { SearchText.normalize($0.name).contains(needle) }) else {
                lines.append("media probe: no series matching query")
                return
            }
            let detail = try await client.seriesDetail(series.key)
            let containers = Dictionary(grouping: detail.allEpisodes) { $0.containerExtension ?? "none" }.mapValues(\.count)
            lines.append("media probe series: seasons=\(detail.seasons.count) episodes=\(detail.allEpisodes.count) containers=\(containers)")
            guard let episode = detail.seasons.first(where: { $0.number == 1 })?.episodes.first(where: { $0.episodeNumber == 2 })
                ?? detail.allEpisodes.dropFirst().first
            else { return }
            lines.append("media probe episode: container=\(episode.containerExtension ?? "none") duration=\(episode.durationSeconds.map(String.init) ?? "unknown")")
            let url = try client.episodeStreamURL(episode)
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("bytes=0-15", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let redirected = response.url?.host != url.host
            let magic = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            lines.append("media probe response: status=\(http?.statusCode ?? -1) type=\(http?.value(forHTTPHeaderField: "Content-Type") ?? "none") "
                + "range=\(http?.value(forHTTPHeaderField: "Content-Range") ?? "none") length=\(http?.value(forHTTPHeaderField: "Content-Length") ?? "none") "
                + "acceptRanges=\(http?.value(forHTTPHeaderField: "Accept-Ranges") ?? "none") redirectedToOtherHost=\(redirected) bytes=\(data.count) magic=\(magic)")
            // Sample other episodes of the same series (first 16 bytes each).
            let samples = [(1, 1), (1, 3), (2, 1), (5, 1), (10, 1)]
            for (seasonNumber, episodeNumber) in samples {
                guard let other = detail.seasons.first(where: { $0.number == seasonNumber })?.episodes
                    .first(where: { $0.episodeNumber == episodeNumber }) else { continue }
                var sample = URLRequest(url: try client.episodeStreamURL(other), timeoutInterval: 20)
                sample.setValue("bytes=0-15", forHTTPHeaderField: "Range")
                let (body, answer) = try await URLSession.shared.data(for: sample)
                let http = answer as? HTTPURLResponse
                lines.append("media probe S\(seasonNumber)E\(episodeNumber): status=\(http?.statusCode ?? -1) "
                    + "type=\(http?.value(forHTTPHeaderField: "Content-Type") ?? "none") bytes=\(body.count) "
                    + "matroska=\(body.prefix(4) == Data([0x1a, 0x45, 0xdf, 0xa3]))")
            }
        } catch {
            lines.append("media probe: FAILED \(error)")
        }
    }


    static func run(source: ProviderSource, client: XtreamClient) async {
        var lines = ["Seyrileo provider probe", "Date: \(Date().ISO8601Format())", "Source kind: \(source.kind.rawValue)",
                     "Scheme: \(source.serverURL.scheme ?? "?")"]
        func timed<T>(_ label: String, _ body: () async throws -> T, describe: (T) -> String) async {
            let start = ContinuousClock.now
            do {
                let value = try await body()
                lines.append("\(label): OK \(describe(value)) (\(start.duration(to: .now).formatted(.units(allowed: [.milliseconds]))))")
            } catch {
                lines.append("\(label): FAILED \(error)")
            }
        }
        await timed("auth", { try await client.authenticate() }) { info in
            "status=\(info.status) expires=\(info.expiresAt?.formatted(date: .abbreviated, time: .omitted) ?? "unknown") "
                + "active=\(info.activeConnections.map(String.init) ?? "unknown") max=\(info.maxConnections.map(String.init) ?? "unknown") "
                + "formats=\(info.allowedOutputFormats) preferredLive=\(info.preferredLiveFormat.rawValue) "
                + "trial=\(info.isTrial.map { $0 ? "yes" : "no" } ?? "unknown") timezone=\(info.serverTimezone ?? "unknown")"
        }
        var firstCategory: String?
        await timed("live categories", { try await client.liveCategories() }) { page in
            firstCategory = page.items.first?.remoteID
            return "count=\(page.items.count) dropped=\(page.droppedCount)"
        }
        if let firstCategory {
            await timed("live streams (first category)", { try await client.liveStreams(categoryID: firstCategory) }) { page in
                "count=\(page.items.count) dropped=\(page.droppedCount) withEPGid=\(page.items.filter { $0.epgChannelID != nil }.count) "
                    + "advertisesArchive=\(page.items.filter(\.advertisesArchive).count)"
            }
        }
        // EPG availability (bounded: one full live list, short EPG for 3 channels, two day tables).
        let istanbul = TimeZone(identifier: "Europe/Istanbul") ?? .current
        let clock = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: istanbul)
        if let live = try? await client.liveStreams() {
            let withEPG = live.items.filter { $0.epgChannelID != nil }
            lines.append("live channels=\(live.items.count) withEPGid=\(withEPG.count)")
            let preferred = ["trt 1", "atv", "show", "kanal d", "star"]
            var picks: [LiveChannel] = []
            for name in preferred {
                if let match = live.items.first(where: { $0.name.lowercased().contains(name) && !picks.contains($0) }) { picks.append(match) }
                if picks.count == 3 { break }
            }
            let now = Date()
            for channel in picks {
                do {
                    let page = try await client.shortEPG(for: channel.key, limit: 4, serverTimeZone: istanbul)
                    let nowNext = NowNext(programs: page.programs, at: now)
                    let first = page.programs.first.map { "\($0.start.formatted(clock))–\($0.end.formatted(clock))" } ?? "-"
                    lines.append("short EPG \(channel.name) epgID=\(channel.epgChannelID ?? "none"): count=\(page.programs.count) dropped=\(page.droppedCount) first=\(first) now=\(nowNext.now?.title ?? "none") next=\(nowNext.next?.title ?? "none")")
                } catch {
                    lines.append("short EPG \(channel.name): FAILED \(error)")
                }
            }
            // Day tables: the first pick plus one sports channel (2 requests, sequential).
            var tables = Array(picks.prefix(1))
            if let sport = withEPG.first(where: { $0.name.lowercased().contains("trt spor") }) { tables.append(sport) }
            for channel in tables {
                do {
                    let page = try await client.fullEPG(for: channel.key, serverTimeZone: istanbul)
                    let span = page.programs.first.flatMap { first in page.programs.last.map { ($0.end.timeIntervalSince(first.start) / 3600).rounded() } } ?? 0
                    lines.append("day table \(channel.name): count=\(page.programs.count) dropped=\(page.droppedCount) spanHours=\(span)")
                    let calendar = Calendar.current
                    let perDay = Dictionary(grouping: page.programs) { calendar.startOfDay(for: $0.start) }
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key.formatted(.iso8601.year().month().day()))=\($0.value.count)" }
                    lines.append("day table days \(channel.name) (device zone): \(perDay.joined(separator: " ")) now=\(Date().formatted(.iso8601))")
                } catch {
                    lines.append("day table \(channel.name): FAILED \(error)")
                }
            }
        }
        for action in ["get_vod_categories", "get_series_categories"] {
            await timed(action, { try await client.probeList(action: action) }) { probe in
                "count=\(probe.itemCount) dropped=\(probe.droppedCount) bytes=\(probe.byteCount)"
            }
        }
        // Detail shape for a few films and series (catalogue requests only; no stream is opened).
        if let movies = try? await client.vodStreams() {
            for movie in movies.items.prefix(6) {
                await timed("vod info shape", { try await client.probeDetail(movie.key) }) { probe in
                    "keys=\(probe.infoKeys) external=\(probe.externalIDs)"
                }
            }
        }
        if let series = try? await client.seriesList() {
            for item in series.items.prefix(4) {
                await timed("series info shape", { try await client.probeDetail(item.key) }) { probe in
                    "keys=\(probe.infoKeys) external=\(probe.externalIDs)"
                }
            }
        }
        if let query = mediaQuery {
            await probeSeriesEpisode(query: query, client: client, into: &lines)
        }
        let host = source.serverURL.host ?? ""
        let redactor = client.redactor.adding([host])
        let text = redactor.redact(lines.joined(separator: "\n")) + "\n"
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("provider-probe.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
/// Stops at the first redirect so its status and target can be described.
private nonisolated final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
#endif
