import Foundation

/// Synthetic provider JSON. Types vary on purpose (numbers vs numeric strings, nulls, one
/// entry without `stream_id`) to mirror the inconsistencies of real Xtream-compatible panels.
enum FixtureCatalog {
    static func authJSON(username: String, status: String, port: UInt16) -> String {
        """
        {"user_info":{"username":"\(username)","auth":1,"status":"\(status)","exp_date":"1924992000",\
        "is_trial":"0","active_cons":"0","created_at":"1767225600","max_connections":"1",\
        "allowed_output_formats":["m3u8","ts"],"message":"Seyrileo fixture provider"},\
        "server_info":{"url":"localhost","port":"\(port)","https_port":"","server_protocol":"http",\
        "rtmp_port":"","timezone":"Europe/Istanbul","timestamp_now":1767225600,"time_now":"2026-01-01 00:00:00"}}
        """
    }

    static let liveCategoriesJSON = """
        [{"category_id":"1","category_name":"Fixture · Pattern Lab","parent_id":0},\
        {"category_id":2,"category_name":"Fixture · Diagnostics Lab","parent_id":0},\
        {"category_name":"Broken entry without id"}]
        """

    private static let streams: [(category: String, json: String)] = [
        ("1", #"{"num":1,"name":"Pattern A (HLS)","stream_type":"live","stream_id":101,"stream_icon":"","epg_channel_id":null,"category_id":"1","category_ids":[1],"tv_archive":0}"#),
        ("1", #"{"num":"2","name":"Pattern B (HLS)","stream_type":"live","stream_id":"102","stream_icon":null,"epg_channel_id":"pattern.b","category_id":1,"tv_archive":"0"}"#),
        ("2", #"{"num":3,"name":"MPEG-TS only","stream_type":"live","stream_id":201,"category_id":"2","category_ids":["2"]}"#),
        ("2", #"{"num":4,"name":"Offline stream (404)","stream_type":"live","stream_id":202,"category_id":"2"}"#),
        ("2", #"{"num":5,"name":"Access denied (403)","stream_type":"live","stream_id":203,"category_id":"2"}"#),
        ("2", #"{"num":6,"name":"Corrupt media","stream_type":"live","stream_id":204,"category_id":"2"}"#),
        ("2", #"{"num":7,"name":"Entry without stream id","stream_type":"live","category_id":"2"}"#),
        ("2", #"{"num":8,"name":"MP2 audio (HLS)","stream_type":"live","stream_id":205,"category_id":"2"}"#),
    ]

    static func liveStreamsJSON(categoryID: String?) -> String {
        let selected = streams.filter { categoryID == nil || $0.category == categoryID }
        return "[" + selected.map(\.json).joined(separator: ",") + "]"
    }

    // MARK: - Movies and series (Milestone 3). Synthetic titles; no real works.

    static let vodCategoriesJSON = #"[{"category_id":"10","category_name":"Fixture · Films","parent_id":0}]"#

    static let vodStreamsJSON = """
        [{"num":1,"name":"Test Film A","stream_type":"movie","stream_id":301,"stream_icon":"","rating":"7.5","added":"1767225600","category_id":"10","container_extension":"mp4"},\
        {"num":2,"name":"Test Film MKV","stream_type":"movie","stream_id":"302","rating":"","added":1767225600,"category_id":10,"container_extension":"mkv"},\
        {"num":3,"name":"Test Film (no container)","stream_type":"movie","stream_id":303,"category_id":"10"},\
        {"num":4,"name":"Entry without stream id","category_id":"10"}]
        """

    static func vodInfoJSON(id: String) -> String {
        switch id {
        case "301":
            return #"{"info":{"name":"Test Film A","plot":"A synthetic colour-bar film used to test playback and resume.","genre":"Test","cast":"","director":"Seyrileo","releasedate":"2026-01-01","duration_secs":"180","rating":"7.5"},"movie_data":{"stream_id":301,"name":"Test Film A","container_extension":"mp4"}}"#
        case "302":
            return #"{"info":{"name":"Test Film MKV","duration_secs":10},"movie_data":{"stream_id":"302","container_extension":"mkv"}}"#
        case "303":
            return #"{"info":[],"movie_data":{"stream_id":303}}"#
        default:
            return "[]"
        }
    }

    static let seriesCategoriesJSON = #"[{"category_id":"20","category_name":"Fixture · Series","parent_id":0}]"#

    static let seriesJSON = """
        [{"num":1,"name":"Test Dizi","series_id":401,"cover":"","plot":"Synthetic series with two seasons.","genre":"Test","releaseDate":"2026-01-01","rating":"8","category_id":"20"},\
        {"num":2,"name":"Empty Series","series_id":"402","category_id":20}]
        """

    static func seriesInfoJSON(id: String) -> String {
        switch id {
        case "401":
            return """
                {"seasons":[{"season_number":1,"name":"Season 1"},{"season_number":"2","name":"Season 2"}],\
                "info":{"name":"Test Dizi","plot":"Synthetic series with two seasons.","genre":"Test","rating":"8"},\
                "episodes":{"2":[{"id":"503","episode_num":1,"title":"S2 E1","container_extension":"mp4","season":2,"info":{"duration_secs":180}}],\
                "1":[{"id":"502","episode_num":"2","title":"S1 E2","container_extension":"mp4","season":1,"info":{"duration_secs":"180"}},\
                {"id":501,"episode_num":1,"title":"S1 E1","container_extension":"mp4","season":"1","info":[]},\
                {"episode_num":3,"title":"Episode without id"}]}}
                """
        case "402":
            return #"{"seasons":[],"info":[],"episodes":[]}"#
        default:
            return "[]"
        }
    }
}
