import Foundation

/// qbhive 归档的连接配置。地址与启用开关进 UserDefaults，**令牌只进 Keychain**。
public struct ArchiveConnection: Hashable, Sendable {
    public var baseURL: String
    public var token: String
    public var enabled: Bool

    public init(baseURL: String = "", token: String = "", enabled: Bool = false) {
        self.baseURL = baseURL
        self.token = token
        self.enabled = enabled
    }

    /// 与 qB 凭据同一套归一规则，保证 Keychain account 不因尾斜杠差异读不到旧令牌。
    public var normalizedBaseURL: String { Credentials(baseURL: baseURL).normalizedBaseURL }
}

/// 不标 Sendable：UserDefaults 不是 Sendable，而这个类型只在边界（CLI / UI 主 actor）用。
public struct ArchiveCredentialStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func tokenAccount(_ url: String) -> String { "\(url)#qbhiveToken" }

    public func load() -> ArchiveConnection {
        let url = defaults.string(forKey: Settings.Key.archiveURL) ?? ""
        let normalized = ArchiveConnection(baseURL: url).normalizedBaseURL
        let token = (try? KeychainHelper.read(account: Self.tokenAccount(normalized))) ?? nil
        return ArchiveConnection(
            baseURL: url, token: token ?? "",
            enabled: defaults.object(forKey: Settings.Key.archiveEnabled) as? Bool ?? false
        )
    }

    public func save(_ connection: ArchiveConnection) throws {
        let normalized = connection.normalizedBaseURL
        defaults.set(connection.baseURL, forKey: Settings.Key.archiveURL)
        defaults.set(connection.enabled, forKey: Settings.Key.archiveEnabled)
        try KeychainHelper.save(connection.token, account: Self.tokenAccount(normalized))
    }

    /// 只清当前地址的令牌，不动别的键。
    public func clearSecret() throws {
        let url = ArchiveConnection(baseURL: defaults.string(forKey: Settings.Key.archiveURL) ?? "").normalizedBaseURL
        try KeychainHelper.delete(account: Self.tokenAccount(url))
    }
}