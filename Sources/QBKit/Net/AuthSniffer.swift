import Foundation

/// qB 在会话失效时**不一定返回 401/403**，可能返回 200 + 一个纯 JSON string
/// （`"Fails."` / `"Unauthorized"`）。直接拿去解码数组会报
/// 「invalid character '"' looking for beginning of value」，所以要先嗅探。
public enum AuthSniffer {
    /// 只看前 200 字节：真实任务列表是 21 MB，全量转小写字符串纯属浪费。
    private static let peekLength = 200

    private static let markers = ["fails", "unauthorized", "access", "forbidden"]

    public static func looksLikeAuthFailure(_ body: Data) -> Bool {
        guard let first = body.first, first == UInt8(ascii: "\"") else { return false }
        let peek = body.prefix(peekLength)
        guard let text = String(data: peek, encoding: .utf8)?.lowercased() else { return false }
        return markers.contains { text.contains($0) }
    }

    /// body 是不是一个纯 JSON string（而不是对象/数组）。解码失败时用它区分
    /// 「会话失效」和「真的解析不了」。
    public static func isPlainJSONString(_ body: Data) -> Bool {
        let trimmed = body.trimmedASCIIWhitespace
        guard let first = trimmed.first, let last = trimmed.last else { return false }
        return first == UInt8(ascii: "\"") && last == UInt8(ascii: "\"") && trimmed.count >= 2
    }

    /// 登录响应的 body 判定。实测 qB 5.3 是 **204 + 空 body**；旧版是 200 + `Ok.`。
    public static func loginSucceeded(status: Int, body: Data) -> Bool {
        guard status == 200 || status == 204 else { return false }
        let text = String(data: body.trimmedASCIIWhitespace, encoding: .utf8) ?? ""
        return text.isEmpty || text == "Ok."
    }

    /// 取一小段可读文本放进错误信息，别把 21 MB 塞进日志。
    public static func snippet(_ body: Data, limit: Int = 120) -> String {
        let peek = body.prefix(limit)
        return String(data: peek, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

extension Data {
    /// 只裁 ASCII 空白，避免为登录响应那几十字节走一遍 Unicode 标量遍历。
    var trimmedASCIIWhitespace: Data {
        var start = startIndex
        var end = endIndex
        while start < end, Self.isASCIIWhitespace(self[start]) { start += 1 }
        while end > start, Self.isASCIIWhitespace(self[end - 1]) { end -= 1 }
        return self[start..<end]
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}