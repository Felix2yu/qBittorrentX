import Foundation

/// `sync/maindata` 里 torrents 的两种形态。全量直接解成 Torrent（实测比建 JSONValue 树快 15.6×），
/// 增量保留原始 JSON 以便先合并再解码。
public enum TorrentPayload: Sendable {
    case full([String: Torrent])
    case patch([String: JSONValue])

    public var count: Int {
        switch self {
        case .full(let t): t.count
        case .patch(let p): p.count
        }
    }
}

/// `sync/maindata` 的响应。server_state / categories 也是增量的，保留原始 JSON；
/// 它们只有几条到几十条，建树开销可忽略。
public struct Maindata: Sendable {
    public var rid: Int
    /// 实测：增量响应里 `full_update` 键**直接缺失**（不是 false），所以默认 false。
    public var fullUpdate: Bool
    public var torrents: TorrentPayload
    public var torrentsRemoved: [String]
    public var serverState: JSONValue?
    public var categories: [String: JSONValue]
    public var categoriesRemoved: [String]
    public var tags: [String]
    public var tagsRemoved: [String]
    /// tracker URL → 该 tracker 下的任务 hash 列表。
    public var trackers: [String: [String]]

    public init(
        rid: Int = 0, fullUpdate: Bool = false, torrents: TorrentPayload = .patch([:]),
        torrentsRemoved: [String] = [], serverState: JSONValue? = nil,
        categories: [String: JSONValue] = [:], categoriesRemoved: [String] = [],
        tags: [String] = [], tagsRemoved: [String] = [], trackers: [String: [String]] = [:]
    ) {
        self.rid = rid
        self.fullUpdate = fullUpdate
        self.torrents = torrents
        self.torrentsRemoved = torrentsRemoved
        self.serverState = serverState
        self.categories = categories
        self.categoriesRemoved = categoriesRemoved
        self.tags = tags
        self.tagsRemoved = tagsRemoved
        self.trackers = trackers
    }
}

extension Maindata: Decodable {
    enum CodingKeys: String, CodingKey {
        case rid
        case fullUpdate = "full_update"
        case torrents
        case torrentsRemoved = "torrents_removed"
        case serverState = "server_state"
        case categories
        case categoriesRemoved = "categories_removed"
        case tags
        case tagsRemoved = "tags_removed"
        case trackers
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rid = try c.decodeIfPresent(Int.self, forKey: .rid) ?? 0
        fullUpdate = try c.decodeIfPresent(Bool.self, forKey: .fullUpdate) ?? false
        // 先读 full_update 再决定 torrents 的解码形态：全量走快路径，增量留原始 JSON。
        if fullUpdate {
            let list = try c.decodeIfPresent([String: Torrent].self, forKey: .torrents) ?? [:]
            torrents = .full(TorrentMerger.injectHash(list))
        } else {
            torrents = .patch(try c.decodeIfPresent([String: JSONValue].self, forKey: .torrents) ?? [:])
        }
        torrentsRemoved = try c.decodeIfPresent([String].self, forKey: .torrentsRemoved) ?? []
        serverState = try c.decodeIfPresent(JSONValue.self, forKey: .serverState)
        categories = try c.decodeIfPresent([String: JSONValue].self, forKey: .categories) ?? [:]
        categoriesRemoved = try c.decodeIfPresent([String].self, forKey: .categoriesRemoved) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        tagsRemoved = try c.decodeIfPresent([String].self, forKey: .tagsRemoved) ?? []
        trackers = try c.decodeIfPresent([String: [String]].self, forKey: .trackers) ?? [:]
    }
}