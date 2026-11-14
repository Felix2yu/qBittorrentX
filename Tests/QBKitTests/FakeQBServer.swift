import Foundation
@testable import QBKit

/// URLProtocol 桩。实测那台真实服务器对客户端出口 IP 免鉴权，
/// 401/403/重登嗅探这些分支**在真机上测不到**，只能靠这里覆盖。
///
/// 用静态状态 + 锁：URLProtocol 由 URLSession 自行实例化，拿不到外部注入的上下文。
/// **按 host 分桶**——swift-testing 的 `.serialized` 只管同一套件内部，
/// 不同套件默认并行，共用一份 handler 会互相清空对方的剧本。
/// 因此每个套件用自己的假 host，且套件内必须 `.serialized`、每个测试开头 reset。
final class FakeQBServer: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var body: Data = Data()
        var headers: [String: String] = [:]
        /// 传输层失败（超时/断连）。在 handler 里 sleep 模拟不了超时：
        /// startLoading 与超时定时器在同一条队列上，sleep 会把定时器一起挡掉。
        var failure: URLError?

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(status: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"])
        }
        static let ok = Response(status: 200, body: Data())
        static let noContent = Response(status: 204, body: Data())
    }

    struct Recorded {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: String

        /// 表单字段，写操作断言用。
        var form: [String: String] {
            var out: [String: String] = [:]
            for pair in body.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                out[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
            return out
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [String: @Sendable (URLRequest) -> Response] = [:]
    private nonisolated(unsafe) static var recorded: [String: [Recorded]] = [:]

    private static func key(_ base: String) -> String { URL(string: base)?.host ?? base }

    static func reset(base: String, _ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.lock()
        handlers[key(base)] = handler
        recorded[key(base)] = []
        lock.unlock()
    }

    static func requests(base: String) -> [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded[key(base)] ?? []
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeQBServer.self]
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let body = Self.readBody(request)
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k] = v }

        let entry = Recorded(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            query: query, headers: headers, body: body
        )
        let host = request.url?.host ?? ""
        Self.lock.lock()
        Self.recorded[host, default: []].append(entry)
        let respond = Self.handlers[host]
        Self.lock.unlock()

        let response = respond?(request) ?? Response(status: 500, body: Data("no handler".utf8))
        if let failure = response.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let url = request.url ?? URL(string: "https://fake.invalid")!
        let http = HTTPURLResponse(
            url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession 可能把 body 转成 stream，两种都要读。
    private static func readBody(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(data: data, encoding: .utf8) ?? "" }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}