import Foundation
import Testing
@testable import QBKit

/// Table 的 sortOrder 与持久化 SortSpec 之间的桥接。放在核心包就是为了能在本机测到。
struct SortComparatorBridgeTests {
    @Test func 每个字段都能往返() throws {
        for field in SortField.allCases {
            for order in [SortOrder.forward, SortOrder.reverse] {
                let spec = SortSpec(field: field, order: order)
                let 回 = SortSpec.specs([spec.comparator])
                #expect(回 == [spec], "\(field) \(order) 往返不一致")
            }
        }
    }

    @Test func 多列顺序保留() {
        let specs = [
            SortSpec(field: .dlspeed, order: .reverse),
            SortSpec(field: .name, order: .forward)
        ]
        #expect(SortSpec.specs(SortSpec.comparators(specs)) == specs)
    }

    @Test func 认不出的列被丢弃而不是崩() {
        let 陌生 = KeyPathComparator(\Torrent.tagsRaw, order: .forward)
        #expect(SortSpec.specs([陌生]).isEmpty)
        let 混合 = SortSpec.specs([陌生, SortSpec(field: .size).comparator])
        #expect(混合 == [SortSpec(field: .size)])
    }

    /// 表格排序与 QueryPipeline 排序必须给出同样的行序，否则点列头会看到与 CLI 不一致的结果。
    /// 收尾必须复刻管线的 name(localizedStandard) + hash 全序，否则会误判成不一致。
    @Test func 表格排序与查询管线结果一致() {
        var 同路径甲 = makeTorrent(hash: "e", name: "同名", dlspeed: 5)
        var 同路径乙 = makeTorrent(hash: "d", name: "同名", dlspeed: 5)
        // 裸 < 会把 Season10 排在 Season2 前，localizedStandard 相反——两条实现必须选同一种。
        同路径甲.savePath = "/data/Season2"
        同路径乙.savePath = "/data/Season10"
        let rows = [
            makeTorrent(hash: "a", name: "第10集", dlspeed: 5, eta: 60),
            makeTorrent(hash: "b", name: "第2集", dlspeed: 5, eta: Torrent.etaUnknown),
            makeTorrent(hash: "c", name: "第1集", dlspeed: 9, eta: 30),
            同路径甲, 同路径乙
        ]
        let 表 = Dictionary(uniqueKeysWithValues: rows.map { ($0.hash, $0) })
        let 收尾 = [
            KeyPathComparator(\Torrent.name, comparator: .localizedStandard),
            KeyPathComparator(\Torrent.hash)
        ]
        for field in SortField.allCases {
            for order in [SortOrder.forward, SortOrder.reverse] {
                let spec = SortSpec(field: field, order: order)
                let 管线 = QueryPipeline.run(表, query: TorrentQuery(), sort: [spec]).rows.map(\.hash)
                let 表格 = rows.sorted(using: [spec.comparator] + 收尾).map(\.hash)
                #expect(管线 == 表格, "\(field) \(order) 行序不一致：管线 \(管线) vs 表格 \(表格)")
            }
        }
    }

    @Test func 名称列用本地化数字比较() {
        let rows = [
            makeTorrent(hash: "a", name: "第10集"),
            makeTorrent(hash: "b", name: "第2集")
        ]
        let 排序后 = rows.sorted(using: [SortSpec(field: .name).comparator])
        #expect(排序后.map(\.name) == ["第2集", "第10集"])
    }

    @Test func ETA哨兵排在最后而不是混在中间() {
        let rows = [
            makeTorrent(hash: "a", name: "未知", eta: Torrent.etaUnknown),
            makeTorrent(hash: "b", name: "一分钟", eta: 60),
            makeTorrent(hash: "c", name: "一天", eta: 86400)
        ]
        let 排序后 = rows.sorted(using: [SortSpec(field: .eta).comparator])
        #expect(排序后.map(\.hash) == ["b", "c", "a"])
    }
}