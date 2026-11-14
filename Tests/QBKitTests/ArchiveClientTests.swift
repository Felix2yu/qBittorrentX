import Foundation
import Testing
@testable import QBKit

/// 走 URLProtocol 桩，假 host 与本套件绑定（见 FakeQBServer 的分桶说明）。
@Suite(.serialized)
struct ArchiveClientTests {
    private let base = "https://qbhive-archive.fake"

    private func client(token: String = "t0ken") -> ArchiveClient {
        ArchiveClient(baseURL: base, token: token, session: FakeQBServer.makeSession())
    }

    private static func envelope(_ records: String, total: Int) -> String {
        #"{"success":true,"message":"","data":{"records":\#(records),"total":\#(total)}}"#
    }

    private static let 一条记录 = """
    {"hash":"abc","name":"沙丘2","category":"电影","tags":"转码,4k","savePath":"/Volumes/Media/电影",\
    "contentPath":"/Volumes/Media/电影/沙丘2.mkv","tracker":"http://tr.example/announce",\
    "magnet":"magnet:?xt=urn:btih:abc","size":49,"uploaded":12,"addedOn":100,"completedOn":200,\
    "retiredAt":300,"ratio":1.5,"reason":"ratio"}
    """

    @Test func 全字段解码与退休判定() async throws {
        FakeQBServer.reset(base: base) { _ in .json(Self.envelope("[\(Self.一条记录)]", total: 1)) }
        let page = try await client().search()
        #expect(page.total == 1)
        let r = try #require(page.records.first)
        #expect(r.hash == "abc")
        #expect(r.id == r.hash)
        #expect(r.name == "沙丘2")
        #expect(r.tags == "转码,4k")
        #expect(r.contentPath == "/Volumes/Media/电影/沙丘2.mkv")
        #expect(r.size == 49)
        #expect(r.ratio == 1.5)
        #expect(r.reason == "ratio")
        #expect(r.isRetired)
    }

