import Foundation
import Testing
@testable import QBKit

private func 登录响应(_ request: URLRequest) -> FakeQBServer.Response? {
    guard request.url?.path == "/api/v2/auth/login" else { return nil }
    return FakeQBServer.Response(
        status: 204, body: Data(),
        headers: ["Set-Cookie": "QBT_SID_8989=stub-token; Path=/"]
    )
}

private final class 计数: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
}

private let 全量首轮 = """
{"rid":1,"full_update":true,
 "torrents":{
   "h1":{"name":"Ubuntu 24.04","state":"downloading","size":100,"progress":0.2,"dlspeed":10,"category":"linux","tags":"iso,官方"},
   "h2":{"name":"Debian 13","state":"stalledUP","size":200,"progress":1,"category":"linux"}},
 "server_state":{"dl_info_speed":10,"up_info_speed":20,"connection_status":"connected","dht_nodes":300},
 "categories":{"linux":{"name":"linux","savePath":"/data/linux"}},"tags":["iso","官方"]}
"""

private let 增量次轮 = """
{"rid":2,"torrents":{"h1":{"dlspeed":999}},"torrents_removed":["h2"],
 "server_state":{"dl_info_speed":55}}
"""

private let 传输信息 = """
{"dl_info_speed":111,"up_info_speed":222,"dl_rate_limit":0,"up_rate_limit":0,
 "connection_status":"connected","dht_nodes":400}
"""

private let 运行中列表 = """
[{"hash":"h1","name":"Ubuntu 24.04","state":"downloading","size":100,"dlspeed":77,"category":"linux"}]
"""

@Suite(.serialized)
struct SyncEngineTests {
    /// 与 QBClientTests 用不同的假 host：两个套件默认并行，桩按 host 分桶才不会互相清剧本。
    private let base = "https://sync.fake.invalid"

    private func 新缓存() -> SnapshotCache {
        SnapshotCache(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qbx-sync-test-\(UUID().uuidString)"))
    }

    private func engine(
        _ cache: SnapshotCache, url: String? = nil, apiKey: String = ""
    ) -> SyncEngine {
        SyncEngine(
            client: QBClient(
                credentials: Credentials(
                    baseURL: url ?? base, username: "admin", password: "pw", apiKey: apiKey
                ),
                session: FakeQBServer.makeSession()
            ),
            cache: cache
        )
    }

    /// 冷启动全量 → 第二轮增量。这是整个引擎的主干路径。
    @Test func 完整档冷启动全量后第二轮走增量() async throws {
        let 轮次 = 计数()
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            return .json(轮次.next() == 1 ? 全量首轮 : 增量次轮)
        }
        let e = engine(新缓存())
        await e.refresh()
        var s = await e.currentSnapshot()
        #expect(s.rows.count == 2)
        #expect(s.loadedCount == 2)
        #expect(s.totalCount == 2)
        #expect(s.serverState.dlInfoSpeed == 10)
        #expect(s.categories.map(\.name) == ["linux"])
        #expect(s.tags == ["iso", "官方"])
        #expect(await e.debugState().rid == 1)

        await e.refresh()
        s = await e.currentSnapshot()
        #expect(s.rows.count == 1)
        let h1 = try #require(s.rows.first)
        // 增量包里没有 name/state/category/tags，合并后一个都不能丢。
        #expect(h1.name == "Ubuntu 24.04")
        #expect(h1.state == .downloading)
        #expect(h1.category == "linux")
        #expect(h1.tags == ["iso", "官方"])
        #expect(h1.dlspeed == 999)
        #expect(await e.debugState().rid == 2)

        let 增量请求 = try #require(FakeQBServer.requests(base: base).last)
        #expect(增量请求.query["rid"] == "1")
    }

