import Foundation

/// Provider-reported account state. Every field is advisory: providers omit, mistype or
/// misreport them, so `nil` means "unknown", never "unlimited" or "fine".
public struct AccountInfo: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case active
        case expired
        case banned
        case disabled
        case unknown(String?)

        init(raw: String?) {
            switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "active": self = .active
            case "expired": self = .expired
            case "banned": self = .banned
            case "disabled": self = .disabled
            default: self = .unknown(raw)
            }
        }

        /// The provider explicitly reported a state in which playback is expected to fail.
        public var blocksPlayback: Bool {
            switch self {
            case .expired, .banned, .disabled: true
            case .active, .unknown: false
            }
        }
    }

    public var status: Status
    public var expiresAt: Date?
    public var isTrial: Bool?
    public var activeConnections: Int?
    public var maxConnections: Int?
    /// e.g. ["m3u8", "ts"]. Empty means the provider did not say.
    public var allowedOutputFormats: [String]
    public var serverTimezone: String?
    public var message: String?

    public init(
        status: Status, expiresAt: Date? = nil, isTrial: Bool? = nil, activeConnections: Int? = nil,
        maxConnections: Int? = nil, allowedOutputFormats: [String] = [], serverTimezone: String? = nil,
        message: String? = nil
    ) {
        self.status = status
        self.expiresAt = expiresAt
        self.isTrial = isTrial
        self.activeConnections = activeConnections
        self.maxConnections = maxConnections
        self.allowedOutputFormats = allowedOutputFormats
        self.serverTimezone = serverTimezone
        self.message = message
    }

    public func isPastExpiry(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// Preferred live output format: HLS when the provider allows it or does not say,
    /// MPEG-TS only when it is the sole advertised option.
    public var preferredLiveFormat: StreamFormat {
        let formats = Set(allowedOutputFormats.map { $0.lowercased() })
        if formats.isEmpty || formats.contains(StreamFormat.hls.rawValue) { return .hls }
        if formats.contains(StreamFormat.mpegts.rawValue) { return .mpegts }
        return .hls
    }
}
