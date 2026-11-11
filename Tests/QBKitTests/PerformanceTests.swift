import Foundation
import Testing
@testable import QBKit

/// 性能测量。swift-testing 没有 XCTest 的 `measure`，用 ContinuousClock 显式计时，
/// 取多轮最小值（避开调度抖动）。数字打印到 stdout，README 里记的就是这里的输出。
/// 单独跑：`make perf`
///
/// 阈值是**回归护栏**，按实测 release 数字留 3~4 倍余量（debug 是 -Onone，慢 2~4 倍），
/// 不是计划里那份未验证的猜测值。
@Suite(.serialized)
struct 性能测量 {
    private func 计时(_ 轮数: Int = 5, _ body: () throws -> Void) rethrows -> Double {
        var 最小 = Double.infinity
        for _ in 0..<轮数 {
            let start = ContinuousClock.now
            try body()
            let d = start.duration(to: .now)
            let 秒 = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            最小 = min(最小, 秒)
        }
        return 最小
    }

    private func 报告(_ 名称: String, _ 秒: Double) {
        print(String(format: "[性能] %@: %.1f ms", 名称, 秒 * 1000))
    }

    /// 当前进程物理内存占用（MB）。
    private func 内存() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    @Test func 全量解码与查询链路() throws {
        let raw = SyntheticData.rawJSON()
        let 全量data = try JSONEncoder().encode(JSONValue.object([
            "rid": .int(1), "full_update": .bool(true), "torrents": .object(raw)
        ]))
        print(String(format: "[性能] 合成全量 payload: %.2f MB（实测真实 maindata 为 28.78 MB）",
                     Double(全量data.count) / 1_048_576))
        let 起始内存 = 内存()

        var 整表: [String: Torrent] = [:]
        let 全量解码 = try 计时 {
            let m = try JSONDecoder().decode(Maindata.self, from: 全量data)
            guard case .full(let t) = m.torrents else { Issue.record("应走 .full"); return }
            整表 = t
        }
        报告("冷启动 Data → Maindata → [Torrent] 7283 条（采用）", 全量解码)
        #expect(全量解码 < 0.5)
        #expect(整表.count == SyntheticData.总数)
        #expect(整表.values.allSatisfy { !$0.hash.isEmpty && !$0.name.isEmpty })
        print(String(format: "[性能] 全表驻留内存增量: %.1f MB", 内存() - 起始内存))

        // 对照：整表建 JSONValue 树再二次编解码。实测慢 15×，故不采用。
        let 建树路径 = try 计时(2) {
            let m = try JSONDecoder().decode(MaindataTree.self, from: 全量data)
            let data = try JSONEncoder().encode(JSONValue.object(m.torrents))
            let t = try JSONDecoder().decode([String: Torrent].self, from: data)
            #expect(t.count == SyntheticData.总数)
        }
        报告("对照：整表建 JSONValue 树 + 二次编解码（不采用）", 建树路径)

        let 过滤排序 = 计时 {
            let r = QueryPipeline.run(整表, query: TorrentQuery(filter: .downloading), sort: [SortSpec(field: .dlspeed, order: .reverse)])
            // downloading 含 stalledDL 11 + stoppedDL 5，与实测 filter=downloading 返回 38 条一致。
            #expect(r.rows.count == 38)
        }
        报告("过滤 downloading + 排序 + 全局 facet", 过滤排序)
        #expect(过滤排序 < 0.1)

        let 全表排序 = 计时 {
            let r = QueryPipeline.run(整表, query: TorrentQuery(), sort: [SortSpec(field: .name)])
            #expect(r.rows.count == SyntheticData.总数)
        }
        报告("全表 7283 条按名称排序 + facet", 全表排序)
        // 计划里「过滤+排序 < 50 ms」的目标在全表名称排序上没达到：release 93 ms。
        // 成本在 localizedStandardCompare（中文+数字混排必须用它）；实测替代方案更差：
        // compare(.numeric…) 221 ms 且排序结果不同，裸 < 4.2 ms 但「第10集」会排在「第2集」前。
        // 排序在 SyncEngine actor 内做，不占主线程，故接受。
        #expect(全表排序 < 0.4)

        var 上一轮: QueryResult?
        let 短路命中 = 计时 {
            let r = QueryPipeline.run(整表, query: TorrentQuery(), sort: [SortSpec(field: .dlspeed, order: .reverse)])
            if let 上一轮 { #expect(上一轮 == r) }
            上一轮 = r
        }
        报告("全表查询 + 与上轮 Equatable 比较（短路判定）", 短路命中)

        let 快照编码 = try 计时(3) { _ = try JSONEncoder().encode(整表) }
        报告("磁盘快照编码 [Torrent] → Data", 快照编码)
        let 快照data = try JSONEncoder().encode(整表)
        print(String(format: "[性能] 快照体积: %.2f MB", Double(快照data.count) / 1_048_576))
        let 快照解码 = try 计时(3) { _ = try JSONDecoder().decode([String: Torrent].self, from: 快照data) }
        报告("磁盘快照解码 Data → [Torrent]", 快照解码)
        #expect(快照编码 < 0.3)
        #expect(快照解码 < 0.3)
    }

    @Test func 稳态增量一轮的总成本() throws {
        let raw = SyntheticData.rawJSON()
        let 全量data = try JSONEncoder().encode(JSONValue.object([
            "rid": .int(1), "full_update": .bool(true), "torrents": .object(raw)
        ]))
        let m = try JSONDecoder().decode(Maindata.self, from: 全量data)
        guard case .full(let 基线) = m.torrents else { Issue.record("应走 .full"); return }

        // 实测增量包 31 条变更 / 10414 B。
        let 变更hash = Array(raw.keys.sorted().prefix(31))
        var patch: [String: JSONValue] = [:]
        for (i, hash) in 变更hash.enumerated() { patch[hash] = SyntheticData.增量patch(hash, 序号: i) }
        let 增量data = try JSONEncoder().encode(JSONValue.object([
            "rid": .int(2), "torrents": .object(patch),
            "server_state": .object(["dl_info_speed": .int(1_048_576)])
        ]))
        print("[性能] 合成增量 payload: \(增量data.count) B（实测 10414 B / 8236 B）")

        var 表 = 基线
        let 一轮 = try 计时(10) {
            let delta = try JSONDecoder().decode(Maindata.self, from: 增量data)
            guard case .patch(let p) = delta.torrents else { Issue.record("应走 .patch"); return }
            表 = try TorrentMerger.apply(base: 表, patch: p, removed: delta.torrentsRemoved)
            let r = QueryPipeline.run(表, query: TorrentQuery(filter: .downloading), sort: [SortSpec(field: .dlspeed, order: .reverse)])
            #expect(r.rows.count == 38)
        }
        报告("稳态一轮：解码 + 合并 31 条 + 查询排序", 一轮)
        #expect(一轮 < 0.15)
        #expect(表.count == SyntheticData.总数)
        #expect(表.values.allSatisfy { !$0.name.isEmpty && $0.state != .unknown("") })
    }
}

/// 只用于性能对照：把 torrents 整表建成 JSONValue 树的旧方案。
private struct MaindataTree: Decodable {
    var torrents: [String: JSONValue]
}