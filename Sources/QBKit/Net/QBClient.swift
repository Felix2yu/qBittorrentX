import Foundation

/// 一次请求的实测开销。CLI 与 UI 都靠它显示真实流量，而不是估算值。
public struct RequestMetric: Hashable, Sendable {
    public var path: String
    public var status: Int
    public var bytes: Int
    public var duration: TimeInterval
    public var at: Date

    public init(path: String, status: Int, bytes: Int, duration: TimeInterval, at: Date = Date()) {
        self.path = path
        self.status = status
        self.bytes = bytes
        self.duration = duration
        self.at = at
    }
}

public struct Credentials: Hashable, Sendable {
    public var baseURL: String
    public var username: String
    public var password: String
    public var apiKey: String

    public init(baseURL: String = "", username: String = "", password: String = "", apiKey: String = "") {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.apiKey = apiKey
    }

    public var usesAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 只有 API key 时拿不到 cookie 会话，而 rid 游标绑定会话 → **无法增量**。
    /// 调用方必须据此强制走省流量档，绝不能退化成全量轮询。
    public var canUseIncrementalSync: Bool { !usesAPIKey && !username.isEmpty }

    public var normalizedBaseURL: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// qBittorrent WebAPI 客户端。所有状态（cookie、退避计数、流量统计）都在 actor 内，
/// 调用方不需要额外加锁。
public actor QBClient {
    private var credentials: Credentials
    private var base: URL?
    private var cookie: SessionCookie?
    private var failCount = 0
    private var lastFailure: Date?
    private let session: URLSession

    private var recentMetrics: [RequestMetric] = []
    private var totalBytes: Int64 = 0
    private var requestCount = 0

    /// 只保留最近若干条，避免长时间运行后无限增长。
    private static let metricLimit = 200

    public init(credentials: Credentials = Credentials(), session: URLSession? = nil) {
        self.credentials = credentials
        self.base = URL(string: credentials.normalizedBaseURL)
        self.session = session ?? QBClient.makeSession()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // 自己管 Cookie 头：qB 的 cookie 名带端口后缀，交给系统 jar 反而不好持久化续传。
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "qBittorrentX/\(QBKit.version)"]
        return URLSession(configuration: config)
    }

    // MARK: - 配置

    /// 热替换凭据。换凭据后必须清 cookie 重新登录；URL 变了调用方还要清空任务表。
    public func configure(_ new: Credentials) {
        let urlChanged = new.normalizedBaseURL != credentials.normalizedBaseURL
        credentials = new
        base = URL(string: new.normalizedBaseURL)
        cookie = nil
        failCount = 0
        lastFailure = nil
        if urlChanged { recentMetrics.removeAll() }
    }

    public func currentCredentials() -> Credentials { credentials }
    public func currentCookie() -> SessionCookie? { cookie }

    /// 跨进程续传：把上次持久化的 cookie 装回来，配合旧 rid 试着只拿增量。
    /// 会话已过期时服务端会返回 full_update，调用方据此回退全量。
    public func restore(cookie: SessionCookie?) {
        self.cookie = cookie
        failCount = 0
        lastFailure = nil
    }

    public func traffic() -> (totalBytes: Int64, requestCount: Int) { (totalBytes, requestCount) }
    public func metrics() -> [RequestMetric] { recentMetrics }
    public func resetTraffic() {
        totalBytes = 0
        requestCount = 0
        recentMetrics.removeAll()
    }

    // MARK: - 读操作

