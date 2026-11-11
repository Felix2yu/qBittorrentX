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

/// 空闲轮：只有 rid 推进，什么都没变。真机上大部分轮次长这样。
private let 空增量 = """
{"rid":2}
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
        _ cache: SnapshotCache, url: String? = nil, apiKey: String = "", approval: Bool = false
    ) -> SyncEngine {
        SyncEngine(
            client: QBClient(
                credentials: Credentials(
                    baseURL: url ?? base, username: "admin", password: "pw", apiKey: apiKey
                ),
                session: FakeQBServer.makeSession()
            ),
            cache: cache,
            requiresFullPullApproval: approval
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

    /// 回归：上面那个测试手动 `persist(force: true)`，所以从没走过「跑几轮就退出」的真实路径。
    /// persist 有 30s 节流，运行不足 30s 就退出会把**过期 rid** 留在盘上。真机代价实测过：
    /// 盘上 rid=1 而服务端已到 rid=4，重启带旧 rid 被判过期，回 full_update 重下 27.45 MB。
    @Test func 停止时强制落盘最新rid与同一轮的任务表() async throws {
        let 轮次 = 计数()
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            return .json(轮次.next() == 1 ? 全量首轮 : 增量次轮)
        }
        let cache = 新缓存()
        let e = engine(cache)
        await e.refresh()
        await e.refresh()
        #expect(await e.debugState().rid == 2)
        // 节流窗口内第二轮没写盘——这正是缺陷的前提，不是断言失败。
        #expect(cache.load(serverURL: base)?.rid == 1)

        await e.stop()

        let 落盘 = try #require(cache.load(serverURL: base))
        #expect(落盘.rid == 2)
        // rid 与任务表必须出自同一轮，否则重启后会漏掉两轮之间的增量。
        #expect(落盘.torrents.count == 1)
        #expect(落盘.torrents["h1"]?.dlspeed == 999)
        #expect(落盘.torrents["h2"] == nil)
        #expect(落盘.cookie?.name == "QBT_SID_8989")
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

    /// 回归：真机上服务端丢了游标后**每轮都回 full_update**，客户端每 2s 重下 27.45 MB，
    /// 4 秒烧掉 54.90 MB。带着非 0 rid 拿回全量就必须停轮询，并把这件事告诉用户。
    @Test func 服务端恒回全量时暂停自动轮询() async throws {
        FakeQBServer.reset(base: base) { request in
            登录响应(request) ?? .json(全量首轮)
        }
        let e = engine(新缓存())
        await e.setIntervals(full: 0.5, lite: 30)
        await e.start()
        try await Task.sleep(for: .milliseconds(1600))

        let 全量次数 = FakeQBServer.requests(base: base)
            .filter { $0.path == "/api/v2/sync/maindata" }.count
        // 冷启动 1 次 + 发现游标失效 1 次。不暂停的话 1.6s 内会打到 4 次。
        #expect(全量次数 == 2)
        let s = await e.currentSnapshot()
        #expect(s.errorMessage?.contains("暂停自动同步") == true)
        // 数据已经下下来了，照常显示，不能因为暂停就清空。
        #expect(s.rows.count == 2)

        // 暂停后单轮 refresh 同样不联网：CLI 逐轮调的就是 refresh，不能绕过暂停。
        let 暂停后请求数 = FakeQBServer.requests(base: base).count
        await e.refresh()
        #expect(FakeQBServer.requests(base: base).count == 暂停后请求数)
        await e.stop()
    }

    /// 暂停后手动刷新是显式用户动作：解除暂停，并且轮询要能重新起来。
    @Test func 暂停后手动刷新能重新起轮询() async throws {
        let 轮次 = 计数()
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            return .json(轮次.next() <= 2 ? 全量首轮 : 增量次轮)
        }
        let e = engine(新缓存())
        await e.setIntervals(full: 0.5, lite: 30)
        await e.start()
        // 必须等轮询**真的退出**：置位后还要再走一个 interval 才 break。
        // 抢在退出前刷新的话 start() 只是空操作，测不到「重启」这条路径。
        try await Task.sleep(for: .milliseconds(1300))
        #expect(await e.currentSnapshot().errorMessage != nil)
        let 暂停时请求数 = FakeQBServer.requests(base: base).count

        await e.refresh()
        await e.start()
        try await Task.sleep(for: .milliseconds(900))
        // 轮询自己停下来时若不清 loopTask，这里的 start() 会被 guard 挡掉，请求数只 +1。
        #expect(FakeQBServer.requests(base: base).count > 暂停时请求数 + 1)
        #expect(await e.currentSnapshot().errorMessage == nil)
        await e.stop()
    }

    /// 自动判定看不穿 TUN 代理下的计费热点，所以完整档首次全量必须由用户点头。
    /// 拦下时**一个字节都不能发**：连登录都不该有。
    @Test func 完整档首次联网前被闸门拦下且零请求() async throws {
        FakeQBServer.reset(base: base) { request in
            登录响应(request) ?? .json(全量首轮)
        }
        let e = engine(新缓存(), approval: true)
        await e.setIntervals(full: 0.5, lite: 30)
        await e.refresh()
        var s = await e.currentSnapshot()
        #expect(s.needsFullPullApproval == true)
        #expect(s.loadedCount == 0)
        #expect(FakeQBServer.requests(base: base).isEmpty)

        // 轮询也不能绕过闸门。
        await e.start()
        try await Task.sleep(for: .milliseconds(800))
        #expect(FakeQBServer.requests(base: base).isEmpty)
        await e.stop()

        await e.approveFullPull()
        await e.refresh()
        s = await e.currentSnapshot()
        #expect(s.needsFullPullApproval == false)
        #expect(s.rows.count == 2)
        #expect(!FakeQBServer.requests(base: base).isEmpty)
    }

    /// 拦下不等于白屏：磁盘快照照常显示，用户看着缓存数据决定要不要下载。
    @Test func 闸门拦下时磁盘快照照常显示() async throws {
        FakeQBServer.reset(base: base) { request in
            登录响应(request) ?? .json(全量首轮)
        }
        let cache = 新缓存()
        let 写盘 = engine(cache)
        await 写盘.refresh()
        await 写盘.persist(force: true)

        let e = engine(cache, approval: true)
        await e.restoreFromCache()
        let s = await e.currentSnapshot()
        #expect(s.loadedCount == 2)
        #expect(s.isFromCache == true)
        #expect(s.needsFullPullApproval == true)
        // 只有写盘那次的登录 + maindata，装回缓存本身零网络。
        #expect(FakeQBServer.requests(base: base).count == 2)
    }

    @Test func 省流量档不受闸门影响且切档即解除() async throws {
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            if request.url?.path == "/api/v2/transfer/info" { return .json(传输信息) }
            return .json(运行中列表)
        }
        let e = engine(新缓存(), approval: true)
        await e.refresh()
        #expect(await e.currentSnapshot().needsFullPullApproval == true)

        // 切档立刻解除，不用等下一轮。
        await e.setMode(.lite)
        #expect(await e.currentSnapshot().needsFullPullApproval == false)
        await e.refresh()
        let s = await e.currentSnapshot()
        #expect(s.needsFullPullApproval == false)
        #expect(s.runningHashes == ["h1"])
        #expect(!FakeQBServer.requests(base: base).isEmpty)
    }

    /// 换服务器就是换一份未知体积，之前的批准不能沿用。
    @Test func 换服务器后全量批准作废() async throws {
        FakeQBServer.reset(base: base) { request in
            登录响应(request) ?? .json(全量首轮)
        }
        let e = engine(新缓存(), approval: true)
        await e.approveFullPull()
        await e.refresh()
        #expect(await e.currentSnapshot().needsFullPullApproval == false)
        let 换站前请求数 = FakeQBServer.requests(base: base).count

        await e.applyCredentials(Credentials(
            baseURL: "https://other.example.com", username: "admin", password: "pw"
        ))
        #expect(await e.currentSnapshot().needsFullPullApproval == true)
        await e.refresh()
        #expect(FakeQBServer.requests(base: base).count == 换站前请求数)
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
        let 轮次 = 计数()
        FakeQBServer.reset(base: base) { request in
            if let r = 登录响应(request) { return r }
            return .json(轮次.next() == 1 ? 全量首轮 : 空增量)
        }
        let e = engine(新缓存())
        let stream = await e.snapshots()
        let 收集器 = 收集()
        let 消费 = Task { for await s in stream { await 收集器.add(s) } }
        try await Task.sleep(for: .milliseconds(100))

        await e.refresh()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await 收集器.items.count == 2)

        // 空增量：rows 与 serverState 都没变 → 不该再推一次。
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