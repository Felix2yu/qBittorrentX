import Foundation

/// 归档检索条件。空字符串表示不过滤，与服务端 `archive.Query` 的语义一致。
public struct ArchiveQuery: Hashable, Sendable {
    public var q: String
    public var category: String
    public var tag: String
    public var pending: Bool
    public var sort: String
    public var order: String
    public var limit: Int
    public var offset: Int

    public init(
        q: String = "", category: String = "", tag: String = "", pending: Bool = false,
        sort: String = "", order: String = "", limit: Int = 50, offset: Int = 0
    ) {
        self.q = q
        self.category = category
        self.tag = tag
        self.pending = pending
        self.sort = sort
        self.order = order
        self.limit = limit
        self.offset = offset
    }
}

/// qbhive 退休账本的只读客户端。流量口径与 QBClient 完全一致（RequestMetric），
/// 但不登录、不写：检索历史只发 GET，加种与删账本都不在这里。
public actor ArchiveClient {
    private var base: URL?
    private var token: String
    private let session: URLSession

    private var recentMetrics: [RequestMetric] = []
    private var totalBytes: Int64 = 0
    private var requestCount = 0

    private static let metricLimit = 200
    private static let searchPath = "/api/archive"

    public init(baseURL: String = "", token: String = "", session: URLSession? = nil) {
        self.base = URL(string: Credentials(baseURL: baseURL).normalizedBaseURL)
        self.token = token
        self.session = session ?? Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "qBittorrentX/\(QBKit.version)"]
        return URLSession(configuration: config)
    }

    public func configure(baseURL: String, token: String) {
        base = URL(string: Credentials(baseURL: baseURL).normalizedBaseURL)
        self.token = token
    }

    public func traffic() -> (totalBytes: Int64, requestCount: Int) { (totalBytes, requestCount) }
    public func metrics() -> [RequestMetric] { recentMetrics }
    public func resetTraffic() {
        totalBytes = 0
        requestCount = 0
        recentMetrics.removeAll()
    }

    public func search(_ query: ArchiveQuery = ArchiveQuery()) async throws -> ArchivePage {
        guard let base else { throw QBError.notConfigured }
        var components = URLComponents(
            url: base.appendingPathComponent("api/archive"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        if !query.q.isEmpty { items.append(URLQueryItem(name: "q", value: query.q)) }
        if !query.category.isEmpty { items.append(URLQueryItem(name: "category", value: query.category)) }
        if !query.tag.isEmpty { items.append(URLQueryItem(name: "tag", value: query.tag)) }
        if query.pending { items.append(URLQueryItem(name: "pending", value: "1")) }
        if !query.sort.isEmpty { items.append(URLQueryItem(name: "sort", value: query.sort)) }
        if !query.order.isEmpty { items.append(URLQueryItem(name: "order", value: query.order)) }
        items.append(URLQueryItem(name: "offset", value: String(query.offset)))
        items.append(URLQueryItem(name: "limit", value: String(query.limit)))
        components?.queryItems = items
        guard let url = components?.url else { throw QBError.invalidURL(base.absoluteString) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        guard let http = response as? HTTPURLResponse else { throw QBError.transport("响应不是 HTTP") }
        record(RequestMetric(path: Self.searchPath, status: http.statusCode, bytes: data.count, duration: seconds))

        // 令牌错不重试：qbhive 没有封 IP 机制，但反复拿错令牌打也没有意义。
        if http.statusCode == 401 || http.statusCode == 403 {
            throw QBError.tokenRejected(AuthSniffer.snippet(data))
        }
        if http.statusCode >= 400 {
            throw QBError.http(status: http.statusCode, snippet: AuthSniffer.snippet(data))
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw QBError.decoding("\(error.localizedDescription)｜响应片段：\(AuthSniffer.snippet(data))")
        }
        guard envelope.success else { throw QBError.rejected(envelope.message ?? "") }
        guard let page = envelope.data else { throw QBError.decoding("响应缺少 data 字段") }
        return page
    }

    private struct Envelope: Decodable {
        var success: Bool
        var message: String?
        var data: ArchivePage?
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
}