    public func version() async throws -> String {
        let (data, _) = try await send(.version)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func webapiVersion() async throws -> String {
        let (data, _) = try await send(.apiVersion)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func maindata(rid: Int) async throws -> Maindata {
        let (data, _) = try await send(.maindata(rid: rid))
        do {
            return try JSONDecoder().decode(Maindata.self, from: data)
        } catch {
            throw Self.decodingError(error, data: data)
        }
    }

    /// `torrents/info` 返回数组，条目里**带 hash**（与 maindata 不同）。
    public func torrents(
        filter: String? = nil, sort: String? = nil, reverse: Bool = false, hashes: [String] = []
    ) async throws -> [Torrent] {
        let (data, _) = try await send(.torrents(filter: filter, sort: sort, reverse: reverse, hashes: hashes))
        do {
            return try JSONDecoder().decode([Torrent].self, from: data)
        } catch {
            throw Self.decodingError(error, data: data)
        }
    }

    public func transferInfo() async throws -> TransferInfo {
        let (data, _) = try await send(.transferInfo)
        do {
            return try JSONDecoder().decode(TransferInfo.self, from: data)
        } catch {
            throw Self.decodingError(error, data: data)
        }
    }

    public func categories() async throws -> [Category] {
        let (data, _) = try await send(.categories)
        do {
            let dict = try JSONDecoder().decode([String: Category].self, from: data)
            // 字典 key 才是权威名字，条目里的 name 可能缺失。
            return dict.map { key, value in
                var c = value
                if c.name.isEmpty { c.name = key }
                return c
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            throw Self.decodingError(error, data: data)
        }
    }

    public func tags() async throws -> [String] {
        let (data, _) = try await send(.tags)
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw Self.decodingError(error, data: data)
        }
    }

    // MARK: - 写操作

    public func stop(_ hashes: [String]) async throws { try await write(.stop(hashes)) }
    public func start(_ hashes: [String]) async throws { try await write(.start(hashes)) }
    public func recheck(_ hashes: [String]) async throws { try await write(.recheck(hashes)) }
    public func delete(_ hashes: [String], deleteFiles: Bool) async throws {
        try await write(.delete(hashes, deleteFiles: deleteFiles))
    }
    public func setCategory(_ hashes: [String], category: String) async throws {
        try await write(.setCategory(hashes, category: category))
    }
    public func addTags(_ hashes: [String], tags: [String]) async throws {
        try await write(.addTags(hashes, tags: tags))
    }
    public func removeTags(_ hashes: [String], tags: [String]) async throws {
        try await write(.removeTags(hashes, tags: tags))
    }
    public func setUploadLimit(_ hashes: [String], bytesPerSecond: Int64) async throws {
        try await write(.setUploadLimit(hashes, bytesPerSecond: bytesPerSecond))
    }

    private func write(_ endpoint: Endpoint) async throws {
        // 空选择直接跳过，别发一个 hashes= 的空请求。
        guard let hashes = endpoint.form["hashes"], !hashes.isEmpty else { return }
        let (data, response) = try await send(endpoint)
        // 写操作成功是 200 + 空 body；失败可能带一段说明文本。
        if response.statusCode >= 400 {
            throw QBError.http(status: response.statusCode, snippet: AuthSniffer.snippet(data))
        }
    }

    public func logout() async throws {
        // 实测 GET /auth/logout 返回 405，必须 POST。
        _ = try? await send(.logout)
        cookie = nil
    }

    // MARK: - 请求管线

    private func send(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        guard base != nil else { throw QBError.notConfigured }

        // API key 模式没有 cookie 可清，失败直接抛；重登只会白白消耗封 IP 的额度。
        if credentials.usesAPIKey {
            let (data, response) = try await raw(endpoint)
            try Self.validate(data: data, response: response)
            return (data, response)
        }

        if cookie == nil { try await login() }
        let (data, response) = try await raw(endpoint)
        let expired = response.statusCode == 401 || response.statusCode == 403
            || AuthSniffer.looksLikeAuthFailure(data)
        if expired {
            cookie = nil
            try await login()
            let (replayed, replayResponse) = try await raw(endpoint)
            if replayResponse.statusCode == 401 || replayResponse.statusCode == 403
                || AuthSniffer.looksLikeAuthFailure(replayed) {
                throw QBError.sessionExpired
            }
            try Self.validate(data: replayed, response: replayResponse)
            return (replayed, replayResponse)
        }
        try Self.validate(data: data, response: response)
        return (data, response)
    }

    private static func validate(data: Data, response: HTTPURLResponse) throws {
        if response.statusCode >= 400 {
            throw QBError.http(status: response.statusCode, snippet: AuthSniffer.snippet(data))
        }
        if AuthSniffer.looksLikeAuthFailure(data) { throw QBError.sessionExpired }
    }

    private func raw(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        guard let base, let url = endpoint.url(base: base) else {
            throw QBError.invalidURL(credentials.baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = endpoint.timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if credentials.usesAPIKey {
            // 实测那台服务器对客户端出口 IP 免鉴权，**无法判定哪个头才是对的**：
            // qbhive 注释说只认 X-Webapi-Key，官方 wiki 说 Authorization: Bearer。
            // 两个互不冲突，先都发；换成开了鉴权的服务器后删掉无效的那个。
            let key = credentials.apiKey.trimmingCharacters(in: .whitespaces)
            request.setValue(key, forHTTPHeaderField: "X-Webapi-Key")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else if let cookie {
            request.setValue(cookie.headerValue, forHTTPHeaderField: "Cookie")
        }

        if let body = endpoint.formBody {
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        let start = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.transportError(error)
        }
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        guard let http = response as? HTTPURLResponse else {
            throw QBError.transport("响应不是 HTTP")
        }
        record(RequestMetric(path: endpoint.path, status: http.statusCode, bytes: data.count, duration: seconds))
        return (data, http)
    }

    private func login() async throws {
        guard let base else { throw QBError.notConfigured }
        guard Backoff.canAttempt(failCount: failCount, lastFailure: lastFailure) else {
            throw QBError.backingOff(seconds: Backoff.remainingSeconds(failCount: failCount, lastFailure: lastFailure))
        }
        guard !credentials.username.isEmpty else {
            throw QBError.credentialsRejected("未填写用户名")
        }

        var request = URLRequest(url: base.appendingPathComponent(Endpoint.login.relativePath))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let start = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // 网络类失败不计入封 IP 的失败次数——服务端根本没收到这次登录。
            throw Self.transportError(error)
        }
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard let http = response as? HTTPURLResponse else { throw QBError.transport("响应不是 HTTP") }
        record(RequestMetric(path: Endpoint.login.path, status: http.statusCode, bytes: data.count, duration: seconds))

        guard AuthSniffer.loginSucceeded(status: http.statusCode, body: data) else {
            failCount += 1
            lastFailure = Date()
            throw QBError.credentialsRejected(AuthSniffer.snippet(data))
        }
        cookie = SessionCookie.extract(from: http)
        failCount = 0
        lastFailure = nil
        if cookie == nil {
            // 登录成功但没拿到会话 cookie：rid 续传无从谈起，调用方应转省流量档。
            Log.net.warning("登录成功但未收到 SID cookie，增量同步不可用")
        }
    }

    private func record(_ metric: RequestMetric) {
        totalBytes += Int64(metric.bytes)
        requestCount += 1
        recentMetrics.append(metric)
        if recentMetrics.count > Self.metricLimit {
            recentMetrics.removeFirst(recentMetrics.count - Self.metricLimit)
        }
    }

    private static func transportError(_ error: any Error) -> QBError {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timedOut
            case .cancelled: return .cancelled
            default: return .transport(urlError.localizedDescription)
            }
        }
        if error is CancellationError { return .cancelled }
        return .transport(error.localizedDescription)
    }

    private static func decodingError(_ error: any Error, data: Data) -> QBError {
        // 解码失败且 body 是纯 JSON string → 大概率是会话失效的另一种说法。
        if AuthSniffer.isPlainJSONString(data) { return .sessionExpired }
        return .decoding("\(error.localizedDescription)｜响应片段：\(AuthSniffer.snippet(data))")
    }
}