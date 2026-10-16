import Foundation

/// Provider adapter for Xtream-compatible `/player_api.php` sources.
///
/// The "API" is a de-facto convention, not a formal standard; behavior here is based on
/// observed responses and must be validated against each real, authorized provider.
public struct XtreamClient: Sendable {
    public struct Limits: Sendable {
        public var authBytes = 1 * 1024 * 1024
        public var categoriesBytes = 4 * 1024 * 1024
        public var streamsBytes = 64 * 1024 * 1024
        public init() {}
    }

    public let providerID: UUID
    public let endpoint: XtreamEndpoint
    let credentials: XtreamCredentials
    private let transport: HTTPTransport
    private let retryPolicy: RetryPolicy
    private let sleeper: Sleeper
    private let limits: Limits

    public init(
        providerID: UUID, endpoint: XtreamEndpoint, credentials: XtreamCredentials, transport: HTTPTransport,
        retryPolicy: RetryPolicy = RetryPolicy(), sleeper: @escaping Sleeper = RetryPolicy.taskSleeper,
        limits: Limits = Limits()
    ) {
        self.providerID = providerID
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
        self.limits = limits
    }

    public var redactor: Redactor { Redactor(secrets: credentials.secrets) }

    /// Verifies credentials. Throws `.authenticationRejected` only when the provider
    /// explicitly says `auth: 0`; returns advisory account state otherwise.
    public func authenticate() async throws -> AccountInfo {
        let data = try await fetch(endpoint.apiURL(credentials: credentials), maxBytes: limits.authBytes)
        let envelope: AuthEnvelopeDTO
        do {
            envelope = try JSONDecoder().decode(AuthEnvelopeDTO.self, from: data)
        } catch {
            if Self.isJSONArrayOrScalar(data) { throw XtreamError.unexpectedShape("auth: expected object") }
            throw XtreamError.malformedJSON
        }
        guard let info = envelope.userInfo else { throw XtreamError.unexpectedShape("auth: missing user_info") }
        guard info.auth == 1 else { throw XtreamError.authenticationRejected }
        return AccountInfo(
            status: .init(raw: info.status),
            expiresAt: info.expDate.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            isTrial: info.isTrial,
            activeConnections: info.activeConnections,
            maxConnections: info.maxConnections,
            allowedOutputFormats: info.allowedOutputFormats,
            serverTimezone: envelope.serverInfo?.timezone,
            message: info.message.flatMap { $0.isEmpty ? nil : $0 })
    }

    public func liveCategories() async throws -> CatalogPage<LiveCategory> {
        let data = try await fetch(
            endpoint.apiURL(credentials: credentials, action: "get_live_categories"), maxBytes: limits.categoriesBytes)
        let list = try Self.decodeList(CategoryDTO.self, from: data)
        return CatalogPage(
            items: list.elements.map {
                LiveCategory(providerID: providerID, remoteID: $0.id, name: $0.name)
            },
            droppedCount: list.droppedCount)
    }

    /// Fetches live streams, optionally for one category. Providers generally do not paginate;
    /// callers should request per category to keep responses bounded.
    public func liveStreams(categoryID: String? = nil) async throws -> CatalogPage<LiveChannel> {
        let parameters = categoryID.map { [("category_id", $0)] } ?? []
        let data = try await fetch(
            endpoint.apiURL(credentials: credentials, action: "get_live_streams", parameters: parameters),
            maxBytes: limits.streamsBytes)
        let list = try Self.decodeList(LiveStreamDTO.self, from: data)
        let channels = list.elements.map { dto in
            LiveChannel(
                key: MediaKey(providerID: providerID, kind: .live, remoteID: dto.streamID),
                name: dto.name,
                number: dto.number,
                categoryIDs: dto.categoryIDs.isEmpty ? dto.categoryID.map { [$0] } ?? [] : dto.categoryIDs,
                iconURL: dto.icon.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                epgChannelID: dto.epgChannelID,
                advertisesArchive: dto.tvArchive ?? false)
        }
        return CatalogPage(items: channels, droppedCount: list.droppedCount)
    }

    /// Credential-bearing stream URL. Treat as a secret: never log or persist it.
    public func liveStreamURL(for channel: LiveChannel, format: StreamFormat) -> URL {
        endpoint.liveStreamURL(credentials: credentials, streamID: channel.key.remoteID, format: format)
    }

    // MARK: - Internals

    /// Detail endpoints return a JSON object; a list-shaped or empty answer means "not found".
    func fetchObject(action: String, parameters: [(String, String)]) async throws -> Data {
        let data = try await fetch(
            endpoint.apiURL(credentials: credentials, action: action, parameters: parameters), maxBytes: limits.categoriesBytes)
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw XtreamError.malformedJSON
        }
        guard let dictionary = object as? [String: Any], !dictionary.isEmpty else {
            throw XtreamError.unexpectedShape("detail: not an object")
        }
        return data
    }

    func fetchList(action: String) async throws -> Data {
        try await fetch(endpoint.apiURL(credentials: credentials, action: action), maxBytes: limits.streamsBytes)
    }

    func fetchList(action: String, parameters: [(String, String)], maxBytes: Int) async throws -> Data {
        try await fetch(endpoint.apiURL(credentials: credentials, action: action, parameters: parameters), maxBytes: maxBytes)
    }

    private func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        let response = try await retryPolicy.run(
            sleeper: sleeper,
            isTransient: { ($0 as? XtreamError)?.isTransient ?? false }
        ) {
            let response = try await transport.get(url, maxBytes: maxBytes)
            guard (200..<300).contains(response.statusCode) else { throw XtreamError.httpStatus(response.statusCode) }
            return response
        }
        return try Self.validateBody(response)
    }

    static func validateBody(_ response: HTTPResponse) throws -> Data {
        let body = response.body
        guard let first = body.first(where: { !Self.isWhitespace($0) }) else { throw XtreamError.emptyResponse }
        if response.contentType?.lowercased().contains("text/html") == true || first == UInt8(ascii: "<") {
            throw XtreamError.htmlInsteadOfJSON
        }
        return body
    }

    /// Accepts a JSON array, or an empty object/`null`/`false` that some panels return for
    /// an empty list. Anything else is an unexpected shape rather than an empty catalogue.
    static func decodeList<T: Decodable>(_ type: T.Type, from data: Data) throws -> LossyArray<T> {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw XtreamError.malformedJSON
        }
        switch object {
        case is [Any]:
            do { return try JSONDecoder().decode(LossyArray<T>.self, from: data) } catch { throw XtreamError.malformedJSON }
        case let dictionary as [String: Any] where dictionary.isEmpty:
            return try JSONDecoder().decode(LossyArray<T>.self, from: Data("[]".utf8))
        case is NSNull:
            return try JSONDecoder().decode(LossyArray<T>.self, from: Data("[]".utf8))
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID() && !number.boolValue:
            return try JSONDecoder().decode(LossyArray<T>.self, from: Data("[]".utf8))
        default:
            throw XtreamError.unexpectedShape("expected list")
        }
    }

    private static func isJSONArrayOrScalar(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return false }
        return !(object is [String: Any])
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0xEF || byte == 0xBB || byte == 0xBF
    }
}