    /// 回归：曾经把「上次发布的 serverState」当解码缓存用，导致完整档第二轮起读不到新合并的 raw。
    @Test func serverState增量合并后新值生效且旧字段保留() async throws {
        let 轮次 = 计数()
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            return .json(轮次.next() == 1 ? 全量首轮 : 增量次轮)
        }
        let e = engine(新缓存())
        await e.refresh()
        await e.refresh()
        let state = await e.currentSnapshot().serverState
        #expect(state.dlInfoSpeed == 55)
        // 增量包只给了 dl_info_speed，其余字段必须留着。
        #expect(state.upInfoSpeed == 20)
        #expect(state.connectionStatus == "connected")
        #expect(state.dhtNodes == 300)
    }

    @Test func 切换筛选与排序零网络请求() async throws {
        FakeQBServer.reset(base: base) { request in
            登录响应(request) ?? .json(全量首轮)
        }
        let e = engine(新缓存())
        await e.refresh()
        let 基线 = FakeQBServer.requests(base: base).count

        await e.setQuery(TorrentQuery(filter: .downloading, category: "linux"))
        #expect(await e.currentSnapshot().rows.count == 1)
        await e.setQuery(TorrentQuery(tags: ["官方"]))
        #expect(await e.currentSnapshot().rows.count == 1)
        await e.setQuery(TorrentQuery(search: "不存在的名字"))
        #expect(await e.currentSnapshot().rows.isEmpty)
        await e.setSort([SortSpec(field: .dlspeed, order: .reverse)])
        await e.setQuery(TorrentQuery())

        #expect(FakeQBServer.requests(base: base).count == 基线)
    }

    @Test func 省流量档永不请求全量() async throws {
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            if request.url?.path == "/api/v2/transfer/info" { return .json(传输信息) }
            return .json(运行中列表)
        }
        let e = engine(新缓存())
        await e.setMode(.lite)
        await e.setIntervals(full: 2, lite: 300)
        await e.refresh()
        await e.refresh()
        await e.refresh()

        let 请求 = FakeQBServer.requests(base: base)
        #expect(!请求.isEmpty)
        for r in 请求 {
            #expect(r.path != "/api/v2/sync/maindata")
            if r.path == "/api/v2/torrents/info" {
                #expect(r.query["filter"] == "running")
            }
        }
        // 首轮 transfer + running 两条；之后只 transfer，任务列表按 300 s 节流。
        #expect(请求.filter { $0.path == "/api/v2/torrents/info" }.count == 1)
        #expect(请求.filter { $0.path == "/api/v2/transfer/info" }.count == 3)
        // 全局速度仍是每轮新鲜。
        #expect(await e.currentSnapshot().serverState.dlInfoSpeed == 111)
    }

    @Test func 省流量档只覆盖运行中那批且标注陈旧行() async throws {
        let 轮次 = 计数()
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            let path = request.url?.path ?? ""
            if path == "/api/v2/transfer/info" { return .json(传输信息) }
            if path == "/api/v2/torrents/info" { return .json(运行中列表) }
            return .json(轮次.next() == 1 ? 全量首轮 : 增量次轮)
        }
        let e = engine(新缓存())
        await e.refresh()
        #expect(await e.currentSnapshot().loadedCount == 2)

        await e.setMode(.lite)
        await e.refresh()
        let s = await e.currentSnapshot()
        // h2 不在 running 里，但缓存行保留——只是被标为陈旧。
        #expect(s.loadedCount == 2)
        #expect(s.runningHashes == ["h1"])
        #expect(s.rows.first { $0.hash == "h1" }?.dlspeed == 77)
        // 没拉过全量就不知道服务端总数，不能假装有。
        #expect(s.totalCount == nil)
        #expect(s.mode == .lite)
    }

    @Test func 完整档快照写盘后新进程能装回rid与cookie() async throws {
        let 轮次 = 计数()
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            return .json(轮次.next() == 1 ? 全量首轮 : 增量次轮)
        }
        let cache = 新缓存()
        let 首个 = engine(cache)
        await 首个.refresh()
        await 首个.persist(force: true)
        #expect(cache.fileSize > 0)

        // 模拟重启：新引擎、新 client，只有磁盘缓存是共享的。
        let 重启后 = engine(cache)
        await 重启后.restoreFromCache()
        var s = await 重启后.currentSnapshot()
        #expect(s.loadedCount == 2)
        #expect(s.isFromCache == true)
        #expect(await 重启后.debugState().rid == 1)

        let 装回后请求数 = FakeQBServer.requests(base: base).count
        await 重启后.refresh()
        s = await 重启后.currentSnapshot()
        let 新请求 = Array(FakeQBServer.requests(base: base).dropFirst(装回后请求数))
        // 续传成功的关键：不重新登录，且带着旧 rid。
        #expect(!新请求.contains { $0.path == "/api/v2/auth/login" })
        #expect(新请求.first?.query["rid"] == "1")
        #expect(s.isFromCache == false)
        #expect(s.rows.count == 1)
    }

    @Test func 省流量档不写全量快照() async throws {
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            if request.url?.path == "/api/v2/transfer/info" { return .json(传输信息) }
            return .json(运行中列表)
        }
        let cache = 新缓存()
        let e = engine(cache)
        await e.setMode(.lite)
        await e.refresh()
        await e.persist(force: true)
        // 只有 1 条运行中任务，写下去会被下次启动误当成完整表。
        #expect(cache.fileSize == 0)
    }

    @Test func 服务器URL变了缓存作废且清空全表() async throws {
        FakeQBServer.reset(base: base) { request in
            登录响应(request) ?? .json(全量首轮)
        }
        let cache = 新缓存()
        let e = engine(cache)
        await e.refresh()
        await e.persist(force: true)
        #expect(cache.fileSize > 0)

        let 换站 = engine(cache, url: "https://other.example.com")
        await 换站.restoreFromCache()
        #expect(await 换站.currentSnapshot().loadedCount == 0)

        await e.applyCredentials(Credentials(
            baseURL: "https://other.example.com", username: "admin", password: "pw"
        ))
        #expect(await e.currentSnapshot().loadedCount == 0)
        #expect(cache.fileSize == 0)
    }

    /// 在途结果回来时代次号已变，必须整份丢弃，否则旧服务器的任务会串进新服务器。
    @Test func 代次号变更后丢弃在途结果() async throws {
        let 闸门 = DispatchSemaphore(value: 0)
        let 轮次 = 计数()
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            if 轮次.next() == 1 {
                _ = 闸门.wait(timeout: .now() + 5)
                return .json(全量首轮)
            }
            if request.url?.path == "/api/v2/transfer/info" { return .json(传输信息) }
            return .json(运行中列表)
        }
        let e = engine(新缓存())
        let 在途 = Task { await e.refresh() }

        // 等 maindata 真的发出去，再改代次号。
        for _ in 0..<500 {
            if FakeQBServer.requests(base: base).contains(where: { $0.path == "/api/v2/sync/maindata" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await e.setMode(.lite)
        闸门.signal()
        await 在途.value

        #expect(await e.currentSnapshot().loadedCount == 0)
        #expect(await e.debugState().rid == 0)
    }

    @Test func 同步失败时快照带出错误且不清空已有数据() async throws {
        let 轮次 = 计数()
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            return 轮次.next() == 1 ? .json(全量首轮) : .json("boom", status: 500)
        }
        let e = engine(新缓存())
        await e.refresh()
        #expect(await e.currentSnapshot().errorMessage == nil)
        await e.refresh()
        let s = await e.currentSnapshot()
        #expect(s.errorMessage != nil)
        #expect(s.rows.count == 2)
    }

    /// 回归：updateTraffic 曾经定义了但没人调用，快照里的流量恒为 0。
    @Test func 快照带出真实流量字节数() async throws {
        FakeQBServer.reset(base: base) { request in
            登录响应(request) ?? .json(全量首轮)
        }
        let e = engine(新缓存())
        await e.refresh()
        let traffic = await e.currentSnapshot().traffic
        #expect(traffic.totalBytes > 0)
        #expect(traffic.lastRoundBytes > 0)
        // 登录 + maindata。
        #expect(traffic.requestCount == 2)
    }

    @Test func 无变化的一轮不重复发布() async throws {
        actor 收集 {
            var items: [Snapshot] = []
            func add(_ s: Snapshot) { items.append(s) }
        }
        FakeQBServer.reset(base: base) { request in
            登录响应(request) ?? .json(全量首轮)
        }
        let e = engine(新缓存())
        let stream = await e.snapshots()
        let 收集器 = 收集()
        let 消费 = Task { for await s in stream { await 收集器.add(s) } }
        try await Task.sleep(for: .milliseconds(100))

        await e.refresh()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await 收集器.items.count == 2)

        // 同一份全量响应，rows 与 serverState 都没变 → 不该再推一次。
        await e.refresh()
        try await Task.sleep(for: .milliseconds(100))
        消费.cancel()
        let 收到 = await 收集器.items
        // 订阅时的初始空快照 + 首轮结果，第二轮被短路。
        #expect(收到.count == 2)
        #expect(收到.last?.rows.count == 2)
    }

    @Test func 乐观停止立刻反映在快照上() async throws {
        FakeQBServer.reset(base: base) { request in
            登录响应(request) ?? .json(全量首轮)
        }
        let e = engine(新缓存())
        await e.refresh()
        await e.optimisticStop(["h1"])
        let h1 = try #require(await e.currentSnapshot().rows.first { $0.hash == "h1" })
        #expect(h1.state == .stoppedDL)
        #expect(h1.dlspeed == 0)

        await e.optimisticCategory(["h1"], category: "电影")
        #expect(await e.currentSnapshot().rows.first { $0.hash == "h1" }?.category == "电影")
        await e.optimisticUploadLimit(["h1"], bytesPerSecond: 4096)
        #expect(await e.currentSnapshot().rows.first { $0.hash == "h1" }?.upLimit == 4096)
        await e.removeLocally(["h1"])
        #expect(await e.currentSnapshot().loadedCount == 1)
    }

    @Test func 分类增量删除与标签增量删除() async throws {
        let 轮次 = 计数()
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            if 轮次.next() == 1 { return .json(全量首轮) }
            return .json("""
            {"rid":3,"categories_removed":["linux"],"categories":{"电影":{"savePath":"/data/movie"}},
             "tags_removed":["官方"]}
            """)
        }
        let e = engine(新缓存())
        await e.refresh()
        await e.refresh()
        let s = await e.currentSnapshot()
        // 字典 key 才是权威名字，条目里没有 name。
        #expect(s.categories.map(\.name) == ["电影"])
        #expect(s.tags == ["iso"])
    }

    @Test func 只有APIkey时仍走完整档由调用方决定档位() async throws {
        // 引擎本身不猜档位；DataUsagePolicy.effectiveMode 负责强制省流量。
        // 这里只确认 API key 模式下引擎不发登录请求。
        FakeQBServer.reset(base: base) { _ in .json(全量首轮) }
        let e = engine(新缓存(), apiKey: "secret-key")
        await e.refresh()
        #expect(!FakeQBServer.requests(base: base).contains { $0.path == "/api/v2/auth/login" })
        #expect(FakeQBServer.requests(base: base).first?.headers["X-Webapi-Key"] == "secret-key")
        let 凭据 = Credentials(baseURL: base, username: "admin", password: "pw", apiKey: "secret-key")
        #expect(DataUsagePolicy.effectiveMode(
            usage: .full, isExpensive: false, isConstrained: false,
            canUseIncrementalSync: 凭据.canUseIncrementalSync
        ) == .lite)
    }
}