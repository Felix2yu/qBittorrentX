import Foundation

/// 端点描述。纯值类型，便于单测「省流量档绝不发全量请求」这类断言。
public struct Endpoint: Hashable, Sendable {
    public enum Method: String, Hashable, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public var method: Method
    /// `/api/v2` 之后的路径，不带前导斜杠。
    public var path: String
    public var query: [String: String]
    /// POST 表单。qB 的写操作全部走 `application/x-www-form-urlencoded`。
    public var form: [String: String]
    /// maindata 全量实测 4.24 s，慢链路更久，单独放宽。
    public var timeout: TimeInterval

    public init(
        method: Method = .get, path: String, query: [String: String] = [:],
        form: [String: String] = [:], timeout: TimeInterval = 15
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.form = form
        self.timeout = timeout
    }

    public static let apiPrefix = "/api/v2/"

    public var relativePath: String { Self.apiPrefix + path }

    /// 表单编码。qB 的 hashes 用 `|` 分隔，必须百分号转义。
    public var formBody: Data? {
        guard method == .post, !form.isEmpty else { return nil }
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        // URLComponents 把空格编成 +，qB 的表单解析接受；但 `|` 必须转义，queryItems 会处理。
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    public func url(base: URL) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent(relativePath), resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        }
        return components?.url
    }
}

extension Endpoint {
    public static let version = Endpoint(path: "app/version")
    public static let apiVersion = Endpoint(path: "app/webapiVersion")
    public static let login = Endpoint(method: .post, path: "auth/login")
    /// 实测 `GET /auth/logout` 返回 **405**，必须 POST。
    public static let logout = Endpoint(method: .post, path: "auth/logout")

    public static func maindata(rid: Int) -> Endpoint {
        Endpoint(path: "sync/maindata", query: ["rid": String(rid)], timeout: 60)
    }

    /// 省流量档唯一用到的任务列表请求。**filter 恒为 running**：
    /// 实测 running(33) ≠ active(21) ≠ downloading(38)，用 running 避免行在档位间抖动。
    public static func torrents(
        filter: String? = nil, sort: String? = nil, reverse: Bool = false, hashes: [String] = []
    ) -> Endpoint {
        var query: [String: String] = [:]
        if let filter { query["filter"] = filter }
        if let sort { query["sort"] = sort }
        if reverse { query["reverse"] = "true" }
        if !hashes.isEmpty { query["hashes"] = hashes.joined(separator: "|") }
        return Endpoint(path: "torrents/info", query: query, timeout: 60)
    }

    public static let runningTorrents = torrents(filter: "running")
    public static let transferInfo = Endpoint(path: "transfer/info")
    public static let categories = Endpoint(path: "torrents/categories")
    public static let tags = Endpoint(path: "torrents/tags")

    // MARK: - 写操作（qB 5.x：stop/start，不是 4.x 的 pause/resume）

    public static func stop(_ hashes: [String]) -> Endpoint {
        Endpoint(method: .post, path: "torrents/stop", form: ["hashes": hashes.joined(separator: "|")])
    }

    public static func start(_ hashes: [String]) -> Endpoint {
        Endpoint(method: .post, path: "torrents/start", form: ["hashes": hashes.joined(separator: "|")])
    }

    public static func recheck(_ hashes: [String]) -> Endpoint {
        Endpoint(method: .post, path: "torrents/recheck", form: ["hashes": hashes.joined(separator: "|")])
    }

    public static func delete(_ hashes: [String], deleteFiles: Bool) -> Endpoint {
        Endpoint(method: .post, path: "torrents/delete", form: [
            "hashes": hashes.joined(separator: "|"),
            "deleteFiles": deleteFiles ? "true" : "false"
        ])
    }

    public static func setCategory(_ hashes: [String], category: String) -> Endpoint {
        Endpoint(method: .post, path: "torrents/setCategory", form: [
            "hashes": hashes.joined(separator: "|"), "category": category
        ])
    }

    /// qB **没有覆盖式改标签端点**，只有 addTags / removeTags，差集要自己算。
    public static func addTags(_ hashes: [String], tags: [String]) -> Endpoint {
        Endpoint(method: .post, path: "torrents/addTags", form: [
            "hashes": hashes.joined(separator: "|"), "tags": tags.joined(separator: ",")
        ])
    }

    public static func removeTags(_ hashes: [String], tags: [String]) -> Endpoint {
        Endpoint(method: .post, path: "torrents/removeTags", form: [
            "hashes": hashes.joined(separator: "|"), "tags": tags.joined(separator: ",")
        ])
    }

    /// 单任务上传限速。0 表示取消限制。
    public static func setUploadLimit(_ hashes: [String], bytesPerSecond: Int64) -> Endpoint {
        Endpoint(method: .post, path: "torrents/setUploadLimit", form: [
            "hashes": hashes.joined(separator: "|"), "limit": String(max(0, bytesPerSecond))
        ])
    }
}