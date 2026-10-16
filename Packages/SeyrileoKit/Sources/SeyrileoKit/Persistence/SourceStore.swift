import Foundation

public protocol SourceStore: Sendable {
    func loadSources() throws -> [ProviderSource]
    func saveSources(_ sources: [ProviderSource]) throws
}

/// Persists source configuration (never credentials) as a versioned JSON document,
/// written atomically with file protection. The catalogue database arrives in Milestone 2.
public struct FileSourceStore: SourceStore {
    struct Document: Codable {
        static let currentVersion = 1
        var schemaVersion: Int
        var sources: [ProviderSource]
    }

    public enum StoreError: Error, Equatable, Sendable {
        /// Written by a newer app version; refuse to overwrite it.
        case unsupportedSchemaVersion(Int)
    }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Application Support/Sources/sources.json. Brand-neutral on purpose.
    public static func defaultLocation() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("Sources", isDirectory: true).appendingPathComponent("sources.json")
    }

    public func loadSources() throws -> [ProviderSource] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let document = try decoder.decode(Document.self, from: data)
        guard document.schemaVersion <= Document.currentVersion else {
            throw StoreError.unsupportedSchemaVersion(document.schemaVersion)
        }
        return document.sources
    }

    public func saveSources(_ sources: [ProviderSource]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(Document(schemaVersion: Document.currentVersion, sources: sources))
        #if os(iOS) || os(tvOS) || os(visionOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: [.atomic])
        #endif
    }

    private var encoder: JSONEncoder {
        // Default (reference-date seconds) date strategy: lossless round trip, unlike ISO-8601.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        JSONDecoder()
    }
}
