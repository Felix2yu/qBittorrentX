import Foundation
import Testing
@testable import QBKit

struct SortingTests {
    private func 表(_ items: [Torrent]) -> [String: Torrent] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.hash, $0) })
    }

    @Test func 排序键并列时行序仍然稳定() {
        // 全表 dlspeed 相同，只能靠 name + hash 的全序 tiebreak 定序。
        let items = (0..<200).map { makeTorrent(hash: String(format: "h%03d", $0), name: "同名任务") }
        var 上一轮: [String] = []
        for round in 0..<10 {
            // 每轮打乱字典插入顺序，模拟增量合并后字典顺序变化。
            let 乱序 = 表(items.shuffled())
            let rows = QueryPipeline.run(乱序, query: TorrentQuery(), sort: [SortSpec(field: .dlspeed, order: .reverse)]).rows
            let 本轮 = rows.map(\.hash)
            if round > 0 { #expect(本轮 == 上一轮) }
            上一轮 = 本轮
        }
        #expect(上一轮.count == 200)
    }

    @Test func 名称相同则按hash定序() {
        let items = [
            makeTorrent(hash: "c", name: "同名"),
            makeTorrent(hash: "a", name: "同名"),
            makeTorrent(hash: "b", name: "同名")
        ]
        let rows = QueryPipeline.run(表(items), query: TorrentQuery(), sort: []).rows
        #expect(rows.map(\.hash) == ["a", "b", "c"])
    }

    @Test func 下载速度降序() {
        let items = [
            makeTorrent(hash: "慢", name: "慢", dlspeed: 10),
            makeTorrent(hash: "快", name: "快", dlspeed: 1_048_576),
            makeTorrent(hash: "零", name: "零")
        ]
        let 降序 = QueryPipeline.run(表(items), query: TorrentQuery(), sort: [SortSpec(field: .dlspeed, order: .reverse)]).rows
        #expect(降序.map(\.hash) == ["快", "慢", "零"])
        let 升序 = QueryPipeline.run(表(items), query: TorrentQuery(), sort: [SortSpec(field: .dlspeed)]).rows
        #expect(升序.map(\.hash) == ["零", "慢", "快"])
    }

    @Test func 多列排序按先后优先级() {
        let items = [
            makeTorrent(hash: "1", name: "b", state: .downloading, dlspeed: 10),
            makeTorrent(hash: "2", name: "a", state: .downloading, dlspeed: 10),
            makeTorrent(hash: "3", name: "z", state: .downloading, dlspeed: 99)
        ]
        let rows = QueryPipeline.run(
            表(items), query: TorrentQuery(),
            sort: [SortSpec(field: .dlspeed, order: .reverse), SortSpec(field: .name)]
        ).rows
        #expect(rows.map(\.hash) == ["3", "2", "1"])
    }

    @Test func ETA哨兵排在最后而不是混在中间() {
        let items = [
            makeTorrent(hash: "未知", name: "未知", eta: Torrent.etaUnknown),
            makeTorrent(hash: "一天", name: "一天", eta: 86400),
            makeTorrent(hash: "一分", name: "一分", eta: 60),
            makeTorrent(hash: "超哨兵", name: "超哨兵", eta: Torrent.etaUnknown + 500)
        ]
        #expect(items[0].etaKey == Int64.max)
        #expect(items[3].etaKey == Int64.max)
        let rows = QueryPipeline.run(表(items), query: TorrentQuery(), sort: [SortSpec(field: .eta)]).rows
        #expect(rows.prefix(2).map(\.hash) == ["一分", "一天"])
        // 两个哨兵值并列，谁先谁后交给中文本地化 tiebreak，这里只断言它们都在末尾。
        #expect(Set(rows.suffix(2).map(\.hash)) == ["未知", "超哨兵"])
    }

    @Test func 空分类与空标签排在最后() {
        let items = [
            makeTorrent(hash: "无", name: "无"),
            makeTorrent(hash: "b", name: "b", category: "beta", tags: "zeta"),
            makeTorrent(hash: "a", name: "a", category: "alpha", tags: "aaa")
        ]
        let 按分类 = QueryPipeline.run(表(items), query: TorrentQuery(), sort: [SortSpec(field: .category)]).rows
        #expect(按分类.map(\.hash) == ["a", "b", "无"])
        let 按标签 = QueryPipeline.run(表(items), query: TorrentQuery(), sort: [SortSpec(field: .tags)]).rows
        #expect(按标签.map(\.hash) == ["a", "b", "无"])
    }

    @Test func 状态按展示语义而非字符串排() {
        let items = [
            makeTorrent(hash: "错", name: "错", state: .error),
            makeTorrent(hash: "下", name: "下", state: .downloading),
            makeTorrent(hash: "停", name: "停", state: .stoppedUP),
            makeTorrent(hash: "新", name: "新", state: .unknown("zzz"))
        ]
        let rows = QueryPipeline.run(表(items), query: TorrentQuery(), sort: [SortSpec(field: .state)]).rows
        #expect(rows.first?.hash == "下")
        #expect(rows.last?.hash == "新")
        #expect(rows.map(\.stateRank) == rows.map(\.stateRank).sorted())
    }

    @Test func 名称用本地化比较让数字按数值排() {
        let items = [
            makeTorrent(hash: "10", name: "第10集"),
            makeTorrent(hash: "2", name: "第2集"),
            makeTorrent(hash: "1", name: "第1集")
        ]
        let rows = QueryPipeline.run(表(items), query: TorrentQuery(), sort: [SortSpec(field: .name)]).rows
        #expect(rows.map(\.hash) == ["1", "2", "10"])
    }

    @Test func 排序与筛选组合() {
        let items = [
            makeTorrent(hash: "a", name: "a", state: .downloading, dlspeed: 5, category: "linux"),
            makeTorrent(hash: "b", name: "b", state: .uploading, dlspeed: 99, category: "linux"),
            makeTorrent(hash: "c", name: "c", state: .downloading, dlspeed: 50, category: "win")
        ]
        let rows = QueryPipeline.run(
            表(items), query: TorrentQuery(filter: .downloading, category: "linux"),
            sort: [SortSpec(field: .dlspeed, order: .reverse)]
        ).rows
        #expect(rows.map(\.hash) == ["a"])
    }
}

