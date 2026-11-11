import Foundation

/// 一条任务。纯值类型，跨 actor 传递无需额外同步。
///
/// 用显式 CodingKeys 而不是 `.convertFromSnakeCase`：真实字段是 `private`（Swift 关键字），
/// 而 `Category.savePath` 又是 camelCase，全局 snake 策略会解错。
/// 所有字段走 `decodeIfPresent` + 默认值：这是外部 API 边界，trackerless 种子确实缺 `tracker`，
/// 且 qB 各版本字段有增减（5.3 比 wiki 多约 20 个键，未建模的由 JSONDecoder 自动忽略）。
public struct Torrent: Identifiable, Hashable, Sendable, Codable {
    public var id: String { hash }

    /// maindata 的 torrents 字典里**没有** hash 字段，由 SyncEngine 用字典 key 注入。
    public var hash: String
    public var name: String
    public var state: TorrentState
    public var progress: Double
    public var size: Int64
    public var downloaded: Int64
    public var uploaded: Int64
    public var dlspeed: Int64
    public var upspeed: Int64
    public var eta: Int64
    public var ratio: Double
    public var numSeeds: Int
    public var numLeechs: Int
    public var category: String
    /// qB 返回逗号分隔字符串，不是数组。
    public var tagsRaw: String
    public var savePath: String
    public var contentPath: String
    public var addedOn: Int64
    /// 5.x 叫 completion_on（4.x 是 completed_on）；0 表示尚未完成。
    public var completionOn: Int64
    public var lastActivity: Int64
    public var tracker: String
    public var amountLeft: Int64
    public var availability: Double
    public var isPrivate: Bool
    public var dlLimit: Int64
    public var upLimit: Int64

    public init(
        hash: String = "", name: String = "", state: TorrentState = .unknown(""),
        progress: Double = 0, size: Int64 = 0, downloaded: Int64 = 0, uploaded: Int64 = 0,
        dlspeed: Int64 = 0, upspeed: Int64 = 0, eta: Int64 = Self.etaUnknown, ratio: Double = 0,
        numSeeds: Int = 0, numLeechs: Int = 0, category: String = "", tagsRaw: String = "",
        savePath: String = "", contentPath: String = "", addedOn: Int64 = 0,
        completionOn: Int64 = 0, lastActivity: Int64 = 0, tracker: String = "",
        amountLeft: Int64 = 0, availability: Double = 0, isPrivate: Bool = false,
        dlLimit: Int64 = -1, upLimit: Int64 = -1
    ) {
        self.hash = hash
        self.name = name
        self.state = state
        self.progress = progress
        self.size = size
        self.downloaded = downloaded
        self.uploaded = uploaded
        self.dlspeed = dlspeed
        self.upspeed = upspeed
        self.eta = eta
        self.ratio = ratio
        self.numSeeds = numSeeds
        self.numLeechs = numLeechs
        self.category = category
        self.tagsRaw = tagsRaw
        self.savePath = savePath
        self.contentPath = contentPath
        self.addedOn = addedOn
        self.completionOn = completionOn
        self.lastActivity = lastActivity
        self.tracker = tracker
        self.amountLeft = amountLeft
        self.availability = availability
        self.isPrivate = isPrivate
        self.dlLimit = dlLimit
        self.upLimit = upLimit
    }

    /// qB 用 8640000 秒（100 天）表示「剩余时间未知」。
    public static let etaUnknown: Int64 = 8_640_000

    public var tags: [String] {
        tagsRaw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public var trackerHost: String {
        guard !tracker.isEmpty, let host = URL(string: tracker)?.host, !host.isEmpty else { return "" }
        return host
    }

    // MARK: - 排序键

    /// 空分类/空标签要排在最后而不是最前，用一个高位码点占位。
    private static let sortsLast = "\u{10FFFF}"

    public var stateRank: Int { state.rank }
    public var categoryKey: String { category.isEmpty ? Self.sortsLast : category }
    public var tagsKey: String { tags.first ?? Self.sortsLast }
    /// 不映射哨兵的话「未知」会混在正常 ETA 中间。
    public var etaKey: Int64 { eta >= Self.etaUnknown ? Int64.max : eta }

    enum CodingKeys: String, CodingKey {
        case hash, name, state, progress, size, downloaded, uploaded, dlspeed, upspeed
        case eta, ratio, category, tracker, availability
        case numSeeds = "num_seeds"
        case numLeechs = "num_leechs"
        case tagsRaw = "tags"
        case savePath = "save_path"
        case contentPath = "content_path"
        case addedOn = "added_on"
        case completionOn = "completion_on"
        case lastActivity = "last_activity"
        case amountLeft = "amount_left"
        case isPrivate = "private"
        case dlLimit = "dl_limit"
        case upLimit = "up_limit"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = try c.decodeIfPresent(String.self, forKey: .hash) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        state = TorrentState(rawValue: try c.decodeIfPresent(String.self, forKey: .state) ?? "")
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        downloaded = try c.decodeIfPresent(Int64.self, forKey: .downloaded) ?? 0
        uploaded = try c.decodeIfPresent(Int64.self, forKey: .uploaded) ?? 0
        dlspeed = try c.decodeIfPresent(Int64.self, forKey: .dlspeed) ?? 0
        upspeed = try c.decodeIfPresent(Int64.self, forKey: .upspeed) ?? 0
        eta = try c.decodeIfPresent(Int64.self, forKey: .eta) ?? Self.etaUnknown
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0
        numSeeds = try c.decodeIfPresent(Int.self, forKey: .numSeeds) ?? 0
        numLeechs = try c.decodeIfPresent(Int.self, forKey: .numLeechs) ?? 0
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        tagsRaw = try c.decodeIfPresent(String.self, forKey: .tagsRaw) ?? ""
        savePath = try c.decodeIfPresent(String.self, forKey: .savePath) ?? ""
        contentPath = try c.decodeIfPresent(String.self, forKey: .contentPath) ?? ""
        addedOn = try c.decodeIfPresent(Int64.self, forKey: .addedOn) ?? 0
        completionOn = try c.decodeIfPresent(Int64.self, forKey: .completionOn) ?? 0
        lastActivity = try c.decodeIfPresent(Int64.self, forKey: .lastActivity) ?? 0
        tracker = try c.decodeIfPresent(String.self, forKey: .tracker) ?? ""
        amountLeft = try c.decodeIfPresent(Int64.self, forKey: .amountLeft) ?? 0
        availability = try c.decodeIfPresent(Double.self, forKey: .availability) ?? 0
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        dlLimit = try c.decodeIfPresent(Int64.self, forKey: .dlLimit) ?? -1
        upLimit = try c.decodeIfPresent(Int64.self, forKey: .upLimit) ?? -1
    }
}