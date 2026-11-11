import Foundation

/// 凭据装配。**密码与 API key 只进 Keychain，绝不进 UserDefaults。**
/// account 用 `"\(url)#password"` / `"\(url)#apiKey"`，换服务器地址不会读到旧凭据。
/// 不标 Sendable：UserDefaults 不是 Sendable，而这个类型只在边界（CLI / UI 主 actor）用。
public struct CredentialStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func passwordAccount(_ url: String) -> String { "\(url)#password" }
    public static func apiKeyAccount(_ url: String) -> String { "\(url)#apiKey" }

    public func load() -> Credentials {
        let url = defaults.string(forKey: Settings.Key.serverURL) ?? ""
        let username = defaults.string(forKey: Settings.Key.serverUsername) ?? ""
        let normalized = Credentials(baseURL: url).normalizedBaseURL
        let password = (try? KeychainHelper.read(account: Self.passwordAccount(normalized))) ?? nil
        let apiKey = (try? KeychainHelper.read(account: Self.apiKeyAccount(normalized))) ?? nil
        return Credentials(
            baseURL: url, username: username,
            password: password ?? "", apiKey: apiKey ?? ""
        )
    }

    public func save(_ credentials: Credentials) throws {
        let normalized = credentials.normalizedBaseURL
        defaults.set(credentials.baseURL, forKey: Settings.Key.serverURL)
        defaults.set(credentials.username, forKey: Settings.Key.serverUsername)
        try KeychainHelper.save(credentials.password, account: Self.passwordAccount(normalized))
        try KeychainHelper.save(credentials.apiKey, account: Self.apiKeyAccount(normalized))
    }

    /// 只清当前服务器的凭据，不动别的键。
    public func clearSecrets() throws {
        let url = Credentials(baseURL: defaults.string(forKey: Settings.Key.serverURL) ?? "").normalizedBaseURL
        try KeychainHelper.delete(account: Self.passwordAccount(url))
        try KeychainHelper.delete(account: Self.apiKeyAccount(url))
    }
}