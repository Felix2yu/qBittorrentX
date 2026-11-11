import Foundation
import Security

public enum KeychainError: Error, Hashable, Sendable {
    case invalidData
    case itemNotFound
    case unexpectedStatus(OSStatus)
}

/// 照搬 ntfyx 的 KeychainHelper，只改 service。
/// 保留 `SecItemUpdate → errSecItemNotFound → SecItemAdd` 的 upsert 顺序：
/// 直接 SecItemAdd 在已存在时会返回 errSecDuplicateItem。
public struct KeychainHelper: Sendable {
    private static let service = "im.yufei.qbittorrentx.auth"

    public static func save(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.invalidData }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 不存在时返回 nil 而不是抛错：首次启动、用户还没填凭据是正常路径。
    public static func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return text
    }

    public static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}