struct SortSpecTests {
    @Test func 编解码往返一致() throws {
        let specs = SortField.allCases.map { SortSpec(field: $0, order: .reverse) }
        let data = try JSONEncoder().encode(specs)
        let back = try JSONDecoder().decode([SortSpec].self, from: data)
        #expect(back == specs)
    }

    @Test func 反向切换() {
        let s = SortSpec(field: .dlspeed)
        #expect(s.reversed.order == .reverse)
        #expect(s.reversed.reversed == s)
    }
}

struct FacetCountTests {
    private let 样本: [String: Torrent] = [
        "1": makeTorrent(hash: "1", state: .downloading, dlspeed: 10, category: "linux", tags: "iso,官方", tracker: "https://a.example.com/announce"),
        "2": makeTorrent(hash: "2", state: .stoppedUP, category: "linux", tags: "iso", tracker: "udp://a.example.com:80/announce"),
        "3": makeTorrent(hash: "3", state: .missingFiles, category: "", tracker: "https://b.example.com/announce"),
        "4": makeTorrent(hash: "4", state: .uploading, upspeed: 7, category: "win")
    ]

    @Test func facet是全局计数不随筛选变化() {
        let 全部 = QueryPipeline.run(样本, query: TorrentQuery(), sort: []).facets
        let 只看linux = QueryPipeline.run(样本, query: TorrentQuery(category: "linux"), sort: []).facets
        #expect(全部 == 只看linux)
        #expect(全部.status[.downloading] == 1)
        #expect(全部.status[.stopped] == 2)
        #expect(全部.status[.errored] == 1)
        #expect(全部.status[.active] == 2)
        #expect(全部.status[.all] == 4)
    }

    @Test func 分类计数含空分类() {
        let f = QueryPipeline.run(样本, query: TorrentQuery(), sort: []).facets
        #expect(f.categories == ["linux": 2, "": 1, "win": 1])
    }

    @Test func 标签按拆分后逐个计数() {
        let f = QueryPipeline.run(样本, query: TorrentQuery(), sort: []).facets
        #expect(f.tags == ["iso": 2, "官方": 1])
    }

    @Test func tracker按host归并() {
        let f = QueryPipeline.run(样本, query: TorrentQuery(), sort: []).facets
        // 两条不同 scheme/端口/路径的 URL 归到同一个 host；无 tracker 的不计数。
        #expect(f.trackerHosts == ["a.example.com": 2, "b.example.com": 1])
    }
}