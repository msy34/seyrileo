import Foundation

// Provider DTOs. These never leave the Xtream adapter; the rest of the app sees domain models.

struct UserInfoDTO: Decodable {
    let auth: Int?
    let status: String?
    let expDate: Int?
    let isTrial: Bool?
    let activeConnections: Int?
    let maxConnections: Int?
    let allowedOutputFormats: [String]
    let message: String?

    enum CodingKeys: String, CodingKey {
        case auth, status, message
        case expDate = "exp_date"
        case isTrial = "is_trial"
        case activeConnections = "active_cons"
        case maxConnections = "max_connections"
        case allowedOutputFormats = "allowed_output_formats"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        auth = c.lenientInt(.auth)
        status = c.lenientString(.status)
        expDate = c.lenientInt(.expDate)
        isTrial = c.lenientBool(.isTrial)
        activeConnections = c.lenientInt(.activeConnections)
        maxConnections = c.lenientInt(.maxConnections)
        allowedOutputFormats = c.lenientStringArray(.allowedOutputFormats)
        message = c.lenientString(.message)
    }
}

struct ServerInfoDTO: Decodable {
    let timezone: String?

    enum CodingKeys: String, CodingKey { case timezone }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timezone = c.lenientString(.timezone)
    }
}

struct AuthEnvelopeDTO: Decodable {
    let userInfo: UserInfoDTO?
    let serverInfo: ServerInfoDTO?

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userInfo = try? c.decodeIfPresent(UserInfoDTO.self, forKey: .userInfo)
        // server_info is informational only; its host/port are never used for requests.
        serverInfo = try? c.decodeIfPresent(ServerInfoDTO.self, forKey: .serverInfo)
    }
}

struct CategoryDTO: Decodable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case name = "category_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(.id), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "category_id"))
        }
        self.id = id
        self.name = c.lenientString(.name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct LiveStreamDTO: Decodable {
    let streamID: String
    let name: String
    let number: Int?
    let categoryID: String?
    let categoryIDs: [String]
    let icon: String?
    let epgChannelID: String?
    let tvArchive: Bool?

    enum CodingKeys: String, CodingKey {
        case name, num
        case streamID = "stream_id"
        case categoryID = "category_id"
        case categoryIDs = "category_ids"
        case icon = "stream_icon"
        case epgChannelID = "epg_channel_id"
        case tvArchive = "tv_archive"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(.streamID), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.streamID, .init(codingPath: c.codingPath, debugDescription: "stream_id"))
        }
        streamID = id
        name = c.lenientString(.name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        number = c.lenientInt(.num)
        categoryID = c.lenientString(.categoryID)
        categoryIDs = c.lenientStringArray(.categoryIDs)
        icon = c.lenientString(.icon)
        epgChannelID = c.lenientString(.epgChannelID).flatMap { $0.isEmpty ? nil : $0 }
        tvArchive = c.lenientBool(.tvArchive)
    }
}
