import Foundation
import Testing
@testable import QBKit

/// 走 URLProtocol 桩。真机免鉴权，这些分支只能在这里覆盖。
@Suite(.serialized)
struct QBClientTests {
    private let base = "https://fake.example.com"

    private func client(
        username: String = "admin", password: String = "pw", apiKey: String = ""
    ) -> QBClient {
        QBClient(
            credentials: Credentials(baseURL: base, username: username, password: password, apiKey: apiKey),
            session: FakeQBServer.makeSession()
        )
    }

    /// 登录成功：实测 qB 5.3 是 204 + 空 body + QBT_SID_8989。
    private static let 登录成功: @Sendable (URLRequest) -> FakeQBServer.Response = { request in
        if request.url?.path == "/api/v2/auth/login" {
            return FakeQBServer.Response(
                status: 204, body: Data(),
                headers: ["Set-Cookie": "QBT_SID_8989=session-token; Path=/; HttpOnly"]
            )
        }
        return .json(#"{"rid":1,"full_update":true,"torrents":{}}"#)
    }

    @Test func 登录后带上带端口后缀的cookie() async throws {
        FakeQBServer.reset(base: base, Self.登录成功)
        let c = client()
        _ = try await c.maindata(rid: 0)
        let 请求 = FakeQBServer.requests(base: base)
        #expect(请求.count == 2)
        #expect(请求[0].path == "/api/v2/auth/login")
        #expect(请求[0].method == "POST")
        #expect(请求[0].form["username"] == "admin")
        #expect(请求[1].headers["Cookie"] == "QBT_SID_8989=session-token")
        #expect(await c.currentCookie()?.name == "QBT_SID_8989")
    }

    @Test func 登录表单是urlencoded() async throws {
        FakeQBServer.reset(base: base, Self.登录成功)
        _ = try await client().version()
        let 登录 = FakeQBServer.requests(base: base)[0]
        #expect(登录.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(登录.body.contains("username=admin"))
        #expect(登录.body.contains("password=pw"))
    }

    @Test func 二百加Fails触发重登并重放一次() async throws {
        // qB 会话失效时可能返回 200 + 纯 JSON string，而不是 401/403。
        final class Counter: @unchecked Sendable {
            var maindataCalls = 0
            var loginCalls = 0
            let lock = NSLock()
        }
        let counter = Counter()
        FakeQBServer.reset(base: base) { request in
            let path = request.url?.path ?? ""
            if path == "/api/v2/auth/login" {
                counter.lock.lock(); counter.loginCalls += 1; let n = counter.loginCalls; counter.lock.unlock()
                return FakeQBServer.Response(
                    status: 204, body: Data(),
                    headers: ["Set-Cookie": "QBT_SID_8989=token\(n); Path=/"]
                )
            }
            counter.lock.lock(); counter.maindataCalls += 1; let n = counter.maindataCalls; counter.lock.unlock()
            if n == 1 { return .json(#""Fails.""#) }
            return .json(#"{"rid":9,"torrents":{"h":{"dlspeed":7}}}"#)
        }
        let c = client()
        let m = try await c.maindata(rid: 5)
        #expect(m.rid == 9)
        #expect(counter.loginCalls == 2)
        #expect(counter.maindataCalls == 2)
        // 重放必须带上**新** cookie，否则又会失败。
        let 重放 = FakeQBServer.requests(base: base).last
        #expect(重放?.headers["Cookie"] == "QBT_SID_8989=token2")
        #expect(重放?.query["rid"] == "5")
    }

    @Test func 四零三触发重登并重放() async throws {
        final class Counter: @unchecked Sendable {
            var calls = 0
            let lock = NSLock()
        }
        let counter = Counter()
        FakeQBServer.reset(base: base) { request in
            if request.url?.path == "/api/v2/auth/login" {
                return FakeQBServer.Response(
                    status: 200, body: Data("Ok.".utf8), headers: ["Set-Cookie": "SID=new; Path=/"]
                )
            }
            counter.lock.lock(); counter.calls += 1; let n = counter.calls; counter.lock.unlock()
            if n == 1 { return FakeQBServer.Response(status: 403, body: Data()) }
            return .json(#"[{"hash":"h1","name":"N","state":"downloading"}]"#)
        }
        let list = try await client().torrents(filter: "running")
        #expect(list.count == 1)
        #expect(list[0].hash == "h1")
        #expect(counter.calls == 2)
        #expect(FakeQBServer.requests(base: base).last?.headers["Cookie"] == "SID=new")
    }

    @Test func 重放后仍失败则会话失效() async throws {
        FakeQBServer.reset(base: base) { request in
            if request.url?.path == "/api/v2/auth/login" {
                return FakeQBServer.Response(status: 204, body: Data(), headers: ["Set-Cookie": "SID=t; Path=/"])
            }
            return .json(#""Unauthorized""#)
        }
        await #expect(throws: QBError.sessionExpired) {
            _ = try await client().maindata(rid: 0)
        }
    }

    @Test func 登录失败进退避且不密集重试() async throws {
        final class Counter: @unchecked Sendable {
            var loginCalls = 0
            let lock = NSLock()
        }
        let counter = Counter()
        FakeQBServer.reset(base: base) { _ in
            counter.lock.lock(); counter.loginCalls += 1; counter.lock.unlock()
            // qB 密码错误时返回 200 + "Fails."
            return .json(#""Fails.""#)
        }
        let c = client(password: "wrong")
        await #expect(throws: QBError.self) { _ = try await c.version() }
        #expect(counter.loginCalls == 1)

        // 紧接着再请求：必须被退避挡住，**不能再发登录请求**（qB 5 次失败封 IP 1 小时）。
        do {
            _ = try await c.version()
            Issue.record("退避期内应当直接抛错")
        } catch let error as QBError {
            guard case .backingOff(let seconds) = error else {
                Issue.record("期望 backingOff，实际 \(error)")
                return
            }
            #expect(seconds == 5)
        }
        #expect(counter.loginCalls == 1)
    }

    @Test func 登录返回五百也计入退避() async throws {
        // 保守处理：服务端异常时同样退避，不去 hammer 一台已经在挣扎的服务器。
        FakeQBServer.reset(base: base) { _ in FakeQBServer.Response(status: 500, body: Data("boom".utf8)) }
        let c = client()
        await #expect(throws: QBError.self) { _ = try await c.version() }
        do {
            _ = try await c.version()
            Issue.record("应当退避")
        } catch let error as QBError {
            if case .backingOff = error {} else { Issue.record("期望 backingOff，实际 \(error)") }
        }
    }

    @Test func APIkey模式双发头且不登录() async throws {
        FakeQBServer.reset(base: base) { _ in .json(#"[]"#) }
        let c = client(apiKey: "secret-key")
        _ = try await c.torrents(filter: "running")
        let 请求 = FakeQBServer.requests(base: base)
        #expect(请求.count == 1)
        #expect(请求[0].path != "/api/v2/auth/login")
        // 真机免鉴权判定不了哪个头才对，两个都发。
        #expect(请求[0].headers["X-Webapi-Key"] == "secret-key")
        #expect(请求[0].headers["Authorization"] == "Bearer secret-key")
        #expect(请求[0].headers["Cookie"] == nil)
    }

    @Test func 非法sort字段透传服务端四百() async throws {
        FakeQBServer.reset(base: base) { request in
            if request.url?.path == "/api/v2/auth/login" {
                return FakeQBServer.Response(status: 204, body: Data(), headers: ["Set-Cookie": "SID=t"])
            }
            return FakeQBServer.Response(status: 400, body: Data("Invalid sort field".utf8))
        }
        do {
            _ = try await client().torrents(sort: "totally_bogus_field")
            Issue.record("应当抛 HTTP 400")
        } catch let error as QBError {
            guard case .http(let status, let snippet) = error else {
                Issue.record("期望 http，实际 \(error)")
                return
            }
            #expect(status == 400)
            #expect(snippet.contains("Invalid sort field"))
        }
    }

    @Test func 增量序列先全量后补丁() async throws {
        FakeQBServer.reset(base: base) { request in
            if request.url?.path == "/api/v2/auth/login" {
                return FakeQBServer.Response(status: 204, body: Data(), headers: ["Set-Cookie": "SID=t"])
            }
            let rid = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "rid" }?.value ?? "0"
            if rid == "0" {
                return .json(#"{"rid":1,"full_update":true,"torrents":{"h1":{"name":"A","state":"downloading","dlspeed":1}}}"#)
            }
            // 实测增量包**没有 full_update 键**，也不含 name/state。
            return .json(#"{"rid":2,"torrents":{"h1":{"dlspeed":99}}}"#)
        }
        let c = client()
        let 全量 = try await c.maindata(rid: 0)
        #expect(全量.fullUpdate)
        guard case .full(let 表) = 全量.torrents else { Issue.record("应走 .full"); return }
        #expect(表["h1"]?.name == "A")

        let 增量 = try await c.maindata(rid: 全量.rid)
        #expect(!增量.fullUpdate)
        #expect(增量.rid == 2)
        guard case .patch(let p) = 增量.torrents else { Issue.record("应走 .patch"); return }
        let 合并 = try TorrentMerger.apply(base: 表, patch: p, removed: 增量.torrentsRemoved)
        #expect(合并["h1"]?.name == "A")
        #expect(合并["h1"]?.dlspeed == 99)
    }

    @Test func 写操作用5x端点且表单正确() async throws {
        FakeQBServer.reset(base: base, Self.登录成功)
        let c = client()
        try await c.stop(["a", "b"])
        try await c.start(["a"])
        try await c.setCategory(["a"], category: "linux")
        try await c.addTags(["a"], tags: ["iso", "官方"])
        try await c.removeTags(["a"], tags: ["iso"])
        try await c.setUploadLimit(["a"], bytesPerSecond: 1024)
        try await c.delete(["a"], deleteFiles: false)

        let 写 = FakeQBServer.requests(base: base).filter { $0.method == "POST" && $0.path != "/api/v2/auth/login" }
        #expect(写.map(\.path) == [
            "/api/v2/torrents/stop", "/api/v2/torrents/start", "/api/v2/torrents/setCategory",
            "/api/v2/torrents/addTags", "/api/v2/torrents/removeTags",
            "/api/v2/torrents/setUploadLimit", "/api/v2/torrents/delete"
        ])
        #expect(写[0].form["hashes"] == "a|b")
        #expect(写[2].form["category"] == "linux")
        #expect(写[3].form["tags"] == "iso,官方")
        #expect(写[5].form["limit"] == "1024")
        // 删除文件默认不勾。
        #expect(写[6].form["deleteFiles"] == "false")
    }

    @Test func 空选择不发请求() async throws {
        FakeQBServer.reset(base: base, Self.登录成功)
        try await client().stop([])
        #expect(FakeQBServer.requests(base: base).isEmpty)
    }

    @Test func 流量统计记录真实字节数() async throws {
        let body = #"{"rid":1,"full_update":true,"torrents":{}}"#
        FakeQBServer.reset(base: base) { request in
            if request.url?.path == "/api/v2/auth/login" {
                return FakeQBServer.Response(status: 204, body: Data(), headers: ["Set-Cookie": "SID=t"])
            }
            return .json(body)
        }
        let c = client()
        _ = try await c.maindata(rid: 0)
        let traffic = await c.traffic()
        #expect(traffic.requestCount == 2)
        #expect(traffic.totalBytes == Int64(body.utf8.count))
        let metrics = await c.metrics()
        #expect(metrics.count == 2)
        #expect(metrics[1].path == "sync/maindata")
        #expect(metrics[1].bytes == body.utf8.count)
        #expect(metrics[1].duration >= 0)
    }

    @Test func 换凭据后清cookie重新登录() async throws {
        FakeQBServer.reset(base: base, Self.登录成功)
        let c = client()
        _ = try await c.version()
        #expect(await c.currentCookie() != nil)
        await c.configure(Credentials(baseURL: base, username: "other", password: "pw2"))
        #expect(await c.currentCookie() == nil)
        _ = try await c.version()
        let 登录请求 = FakeQBServer.requests(base: base).filter { $0.path == "/api/v2/auth/login" }
        #expect(登录请求.count == 2)
        #expect(登录请求[1].form["username"] == "other")
    }

    @Test func 续传装回旧cookie后不再登录() async throws {
        FakeQBServer.reset(base: base, Self.登录成功)
        let c = client()
        await c.restore(cookie: SessionCookie(name: "QBT_SID_8989", value: "persisted"))
        _ = try await c.maindata(rid: 42)
        let 请求 = FakeQBServer.requests(base: base)
        #expect(请求.count == 1)
        #expect(请求[0].headers["Cookie"] == "QBT_SID_8989=persisted")
        #expect(请求[0].query["rid"] == "42")
    }

    @Test func 未配置地址直接报错不发请求() async throws {
        FakeQBServer.reset(base: base, Self.登录成功)
        let c = QBClient(credentials: Credentials(), session: FakeQBServer.makeSession())
        await #expect(throws: QBError.notConfigured) { _ = try await c.version() }
        #expect(FakeQBServer.requests(base: base).isEmpty)
    }

    @Test func 解码失败且body是纯JSON串时判为会话失效() async throws {
        FakeQBServer.reset(base: base) { request in
            if request.url?.path == "/api/v2/auth/login" {
                return FakeQBServer.Response(status: 204, body: Data(), headers: ["Set-Cookie": "SID=t"])
            }
            // 不带鉴权关键词的纯字符串，嗅探认不出，但解码失败后应归类为会话问题。
            return .json(#""Some other failure""#)
        }
        await #expect(throws: QBError.sessionExpired) {
            _ = try await client().torrents(filter: "running")
        }
    }

    @Test func 分类字典key补进name() async throws {
        FakeQBServer.reset(base: base) { request in
            if request.url?.path == "/api/v2/auth/login" {
                return FakeQBServer.Response(status: 204, body: Data(), headers: ["Set-Cookie": "SID=t"])
            }
            return .json(#"{"linux":{"savePath":"/data/linux"},"影视":{"name":"影视","savePath":"/data/v"}}"#)
        }
        let list = try await client().categories()
        #expect(list.count == 2)
        #expect(list.contains { $0.name == "linux" && $0.savePath == "/data/linux" })
    }
}