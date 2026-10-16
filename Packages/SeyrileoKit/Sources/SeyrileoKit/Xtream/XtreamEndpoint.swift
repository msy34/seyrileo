import Foundation

/// Builds Xtream-style URLs from a user-entered server address.
///
/// Credentials end up in query strings (API) and in path segments (streams), so every
/// component is percent-encoded with the strict RFC 3986 unreserved set: `+`, `&`, `/`, `?`,
/// `#`, `%` and spaces in a password can never change the URL structure.
public struct XtreamEndpoint: Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case unsupportedScheme(String)
        case missingHost
        case containsUserInfo
        case malformed
    }

    /// scheme://host[:port][/base/path] with no trailing slash, query, fragment or user info.
    public let baseURL: URL

    public init(baseURL: URL) throws {
        self = try XtreamEndpoint(serverAddress: baseURL.absoluteString)
    }

    /// Accepts "example.com:8080", "https://example.com/base/", or a pasted
    /// ".../player_api.php" address. A missing scheme defaults to HTTPS.
    public init(serverAddress raw: String) throws {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ValidationError.empty }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text) else { throw ValidationError.malformed }
        guard let scheme = components.scheme?.lowercased() else { throw ValidationError.malformed }
        guard scheme == "http" || scheme == "https" else { throw ValidationError.unsupportedScheme(scheme) }
        guard let host = components.host, !host.isEmpty else { throw ValidationError.missingHost }
        guard components.user == nil, components.password == nil else { throw ValidationError.containsUserInfo }

        components.scheme = scheme
        components.host = host.lowercased()
        components.query = nil
        components.fragment = nil
        var path = components.path
        for suffix in ["/player_api.php", "/get.php", "/xmltv.php", "/panel_api.php"]
        where path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        guard let url = components.url else { throw ValidationError.malformed }
        self.baseURL = url
    }

    public var usesHTTPS: Bool { baseURL.scheme == "https" }

    public func apiURL(credentials: XtreamCredentials, action: String? = nil, parameters: [(String, String)] = []) -> URL {
        var items = [("username", credentials.username), ("password", credentials.password)]
        if let action { items.append(("action", action)) }
        items.append(contentsOf: parameters)
        let query = items.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        return Self.join(baseURL, path: "player_api.php", query: query)
    }

    public func liveStreamURL(credentials: XtreamCredentials, streamID: String, format: StreamFormat) -> URL {
        let path = ["live", credentials.username, credentials.password, "\(streamID).\(format.rawValue)"]
            .map(Self.encode)
            .joined(separator: "/")
        return Self.join(baseURL, path: path, query: nil)
    }

    /// `{base}/movie/{user}/{pass}/{id}.{ext}` with the provider-reported container.
    public func movieStreamURL(credentials: XtreamCredentials, streamID: String, containerExtension: String) -> URL {
        mediaURL(kind: "movie", credentials: credentials, id: streamID, containerExtension: containerExtension)
    }

    /// `{base}/series/{user}/{pass}/{episodeID}.{ext}` with the provider-reported container.
    public func episodeStreamURL(credentials: XtreamCredentials, episodeID: String, containerExtension: String) -> URL {
        mediaURL(kind: "series", credentials: credentials, id: episodeID, containerExtension: containerExtension)
    }

    private func mediaURL(kind: String, credentials: XtreamCredentials, id: String, containerExtension: String) -> URL {
        let path = [kind, credentials.username, credentials.password, "\(id).\(containerExtension)"]
            .map(Self.encode)
            .joined(separator: "/")
        return Self.join(baseURL, path: path, query: nil)
    }

    static func join(_ base: URL, path: String, query: String?) -> URL {
        var string = base.absoluteString + "/" + path
        if let query { string += "?" + query }
        // Every dynamic component is already percent-encoded, so this cannot fail for a valid base.
        return URL(string: string)!
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

/// Recognizes common pasted provider links (`get.php?username=…&password=…&type=m3u`, or
/// `player_api.php?username=…`) and splits them into separate fields so the user never has
/// to keep credentials inside a URL.
public struct XtreamLinkParser {
    public struct Result: Equatable, Sendable {
        public let serverAddress: String
        public let username: String?
        public let password: String?
    }

    public static func parse(_ text: String) -> Result? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let items = components.queryItems, !items.isEmpty,
              let username = items.first(where: { $0.name == "username" })?.value
        else { return nil }
        let password = items.first(where: { $0.name == "password" })?.value
        var base = components
        base.query = nil
        base.fragment = nil
        guard let endpoint = try? XtreamEndpoint(serverAddress: base.string ?? "") else { return nil }
        return Result(serverAddress: endpoint.baseURL.absoluteString, username: username, password: password)
    }
}
