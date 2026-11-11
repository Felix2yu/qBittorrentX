import Foundation
import Testing
@testable import QBKit

struct JSONMergeTests {
    /// 这是整个设计最硬的约束：实测 qB 5.3 的增量 patch 只含这 11 个字段，
    /// **不含 hash / name / state**。直接反序列化 patch 会把它们清零。
    private let 实测patch: JSONValue = .object([
        "availability": .double(0.5),
        "connections_count": .int(12),
        "dlspeed": .int(1_048_576),
        "downloaded": .int(2048),
        "eta": .int(600),
        "last_activity": .int(1_760_000_000),
        "popularity": .double(1.5),
        "ratio": .double(0.25),
        "reannounce": .int(300),
        "seen_complete": .int(1_759_000_000),
        "time_active": .int(3600)
    ])

    private let 全量条目: JSONValue = .object([
        "hash": .string("abc123"),
        "name": .string("Ubuntu 24.04"),
        "state": .string("downloading"),
        "size": .int(5_368_709_120),
        "progress": .double(0.4),
        "dlspeed": .int(100),
        "category": .string("linux"),
        "tags": .string("iso,官方"),
        "save_path": .string("/data/linux"),
        "private": .bool(true)
    ])

    @Test func 增量合并后名称与状态不丢() throws {
        let merged = JSONMerge.merge(全量条目, 实测patch)
        let t = try merged.decoded(Torrent.self)
        #expect(t.name == "Ubuntu 24.04")
        #expect(t.state == .downloading)
        #expect(t.category == "linux")
        #expect(t.tags == ["iso", "官方"])
        #expect(t.savePath == "/data/linux")
        #expect(t.isPrivate == true)
        #expect(t.size == 5_368_709_120)
        // patch 里的字段确实被覆盖
        #expect(t.dlspeed == 1_048_576)
        #expect(t.eta == 600)
        #expect(t.ratio == 0.25)
    }

    @Test func 直接解码patch会丢掉名称与状态() throws {
        // 反证：说明为什么必须先合并。
        let 错误做法 = try 实测patch.decoded(Torrent.self)
        #expect(错误做法.name == "")
        #expect(错误做法.state == .unknown(""))
        #expect(错误做法.dlspeed == 1_048_576)
    }

    @Test func 合并保留未出现字段且覆盖已有字段() {
        let base: JSONValue = .object(["a": .int(1), "b": .int(2), "nested": .object(["x": .int(1), "y": .int(2)])])
        let patch: JSONValue = .object(["b": .int(9), "nested": .object(["y": .int(8)])])
        let merged = JSONMerge.merge(base, patch)
        #expect(merged.objectValue?["a"]?.intValue == 1)
        #expect(merged.objectValue?["b"]?.intValue == 9)
        #expect(merged.objectValue?["nested"]?.objectValue?["x"]?.intValue == 1)
        #expect(merged.objectValue?["nested"]?.objectValue?["y"]?.intValue == 8)
    }

    @Test func base为nil时直接取patch() {
        #expect(JSONMerge.merge(nil, .int(7)).intValue == 7)
    }

    @Test func 数组整体替换而非逐元素合并() {
        let base: JSONValue = .object(["list": .array([.int(1), .int(2), .int(3)])])
        let patch: JSONValue = .object(["list": .array([.int(9)])])
        #expect(JSONMerge.merge(base, patch).objectValue?["list"]?.arrayValue?.count == 1)
    }

    @Test func 按key合并字典并处理removed() {
        let base: [String: JSONValue] = ["a": .object(["name": .string("A")]), "b": .object(["name": .string("B")])]
        let patch: [String: JSONValue] = ["b": .object(["dlspeed": .int(5)]), "c": .object(["name": .string("C")])]
        let result = JSONMerge.mergeDictionary(base: base, patch: patch, removed: ["a"])
        #expect(result.count == 2)
        #expect(result["a"] == nil)
        #expect(result["b"]?.objectValue?["name"]?.stringValue == "B")
        #expect(result["b"]?.objectValue?["dlspeed"]?.intValue == 5)
        #expect(result["c"]?.objectValue?["name"]?.stringValue == "C")
    }

    @Test func 大整数不经Double丢精度() throws {
        // 9 PB 级 size 超出 Double 的 53 位精确整数范围。
        let 大值: Int64 = 9_007_199_254_740_993
        let value = JSONValue.int(大值)
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(back.intValue == 大值)
    }
}

