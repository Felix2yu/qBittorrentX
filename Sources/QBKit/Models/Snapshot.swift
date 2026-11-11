import Foundation

public enum SyncMode: String, Hashable, Sendable, Codable {
    /// sync/maindata 增量，可见全部任务。需要账号密码登录（rid 绑定 cookie 会话）。
    case full
    /// 只跟运行中任务，永不请求全量。
    case lite

    public var displayName: String {
        switch self {
        case .full: "完整"
        case .lite: "省流量"
        }
    }
}

/// 各筛选维度的计数。用**全局计数**（对完整快照一次遍历），不做「排除自身维度」的
/// faceted 计数：qB WebUI 就是全局计数，用户预期一致，且排除自身要跑 4 遍、计数随点击跳动反而费解。
public struct Facets: Hashable, Sendable {
    public var status: [TorrentFilter: Int]
    /// key 为分类名，`""` 表示无分类。
    public var categories: [String: Int]
    public var tags: [String: Int]
    /// 按 tracker URL 的 host 归并——实测 260 个 tracker URL，不归并侧边栏没法看。
    public var trackerHosts: [String: Int]

    public init(
        status: [TorrentFilter: Int] = [:], categories: [String: Int] = [:],
        tags: [String: Int] = [:], trackerHosts: [String: Int] = [:]
    ) {
        self.status = status
        self.categories = categories
        self.tags = tags
        self.trackerHosts = trackerHosts
    }
}

public struct TrafficStats: Hashable, Sendable {
    public var totalBytes: Int64
    public var lastRoundBytes: Int64
    public var requestCount: Int

    public init(totalBytes: Int64 = 0, lastRoundBytes: Int64 = 0, requestCount: Int = 0) {
        self.totalBytes = totalBytes
        self.lastRoundBytes = lastRoundBytes
        self.requestCount = requestCount
    }
}

/// 同步引擎推给 UI 的不可变快照。主线程只做一次赋值，过滤/排序/计数全在 actor 内完成。
public struct Snapshot: Hashable, Sendable {
    public var rows: [Torrent]
    public var facets: Facets
    public var serverState: ServerState
    public var categories: [Category]
    public var tags: [String]
    public var mode: SyncMode
    /// 内存里已加载的任务总数（未经筛选）。
    public var loadedCount: Int
    /// 服务端全部任务数。省流量档为 nil——没拉过全量，不知道总数，UI 不能假装有。
    public var totalCount: Int?
    public var updatedAt: Date
    /// 数据来自磁盘缓存而非本轮网络。UI 要标注出来，不能让用户以为是实时的。
    public var isFromCache: Bool
    public var traffic: TrafficStats
    /// 本轮 `filter=running` 命中的 hash。省流量档下，缓存里不在该集合的行是**陈旧**的，
    /// UI 必须能区分「实时」与「缓存残留」，否则会把已停止的任务显示成还在下载。
    /// 完整档为空集合（全部行都是实时的）。
    public var runningHashes: Set<String>
    /// 最近一次同步失败的原因。 nil 表示正常。UI 要显示出来，不能静默假装在线。
    public var errorMessage: String?
    /// 完整档首次联网被闸门拦下，等用户确认。UI 据此弹确认框；此时一个字节都没发。
    public var needsFullPullApproval: Bool

    public init(
        rows: [Torrent] = [], facets: Facets = Facets(), serverState: ServerState = ServerState(),
        categories: [Category] = [], tags: [String] = [], mode: SyncMode = .full,
        loadedCount: Int = 0, totalCount: Int? = nil, updatedAt: Date = .distantPast,
        isFromCache: Bool = false, traffic: TrafficStats = TrafficStats(),
        runningHashes: Set<String> = [], errorMessage: String? = nil,
        needsFullPullApproval: Bool = false
    ) {
        self.rows = rows
        self.facets = facets
        self.serverState = serverState
        self.categories = categories
        self.tags = tags
        self.mode = mode
        self.loadedCount = loadedCount
        self.totalCount = totalCount
        self.updatedAt = updatedAt
        self.isFromCache = isFromCache
        self.traffic = traffic
        self.runningHashes = runningHashes
        self.errorMessage = errorMessage
        self.needsFullPullApproval = needsFullPullApproval
    }
}