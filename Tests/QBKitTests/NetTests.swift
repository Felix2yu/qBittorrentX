import Foundation
import Testing
@testable import QBKit

struct SessionCookieTests {
    @Test func 带端口后缀的cookie名() {
        // 实测某台 5.3 服务器返回的就是这个名字，硬编码 SID 会拿不到会话。
        let c = SessionCookie.extract(setCookieHeaders: ["QBT_SID_8989=abc123; Path=/; HttpOnly"])
        #expect(c?.name == "QBT_SID_8989")
        #expect(c?.value == "abc123")
        #expect(c?.headerValue == "QBT_SID_8989=abc123")
    }

    @Test func 旧版SID也能取到() {
        #expect(SessionCookie.extract(setCookieHeaders: ["SID=xyz; Path=/"])?.name == "SID")
    }

    @Test func 多条cookie里挑出SID() {
        let headers = ["other=1; Path=/", "QBT_SID_8989=real; HttpOnly", "third=2"]
        #expect(SessionCookie.extract(setCookieHeaders: headers)?.value == "real")
    }

    @Test func 大小写不敏感() {
        #expect(SessionCookie.extract(setCookieHeaders: ["qbt_sid_8080=v"])?.value == "v")
    }

    @Test func 无SID时返回nil() {
        #expect(SessionCookie.extract(setCookieHeaders: ["other=1", "theme=dark"]) == nil)
        #expect(SessionCookie.extract(setCookieHeaders: []) == nil)
        #expect(SessionCookie.extract(setCookieHeaders: ["SID="]) == nil)
        #expect(SessionCookie.extract(setCookieHeaders: [" malformed "]) == nil)
    }

    @Test func 值里含等号时只切第一个() {
        let c = SessionCookie.extract(setCookieHeaders: ["SID=aa=bb=cc; Path=/"])
        #expect(c?.value == "aa=bb=cc")
    }

    @Test func 从HTTPURLResponse提取() throws {
        let url = try #require(URL(string: "https://bt.example.com/api/v2/auth/login"))
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 204, httpVersion: "HTTP/1.1",
            headerFields: ["Set-Cookie": "QBT_SID_8989=fromResponse; Path=/; HttpOnly"]
        ))
        #expect(SessionCookie.extract(from: response)?.value == "fromResponse")
    }

    @Test func 编解码往返用于跨进程续传() throws {
        let c = SessionCookie(name: "QBT_SID_8989", value: "v")
        let back = try JSONDecoder().decode(SessionCookie.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }
}

struct AuthSnifferTests {
    @Test func 识别200加Fails() {
        #expect(AuthSniffer.looksLikeAuthFailure(Data(#""Fails.""#.utf8)))
        #expect(AuthSniffer.looksLikeAuthFailure(Data(#""Unauthorized""#.utf8)))
        #expect(AuthSniffer.looksLikeAuthFailure(Data(#""Access denied""#.utf8)))
        #expect(AuthSniffer.looksLikeAuthFailure(Data(#""Forbidden""#.utf8)))
    }

    @Test func 正常数组与对象不误判() {
        #expect(!AuthSniffer.looksLikeAuthFailure(Data(#"[{"name":"fails"}]"#.utf8)))
        #expect(!AuthSniffer.looksLikeAuthFailure(Data(#"{"rid":1}"#.utf8)))
        #expect(!AuthSniffer.looksLikeAuthFailure(Data()))
        // 任务名里含 fails 也不该误判——首字节不是引号。
        #expect(!AuthSniffer.looksLikeAuthFailure(Data(#"[{"name":"Mission Fails"}]"#.utf8)))
    }

    @Test func 只看前200字节() {
        // 引号开头但关键词在 200 字节之后：不该判为鉴权失败。
        let 长 = "\"" + String(repeating: "x", count: 300) + "fails\""
        #expect(!AuthSniffer.looksLikeAuthFailure(Data(长.utf8)))
    }

    @Test func 纯JSON串判定() {
        #expect(AuthSniffer.isPlainJSONString(Data(#""Fails.""#.utf8)))
        #expect(AuthSniffer.isPlainJSONString(Data("  \"Ok.\"  \n".utf8)))
        #expect(!AuthSniffer.isPlainJSONString(Data(#"[1,2]"#.utf8)))
        #expect(!AuthSniffer.isPlainJSONString(Data(#"{"a":1}"#.utf8)))
        #expect(!AuthSniffer.isPlainJSONString(Data()))
    }

    @Test func 登录成功判定_实测5_3是204空body() {
        #expect(AuthSniffer.loginSucceeded(status: 204, body: Data()))
        #expect(AuthSniffer.loginSucceeded(status: 200, body: Data("Ok.".utf8)))
        #expect(AuthSniffer.loginSucceeded(status: 200, body: Data("  Ok. \n".utf8)))
        #expect(AuthSniffer.loginSucceeded(status: 200, body: Data()))
    }

    @Test func 登录失败判定() {
        #expect(!AuthSniffer.loginSucceeded(status: 200, body: Data("Fails.".utf8)))
        #expect(!AuthSniffer.loginSucceeded(status: 403, body: Data()))
        #expect(!AuthSniffer.loginSucceeded(status: 401, body: Data("Ok.".utf8)))
        // 用户的 IP 被封时 qB 返回 403 + 一段说明。
        #expect(!AuthSniffer.loginSucceeded(status: 403, body: Data("Your IP has been banned".utf8)))
    }

    @Test func 错误片段有长度上限() {
        let 长 = Data(String(repeating: "a", count: 5000).utf8)
        #expect(AuthSniffer.snippet(长).count <= 120)
    }
}

