import Foundation

/// A user-added provider source. Contains no secrets: credentials live in the Keychain
/// (see `CredentialStore`) keyed by `id`.
public struct ProviderSource: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case xtream
        /// Deterministic local fixture provider. Always labeled in the UI; never a real account.
        case fixture
    }

    public let id: UUID
    public var name: String
    public var kind: Kind
    /// Normalized base URL (scheme, host, optional port and base path; no query, fragment or user info).
    public var serverURL: URL
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, kind: Kind, serverURL: URL, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.serverURL = serverURL
        self.createdAt = createdAt
    }

    public var isFixture: Bool { kind == .fixture }

    /// `createdAt` is persisted as seconds since 1970 (a `Double`), which can lose sub-millisecond
    /// precision on a round trip; equality therefore compares it to the millisecond.
    public static func == (lhs: ProviderSource, rhs: ProviderSource) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.kind == rhs.kind && lhs.serverURL == rhs.serverURL
            && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 0.001
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Provider credentials. These are the provider's account details, not a Seyrileo account.
/// Description and reflection are redacted so accidental logging cannot print them.
public struct XtreamCredentials: Codable, Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var description: String { "XtreamCredentials(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// Values that must never appear in logs, errors or exported diagnostics.
    public var secrets: [String] { [username, password] }
}
