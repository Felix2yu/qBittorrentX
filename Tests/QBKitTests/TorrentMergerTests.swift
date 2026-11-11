import Foundation
import Testing
@testable import QBKit

struct TorrentMergerTests {
    /// 实测 qB 5.3 增量包的全部字段：11 个，**不含 hash/name/state**。
    private let 实测patch: JSONValue = .object([
        "availability": .double(0.5), "connections_count": .int(12),
        "dlspeed": .int(1_048_576), "downloaded": .int(2048), "eta": .int(600),
        "last_activity": .int(1_760_000_000), "popularity": .double(1.5),
        "ratio": .double(0.25), "reannounce": .int(300),
        "seen_complete": .int(1_759_000_000), "time_active": .int(3600)
    ])

    private let 基线 = Torrent(
        hash: "abc123", name: "Ubuntu 24.04", state: .downloading, progress: 0.4,
        size: 5_368_709_120, dlspeed: 100, category: "linux", tagsRaw: "iso,官方",
        savePath: "/data/linux", tracker: "https://t.example.com/announce", isPrivate: true
    )

    @Test func 增量合并后未提到的字段全部保留() throws {
        let 表 = try TorrentMerger.apply(base: ["abc123": 基线], patch: ["abc123": 实测patch], removed: [])
        let t = try #require(表["abc123"])
        #expect(t.name == "Ubuntu 24.04")
        #expect(t.state == .downloading)
        #expect(t.category == "linux")
        #expect(t.tags == ["iso", "官方"])
        #expect(t.savePath == "/data/linux")
        #expect(t.trackerHost == "t.example.com")
        #expect(t.isPrivate == true)
        #expect(t.size == 5_368_709_120)
        #expect(t.progress == 0.4)
        // patch 里的字段确实被覆盖
        #expect(t.dlspeed == 1_048_576)
        #expect(t.eta == 600)
        #expect(t.ratio == 0.25)
        #expect(t.availability == 0.5)
        #expect(t.hash == "abc123")
    }

    @Test func 反证_直接把patch当Torrent解码会清零() throws {
        let 错误做法 = try 实测patch.decoded(Torrent.self)
        #expect(错误做法.name == "")
        #expect(错误做法.state == .unknown(""))
        #expect(错误做法.size == 0)
        #expect(错误做法.dlspeed == 1_048_576)
    }

    @Test func 新增任务没有基线也能落地() throws {
        let 新条目: JSONValue = .object([
            "name": .string("新任务"), "state": .string("stalledDL"), "size": .int(99)
        ])
        let 表 = try TorrentMerger.apply(base: [:], patch: ["new": 新条目], removed: [])
        let t = try #require(表["new"])
        // hash 在 maindata 条目里缺失，必须由字典 key 注入。
        #expect(t.hash == "new")
        #expect(t.name == "新任务")
        #expect(t.state == .stalledDL)
        #expect(t.size == 99)
    }

    @Test func removed与patch同时生效() throws {
        let 表 = try TorrentMerger.apply(
            base: ["a": 基线, "b": 基线],
            patch: ["b": 实测patch, "c": .object(["name": .string("C")])],
            removed: ["a"]
        )
        #expect(表.count == 2)
        #expect(表["a"] == nil)
        #expect(表["b"]?.name == "Ubuntu 24.04")
        #expect(表["c"]?.hash == "c")
    }

    @Test func 空patch原样返回基线() throws {
        let 表 = try TorrentMerger.apply(base: ["a": 基线], patch: [:], removed: [])
        #expect(表 == ["a": 基线])
    }

    @Test func 大批量变更也不丢字段() throws {
        var base: [String: Torrent] = [:]
        var patch: [String: JSONValue] = [:]
        for i in 0..<500 {
            let hash = "h\(i)"
            base[hash] = Torrent(hash: hash, name: "任务\(i)", state: .downloading, category: "c")
            patch[hash] = 实测patch
        }
        let 表 = try TorrentMerger.apply(base: base, patch: patch, removed: [])
        #expect(表.count == 500)
        #expect(表.values.allSatisfy { !$0.name.isEmpty && $0.state == .downloading && $0.category == "c" })
        #expect(表.values.allSatisfy { $0.dlspeed == 1_048_576 })
    }

    @Test func 全量响应直接解成Torrent并注入hash() throws {
        let json = """
        {"rid":1,"full_update":true,"torrents":{"h1":{"name":"A","state":"downloading"},
         "h2":{"name":"B","state":"stoppedUP"}}}
        """
        let m = try JSONDecoder().decode(Maindata.self, from: Data(json.utf8))
        guard case .full(let 表) = m.torrents else {
            Issue.record("full_update=true 应走 .full 分支")
            return
        }
        #expect(表.count == 2)
        #expect(表["h1"]?.hash == "h1")
        #expect(表["h1"]?.name == "A")
        #expect(表["h2"]?.state == .stoppedUP)
    }

    @Test func 增量响应保留原始JSON() throws {
        let json = #"{"rid":2,"torrents":{"h1":{"dlspeed":5}}}"#
        let m = try JSONDecoder().decode(Maindata.self, from: Data(json.utf8))
        #expect(m.fullUpdate == false)
        guard case .patch(let p) = m.torrents else {
            Issue.record("缺 full_update 键应走 .patch 分支")
            return
        }
        #expect(p["h1"]?.objectValue?["dlspeed"]?.intValue == 5)
        #expect(p["h1"]?.objectValue?["name"] == nil)
    }
}