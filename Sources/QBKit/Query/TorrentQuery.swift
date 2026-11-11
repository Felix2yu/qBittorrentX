import Foundation

/// 多维筛选条件，各维度之间是 AND。全部在本地内存求值——切换筛选不产生任何网络请求，
/// 这对省流量档尤其重要。
public struct TorrentQuery: Hashable, Sendable {
    public var filter: TorrentFilter
    /// nil = 不按分类筛选；`""` = 只看无分类的任务。
    public var category: String?
    /// 同一维度内多个标签也是 AND（qB WebUI 语义）。
    public var tags: Set<String>
    public var trackerHost: String?
    public var search: String

    public init(
        filter: TorrentFilter = .all, category: String? = nil, tags: Set<String> = [],
        trackerHost: String? = nil, search: String = ""
    ) {
        self.filter = filter
        self.category = category
        self.tags = tags
        self.trackerHost = trackerHost
        self.search = search
    }

    public var isUnfiltered: Bool {
        filter == .all && category == nil && tags.isEmpty && trackerHost == nil
            && search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public func matches(_ t: Torrent) -> Bool {
        guard filter.matches(t) else { return false }
        if let category, t.category != category { return false }
        if !tags.isEmpty {
            let owned = Set(t.tags)
            guard tags.isSubset(of: owned) else { return false }
        }
        if let trackerHost, t.trackerHost != trackerHost { return false }
        let keyword = search.trimmingCharacters(in: .whitespaces)
        if !keyword.isEmpty, !t.name.localizedStandardContains(keyword) { return false }
        return true
    }
}