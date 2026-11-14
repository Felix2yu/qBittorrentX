import Foundation
import QBKit

/// 凭据来源：环境变量优先（一次性探测用，不落盘），否则读 Keychain + UserDefaults。
/// **仓库里不存任何凭据。**
enum CredentialSource {
    static func resolve() -> Credentials {
        let env = ProcessInfo.processInfo.environment
        let store = CredentialStore()
        var stored = store.load()
        if let v = env["QBX_URL"], !v.isEmpty { stored.baseURL = v }
        if let v = env["QBX_USERNAME"], !v.isEmpty { stored.username = v }
        if let v = env["QBX_PASSWORD"] { stored.password = v }
        if let v = env["QBX_API_KEY"] { stored.apiKey = v }
        return stored
    }

    /// 归档连接同样环境变量优先。`enabled` 只是界面开关，CLI 探测不看它。
    static func resolveArchive() -> ArchiveConnection {
        let env = ProcessInfo.processInfo.environment
        var stored = ArchiveCredentialStore().load()
        if let v = env["QBHIVE_URL"], !v.isEmpty { stored.baseURL = v }
        if let v = env["QBHIVE_TOKEN"] { stored.token = v }
        return stored
    }

    static func describe(_ c: Credentials) -> String {
        let lines = [
            "地址：\(c.normalizedBaseURL.isEmpty ? "(未配置)" : c.normalizedBaseURL)",
            "用户名：\(c.username.isEmpty ? "(未配置)" : c.username)",
            "密码：\(c.password.isEmpty ? "(未配置)" : "已设置（\(c.password.count) 字符）")",
            "API key：\(c.apiKey.isEmpty ? "(未配置)" : "已设置（\(c.apiKey.count) 字符）")",
            "鉴权方式：\(c.usesAPIKey ? "API key（无法增量，强制省流量档）" : "账号密码 + cookie 会话")",
            "可增量同步：\(c.canUseIncrementalSync ? "是" : "否")"
        ]
        return lines.joined(separator: "\n")
    }
}