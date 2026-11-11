import Foundation

/// 会话 cookie。**名字不能硬编码**：实测某台 5.3 服务器返回 `QBT_SID_8989`（带端口后缀），
/// 而官方 wiki 与旧版本写的是 `SID`。
public struct SessionCookie: Hashable, Sendable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public var headerValue: String { "\(name)=\(value)" }

    /// 从 `Set-Cookie` 头里挑出会话 cookie。可能有多条（qB 还会下发别的），
    /// 取名字含 `SID` 的那条；大小写不敏感比较。
    public static func extract(setCookieHeaders: [String]) -> SessionCookie? {
        for header in setCookieHeaders {
            // 只取第一段（name=value），后面的 Path/HttpOnly 等属性不要。
            let pair = header.split(separator: ";", maxSplits: 1)[0]
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            if name.uppercased().contains("SID") {
                return SessionCookie(name: name, value: value)
            }
        }
        return nil
    }

    /// URLSession 把多条 Set-Cookie 合并成一个头时的兜底解析。
    public static func extract(from response: HTTPURLResponse) -> SessionCookie? {
        // allHeaderFields 的 key 大小写不定，逐个比较。
        var headers: [String] = []
        for (key, value) in response.allHeaderFields {
            guard let k = key as? String, k.lowercased() == "set-cookie" else { continue }
            if let v = value as? String { headers.append(v) }
        }
        if let found = extract(setCookieHeaders: headers) { return found }
        // 合并成一条时形如 "A=1; Path=/, QBT_SID_8989=abc; HttpOnly"，按逗号再切一次。
        let split = headers.flatMap { $0.split(separator: ",").map(String.init) }
        return extract(setCookieHeaders: split)
    }
}