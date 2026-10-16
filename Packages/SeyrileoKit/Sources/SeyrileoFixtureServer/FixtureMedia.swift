import Foundation

/// Bundled synthetic media plus live HLS playlist generation.
struct FixtureMedia: @unchecked Sendable {
    struct Loop {
        let segments: [Data]
        let durations: [Double]
        var total: Double { durations.reduce(0, +) }
    }

    let loops: [String: Loop]
    let rawTS: Data
    let featureMP4: Data
    let shortMKV: Data

    static let windowSize = 4

    init?(bundle: Bundle) {
        guard let root = bundle.url(forResource: "Media", withExtension: nil) else { return nil }
        var loops: [String: Loop] = [:]
        for directory in ["pattern-a", "pattern-b", "pattern-mp2"] {
            let folder = root.appendingPathComponent(directory)
            guard let durationsText = try? String(contentsOf: folder.appendingPathComponent("durations.txt"), encoding: .utf8)
            else { return nil }
            let durations = durationsText.split(whereSeparator: \.isNewline).compactMap { Double($0) }
            var segments: [Data] = []
            for index in durations.indices {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("seg\(index).ts")) else { return nil }
                segments.append(data)
            }
            guard !segments.isEmpty else { return nil }
            loops[directory] = Loop(segments: segments, durations: durations)
        }
        guard let raw = try? Data(contentsOf: root.appendingPathComponent("raw-pattern-a.ts")),
              let mp4 = try? Data(contentsOf: root.appendingPathComponent("vod/feature.mp4")),
              let mkv = try? Data(contentsOf: root.appendingPathComponent("vod/short.mkv"))
        else { return nil }
        self.loops = loops
        self.rawTS = raw
        self.featureMP4 = mp4
        self.shortMKV = mkv
    }

    func segment(directory: String, file: String) -> Data? {
        guard let loop = loops[directory], file.hasPrefix("seg"), file.hasSuffix(".ts"),
              let index = Int(file.dropFirst(3).dropLast(3)), loop.segments.indices.contains(index)
        else { return nil }
        return loop.segments[index]
    }

    /// A live (no ENDLIST) sliding-window playlist that loops the bundled segments forever,
    /// with discontinuity markers where the loop restarts its timestamps.
    func livePlaylist(directory: String, now: Date) -> String? {
        guard let loop = loops[directory] else { return nil }
        return Self.livePlaylist(durations: loop.durations, directory: directory, time: now.timeIntervalSince1970)
    }

    static func livePlaylist(durations: [Double], directory: String, time: TimeInterval) -> String {
        let count = durations.count
        let total = durations.reduce(0, +)
        let cycles = Int(floor(time / total))
        var within = time - Double(cycles) * total
        var index = 0
        while index < count - 1 && within >= durations[index] {
            within -= durations[index]
            index += 1
        }
        let latest = cycles * count + index
        let first = max(0, latest - windowSize + 1)
        let discontinuitySequence = first >= 1 ? (first - 1) / count : 0
        let target = Int(ceil(durations.max() ?? 2))

        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:\(first)",
            "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)",
        ]
        for sequence in first...latest {
            let segmentIndex = sequence % count
            if segmentIndex == 0 && sequence > 0 { lines.append("#EXT-X-DISCONTINUITY") }
            lines.append(String(format: "#EXTINF:%.6f,", durations[segmentIndex]))
            lines.append("/fixture-media/\(directory)/seg\(segmentIndex).ts")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Bytes that look like a transport stream packet header but carry no decodable media.
    static let corruptSegment: Data = {
        var bytes = [UInt8](repeating: 0, count: 188 * 64)
        for packet in 0..<64 {
            bytes[packet * 188] = 0x47
            for offset in 1..<188 { bytes[packet * 188 + offset] = UInt8(truncatingIfNeeded: packet &* 31 &+ offset &* 7) }
        }
        return Data(bytes)
    }()
}
