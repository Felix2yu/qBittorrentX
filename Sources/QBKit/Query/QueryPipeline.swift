import Foundation

public struct QueryResult: Hashable, Sendable {
    public var rows: [Torrent]
    public var facets: Facets

    public init(rows: [Torrent], facets: Facets) {
        self.rows = rows
        self.facets = facets
    }
}

public enum QueryPipeline {
    /// 过滤 + 排序 + facet 计数。纯函数，在 SyncEngine actor 内调用，不占主线程。
    public static func run(
        _ torrents: [String: Torrent], query: TorrentQuery, sort: [SortSpec]
    ) -> QueryResult {
        var rows: [Torrent] = []
        rows.reserveCapacity(torrents.count)
        var facets = Facets()
        facets.status.reserveCapacity(TorrentFilter.allCases.count)

        // facet 是全局计数，所以遍历全表；rows 只收命中筛选的。
        for torrent in torrents.values {
            for filter in TorrentFilter.allCases {
                if filter.matches(torrent) { facets.status[filter, default: 0] += 1 }
            }
            facets.categories[torrent.category, default: 0] += 1
            for tag in torrent.tags { facets.tags[tag, default: 0] += 1 }
            let host = torrent.trackerHost
            if !host.isEmpty { facets.trackerHosts[host, default: 0] += 1 }

            if query.matches(torrent) { rows.append(torrent) }
        }

        rows.sort { a, b in
            for spec in sort {
                let r = compare(spec.field, a, b)
                if r != 0 { return spec.order == .forward ? r < 0 : r > 0 }
            }
            // 字典转数组顺序是随机的，排序键并列时不加全序 tiebreak 会导致每轮行序乱跳。
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.hash < b.hash
        }

        return QueryResult(rows: rows, facets: facets)
    }

    private static func compare(_ field: SortField, _ a: Torrent, _ b: Torrent) -> Int {
        switch field {
        case .name: return a.name.localizedStandardCompare(b.name).rawValue
        case .size: return cmp(a.size, b.size)
        case .progress: return cmp(a.progress, b.progress)
        case .dlspeed: return cmp(a.dlspeed, b.dlspeed)
        case .upspeed: return cmp(a.upspeed, b.upspeed)
        case .eta: return cmp(a.etaKey, b.etaKey)
        case .state: return cmp(a.stateRank, b.stateRank)
        case .category: return cmp(a.categoryKey, b.categoryKey)
        case .tags: return cmp(a.tagsKey, b.tagsKey)
        case .ratio: return cmp(a.ratio, b.ratio)
        case .numSeeds: return cmp(a.numSeeds, b.numSeeds)
        case .numLeechs: return cmp(a.numLeechs, b.numLeechs)
        case .addedOn: return cmp(a.addedOn, b.addedOn)
        case .completionOn: return cmp(a.completionOn, b.completionOn)
        case .lastActivity: return cmp(a.lastActivity, b.lastActivity)
        case .downloaded: return cmp(a.downloaded, b.downloaded)
        case .uploaded: return cmp(a.uploaded, b.uploaded)
        case .savePath: return a.savePath.localizedStandardCompare(b.savePath).rawValue
        }
    }

    @inline(__always)
    private static func cmp<T: Comparable>(_ x: T, _ y: T) -> Int {
        x < y ? -1 : (x > y ? 1 : 0)
    }
}