    @Test func 缺键记录落到默认值() async throws {
        FakeQBServer.reset(base: base) { _ in .json(Self.envelope(#"[{"hash":"abc","name":"老记录"}]"#, total: 1)) }
        let page = try await client().search()
        let r = try #require(page.records.first)
        #expect(r.category == "")
        #expect(r.magnet == "")
        #expect(r.size == 0)
        #expect(r.retiredAt == 0)
        #expect(!r.isRetired)
    }

    @Test func 中文与筛选条件进查询参数() async throws {
        FakeQBServer.reset(base: base) { _ in .json(Self.envelope("[]", total: 0)) }
        _ = try await client().search(ArchiveQuery(
            q: "沙丘 & 合集", category: "电影", tag: "转码", pending: true,
            sort: "size", order: "desc", limit: 20, offset: 40))
        let req = try #require(FakeQBServer.requests(base: base).first)
        #expect(req.path == "/api/archive")
        #expect(req.query["q"] == "沙丘 & 合集")
        #expect(req.query["category"] == "电影")
        #expect(req.query["tag"] == "转码")
        #expect(req.query["pending"] == "1")
        #expect(req.query["sort"] == "size")
        #expect(req.query["order"] == "desc")
        #expect(req.query["limit"] == "20")
        #expect(req.query["offset"] == "40")
    }

    @Test func 空条件只发分页参数() async throws {
        FakeQBServer.reset(base: base) { _ in .json(Self.envelope("[]", total: 0)) }
        _ = try await client().search()
        let req = try #require(FakeQBServer.requests(base: base).first)
        #expect(req.query.keys.sorted() == ["limit", "offset"])
    }

    @Test func 令牌走Bearer头() async throws {
        FakeQBServer.reset(base: base) { _ in .json(Self.envelope("[]", total: 0)) }
        _ = try await client(token: "sekrit").search()
        let req = try #require(FakeQBServer.requests(base: base).first)
        #expect(req.headers["Authorization"] == "Bearer sekrit")
    }

    @Test func 空令牌不发Authorization() async throws {
        FakeQBServer.reset(base: base) { _ in .json(Self.envelope("[]", total: 0)) }
        _ = try await client(token: "").search()
        let req = try #require(FakeQBServer.requests(base: base).first)
        #expect(req.headers["Authorization"] == nil)
    }

    @Test func 四零一判令牌问题且不重放() async throws {
        let body = #"{"success":false,"message":"未授权"}"#
        FakeQBServer.reset(base: base) { _ in .json(body, status: 401) }
        await #expect(throws: QBError.tokenRejected(body)) {
            _ = try await client().search()
        }
        #expect(FakeQBServer.requests(base: base).count == 1)
    }

    @Test func 四零三同样判令牌问题() async throws {
        FakeQBServer.reset(base: base) { _ in .json("禁止访问", status: 403) }
        await #expect(throws: QBError.tokenRejected("禁止访问")) {
            _ = try await client().search()
        }
        #expect(FakeQBServer.requests(base: base).count == 1)
    }

    @Test func 令牌被拒的文案指向QBHIVE_TOKEN() {
        // qbhive 没有登录，报「用户名或密码错误」会把人引去改 qB 的凭据。
        let 带片段 = QBError.tokenRejected(#"{"message":"unauthorized"}"#).displayMessage
        #expect(带片段.contains("QBHIVE_TOKEN"))
        #expect(带片段.contains("unauthorized"))
        #expect(!带片段.contains("用户名或密码"))
        #expect(QBError.tokenRejected("").displayMessage.contains("QBHIVE_TOKEN"))
    }

    @Test func 五百带片段抛http() async throws {
        FakeQBServer.reset(base: base) { _ in .json("归档模块未加载", status: 500) }
        await #expect(throws: QBError.http(status: 500, snippet: "归档模块未加载")) {
            _ = try await client().search()
        }
    }

    @Test func success为false抛rejected带说明() async throws {
        FakeQBServer.reset(base: base) { _ in .json(#"{"success":false,"message":"归档模块未加载"}"#) }
        await #expect(throws: QBError.rejected("归档模块未加载")) {
            _ = try await client().search()
        }
    }

    @Test func 空结果返回空页() async throws {
        FakeQBServer.reset(base: base) { _ in .json(Self.envelope("[]", total: 0)) }
        let page = try await client().search(ArchiveQuery(q: "不存在"))
        #expect(page.records.isEmpty)
        #expect(page.total == 0)
    }

    @Test func 超时映射为timedOut() async throws {
        FakeQBServer.reset(base: base) { _ in
            var r = FakeQBServer.Response()
            r.failure = URLError(.timedOut)
            return r
        }
        await #expect(throws: QBError.timedOut) { _ = try await client().search() }
    }

    @Test func 断连映射为transport() async throws {
        FakeQBServer.reset(base: base) { _ in
            var r = FakeQBServer.Response()
            r.failure = URLError(.networkConnectionLost)
            return r
        }
        do {
            _ = try await client().search()
            Issue.record("断连应当抛错")
        } catch let error as QBError {
            guard case .transport = error else {
                Issue.record("期望 transport，实际 \(error)")
                return
            }
        }
    }

    @Test func 流量统计记录真实字节与路径() async throws {
        let body = Self.envelope("[\(Self.一条记录)]", total: 1)
        FakeQBServer.reset(base: base) { _ in .json(body) }
        let c = client()
        _ = try await c.search()
        let traffic = await c.traffic()
        #expect(traffic.requestCount == 1)
        #expect(traffic.totalBytes == Int64(body.utf8.count))
        let metrics = await c.metrics()
        #expect(metrics.first?.path == "/api/archive")
        #expect(metrics.first?.status == 200)
        await c.resetTraffic()
        let cleared = await c.traffic()
        #expect(cleared.totalBytes == 0)
    }

    @Test func 未配置地址不发请求() async throws {
        FakeQBServer.reset(base: base) { _ in .json(Self.envelope("[]", total: 0)) }
        let c = ArchiveClient(baseURL: "", session: FakeQBServer.makeSession())
        await #expect(throws: QBError.notConfigured) { _ = try await c.search() }
        #expect(FakeQBServer.requests(base: base).isEmpty)
    }

    @Test func 尾斜杠地址归一后路径不重复() async throws {
        FakeQBServer.reset(base: base) { _ in .json(Self.envelope("[]", total: 0)) }
        let c = ArchiveClient(baseURL: base + "/", session: FakeQBServer.makeSession())
        _ = try await c.search()
        let req = try #require(FakeQBServer.requests(base: base).first)
        #expect(req.path == "/api/archive")
    }
}

/// 只验 UserDefaults 与 account 命名：**不碰真 Keychain**，测试不该往用户钥匙串写东西。
struct ArchiveCredentialStoreTests {
    @Test func 地址与开关进UserDefaults且默认关闭() throws {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ArchiveCredentialStore(defaults: defaults)
        #expect(store.load() == ArchiveConnection())
        defaults.set("http://127.0.0.1:8088/", forKey: Settings.Key.archiveURL)
        defaults.set(true, forKey: Settings.Key.archiveEnabled)
        let loaded = store.load()
        #expect(loaded.baseURL == "http://127.0.0.1:8088/")
        #expect(loaded.normalizedBaseURL == "http://127.0.0.1:8088")
        #expect(loaded.enabled)
        #expect(loaded.token == "")
    }

    @Test func account带归一地址换地址不读旧令牌() {
        #expect(ArchiveCredentialStore.tokenAccount("http://a:8088") == "http://a:8088#qbhiveToken")
        #expect(ArchiveCredentialStore.tokenAccount("http://a:8088") != ArchiveCredentialStore.tokenAccount("http://b:8088"))
    }
}