struct TorrentDecodingTests {
    @Test func private映射到isPrivate() throws {
        let json = """
        {"hash":"h","name":"n","private":true,"num_seeds":7,"num_leechs":3,"tags":"a,b",
         "save_path":"/p","content_path":"/p/n","added_on":1700000000,"completion_on":1700000100,
         "last_activity":1700000200,"amount_left":99,"dl_limit":-1,"up_limit":1024}
        """
        let t = try JSONDecoder().decode(Torrent.self, from: Data(json.utf8))
        #expect(t.isPrivate == true)
        #expect(t.numSeeds == 7)
        #expect(t.numLeechs == 3)
        #expect(t.tags == ["a", "b"])
        #expect(t.savePath == "/p")
        #expect(t.contentPath == "/p/n")
        #expect(t.addedOn == 1_700_000_000)
        #expect(t.completionOn == 1_700_000_100)
        #expect(t.amountLeft == 99)
        #expect(t.dlLimit == -1)
        #expect(t.upLimit == 1024)
    }

    @Test func 缺字段时用默认值而不是解码失败() throws {
        // trackerless 种子确实没有 tracker；maindata 的条目没有 hash。
        let t = try JSONDecoder().decode(Torrent.self, from: Data(#"{"name":"n"}"#.utf8))
        #expect(t.hash == "")
        #expect(t.tracker == "")
        #expect(t.eta == Torrent.etaUnknown)
        #expect(t.state == .unknown(""))
        #expect(t.dlLimit == -1)
    }

    @Test func 未知状态原样保留() throws {
        let t = try JSONDecoder().decode(Torrent.self, from: Data(#"{"state":"someFutureState"}"#.utf8))
        #expect(t.state == .unknown("someFutureState"))
        #expect(t.state.rawValue == "someFutureState")
    }

    @Test func 编码解码往返一致() throws {
        let 原 = makeTorrent(
            hash: "h", name: "名字", state: .stalledUP, dlspeed: 10, upspeed: 20,
            size: 999, progress: 0.5, eta: 60, category: "c", tags: "a,b",
            tracker: "https://t.example.com/announce", addedOn: 1_700_000_000
        )
        let data = try JSONEncoder().encode(原)
        let 回 = try JSONDecoder().decode(Torrent.self, from: data)
        #expect(回 == 原)
    }

    @Test func maindata增量响应缺full_update键也能解码() throws {
        let json = """
        {"rid":3,"torrents":{"h":{"dlspeed":5}},"server_state":{"dl_info_speed":10}}
        """
        let m = try JSONDecoder().decode(Maindata.self, from: Data(json.utf8))
        #expect(m.rid == 3)
        #expect(m.fullUpdate == false)
        #expect(m.torrents.count == 1)
        #expect(m.torrentsRemoved.isEmpty)
        #expect(m.serverState?.objectValue?["dl_info_speed"]?.intValue == 10)
    }

    @Test func maindata全量响应解析removed与trackers() throws {
        let json = """
        {"rid":1,"full_update":true,"torrents":{},"torrents_removed":["x"],
         "categories":{"linux":{"name":"linux","savePath":"/data/linux"}},
         "tags":["iso"],"trackers":{"https://t.com/announce":["h1","h2"]}}
        """
        let m = try JSONDecoder().decode(Maindata.self, from: Data(json.utf8))
        #expect(m.fullUpdate == true)
        #expect(m.torrentsRemoved == ["x"])
        #expect(m.tags == ["iso"])
        #expect(m.trackers["https://t.com/announce"] == ["h1", "h2"])
        let 分类 = try #require(m.categories["linux"]).decoded(Category.self)
        #expect(分类.name == "linux")
        #expect(分类.savePath == "/data/linux")
    }

    @Test func serverState字段名是dl_info_speed() throws {
        let json = #"{"dl_info_speed":1024,"up_info_speed":2048,"dl_rate_limit":0,"connection_status":"connected","dht_nodes":300}"#
        let s = try JSONDecoder().decode(ServerState.self, from: Data(json.utf8))
        #expect(s.dlInfoSpeed == 1024)
        #expect(s.upInfoSpeed == 2048)
        #expect(s.connectionStatus == "connected")
        #expect(s.dhtNodes == 300)
    }
}