struct BackoffTests {
    @Test func 五秒起翻倍封顶三百秒() {
        #expect(Backoff.delay(failCount: 0) == 0)
        #expect(Backoff.delay(failCount: 1) == 5)
        #expect(Backoff.delay(failCount: 2) == 10)
        #expect(Backoff.delay(failCount: 3) == 20)
        #expect(Backoff.delay(failCount: 4) == 40)
        #expect(Backoff.delay(failCount: 5) == 80)
        #expect(Backoff.delay(failCount: 6) == 160)
        #expect(Backoff.delay(failCount: 7) == 300)
        #expect(Backoff.delay(failCount: 8) == 300)
        // 大 failCount 不能溢出。
        #expect(Backoff.delay(failCount: 1000) == 300)
    }

    @Test func 没失败过就放行() {
        #expect(Backoff.canAttempt(failCount: 0, lastFailure: nil))
        #expect(Backoff.remainingSeconds(failCount: 0, lastFailure: nil) == 0)
    }

    @Test func 退避期内拒绝() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let 上次 = now.addingTimeInterval(-3)
        #expect(!Backoff.canAttempt(failCount: 1, lastFailure: 上次, now: now))
        #expect(Backoff.remainingSeconds(failCount: 1, lastFailure: 上次, now: now) == 2)
        let 够久了 = now.addingTimeInterval(-6)
        #expect(Backoff.canAttempt(failCount: 1, lastFailure: 够久了, now: now))
        #expect(Backoff.remainingSeconds(failCount: 1, lastFailure: 够久了, now: now) == 0)
    }

    @Test func 凭据类错误不可重试而网络类可以() {
        // 这条区分是防封 IP 的关键：qB 默认 5 次失败登录封 IP 1 小时。
        #expect(!QBError.credentialsRejected("Fails.").isRetryable)
        #expect(!QBError.sessionExpired.isRetryable)
        #expect(!QBError.http(status: 403, snippet: "").isRetryable)
        #expect(QBError.timedOut.isRetryable)
        #expect(QBError.transport("connection lost").isRetryable)
        #expect(QBError.credentialsRejected("").isCredentialProblem)
        #expect(!QBError.timedOut.isCredentialProblem)
    }
}

struct EndpointTests {
    private let base = URL(string: "https://bt.example.com")!

    @Test func 路径带api前缀() {
        #expect(Endpoint.version.relativePath == "/api/v2/app/version")
        #expect(Endpoint.maindata(rid: 7).url(base: base)?.absoluteString
                == "https://bt.example.com/api/v2/sync/maindata?rid=7")
    }

    @Test func 登出必须是POST() {
        // 实测 GET /auth/logout 返回 405。
        #expect(Endpoint.logout.method == .post)
    }

    @Test func 用5x的stop与start而不是4x的pause与resume() {
        #expect(Endpoint.stop(["a"]).path == "torrents/stop")
        #expect(Endpoint.start(["a"]).path == "torrents/start")
        #expect(Endpoint.stop(["a"]).method == .post)
    }

    @Test func 多hash用竖线分隔并转义() throws {
        let e = Endpoint.stop(["aaa", "bbb"])
        #expect(e.form["hashes"] == "aaa|bbb")
        let body = try #require(e.formBody)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains("hashes=aaa%7Cbbb"))
    }

    @Test func 删除文件默认关闭() {
        #expect(Endpoint.delete(["a"], deleteFiles: false).form["deleteFiles"] == "false")
        #expect(Endpoint.delete(["a"], deleteFiles: true).form["deleteFiles"] == "true")
    }

    @Test func 限速负数夹到零() {
        #expect(Endpoint.setUploadLimit(["a"], bytesPerSecond: -5).form["limit"] == "0")
        #expect(Endpoint.setUploadLimit(["a"], bytesPerSecond: 1024).form["limit"] == "1024")
    }

    @Test func 省流量档的请求恒带running筛选() throws {
        let url = try #require(Endpoint.runningTorrents.url(base: base))
        #expect(url.query?.contains("filter=running") == true)
        // 省流量档绝不能用无 filter 的 torrents/info（那是 20.6 MB 全量）。
        #expect(Endpoint.runningTorrents.query["filter"] != nil)
    }

    @Test func maindata超时放宽到60秒() {
        #expect(Endpoint.maindata(rid: 0).timeout == 60)
        #expect(Endpoint.transferInfo.timeout == 15)
    }

    @Test func 非法sort字段由服务端拒绝() {
        // 实测 sort=totally_bogus_field → HTTP 400，所以排序一律本地做，不传服务端。
        let e = Endpoint.torrents(sort: "totally_bogus_field")
        #expect(e.query["sort"] == "totally_bogus_field")
        #expect(SortField(rawValue: "totally_bogus_field") == nil)
    }
}

struct CredentialsTests {
    @Test func 凭据形态决定能否增量() {
        #expect(Credentials(baseURL: "u", username: "admin", password: "p").canUseIncrementalSync)
        #expect(!Credentials(baseURL: "u", apiKey: "k").canUseIncrementalSync)
        // 同时填了 API key 与密码时以 API key 为准（不登录），因此也不能增量。
        #expect(!Credentials(baseURL: "u", username: "admin", password: "p", apiKey: "k").canUseIncrementalSync)
        #expect(!Credentials(baseURL: "u").canUseIncrementalSync)
    }

    @Test func 地址末尾斜杠归一化() {
        #expect(Credentials(baseURL: " https://bt.example.com/ ").normalizedBaseURL == "https://bt.example.com")
        #expect(Credentials(baseURL: "https://bt.example.com//").normalizedBaseURL == "https://bt.example.com")
    }
}