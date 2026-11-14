import Foundation

public enum QBError: Error, Hashable, Sendable {
    case invalidURL(String)
    case notConfigured
    /// 用户名/密码/API key 被服务端拒绝。**不重试**——qB 默认 5 次失败封 IP 1 小时。
    case credentialsRejected(String)
    /// qbhive 的 Bearer 令牌被拒（401/403）。与 qB 的登录凭据不是一回事：
    /// 文案必须指向 QBHIVE_TOKEN，否则用户会去改 qB 的用户名密码。
    case tokenRejected(String)
    case http(status: Int, snippet: String)
    /// HTTP 200 但 envelope 里 success=false：服务端明确拒绝，带它给的说明。
    case rejected(String)
    /// 200 但 body 是 `"Fails."` 这类纯 JSON string，qB 用它表示会话失效。
    case sessionExpired
    case decoding(String)
    case transport(String)
    case timedOut
    /// 登录失败退避中，附带还需等待的秒数。
    case backingOff(seconds: Int)
    case cancelled

    /// 只有网络/超时类才允许重登重放；凭据类错误直接进退避。这条区分是防封 IP 的关键。
    public var isRetryable: Bool {
        switch self {
        case .transport, .timedOut: true
        default: false
        }
    }

    public var isCredentialProblem: Bool {
        switch self {
        case .credentialsRejected, .sessionExpired, .tokenRejected: true
        default: false
        }
    }

    public var displayMessage: String {
        switch self {
        case .invalidURL(let s): "服务器地址无效：\(s)"
        case .notConfigured: "尚未配置服务器地址"
        case .credentialsRejected(let s): s.isEmpty ? "用户名或密码错误" : "登录被拒绝：\(s)"
        case .tokenRejected(let s):
            s.isEmpty ? "qbhive 令牌被拒绝，核对 QBHIVE_TOKEN" : "qbhive 令牌被拒绝，核对 QBHIVE_TOKEN：\(s)"
        case .http(let status, let snippet):
            snippet.isEmpty ? "服务器返回 HTTP \(status)" : "服务器返回 HTTP \(status)：\(snippet)"
        case .rejected(let s): s.isEmpty ? "服务端拒绝了请求" : "服务端拒绝：\(s)"
        case .sessionExpired: "会话已失效，需要重新登录"
        case .decoding(let s): "响应解析失败：\(s)"
        case .transport(let s): "网络错误：\(s)"
        case .timedOut: "请求超时"
        case .backingOff(let seconds): "登录失败次数过多，\(seconds) 秒后重试"
        case .cancelled: "请求已取消"
        }
    }
}