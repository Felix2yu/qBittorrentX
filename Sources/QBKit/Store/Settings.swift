import Foundation

/// UserDefaults 门面。**这里不存任何密码或 API key**，那些只走 Keychain。
/// 不标 Sendable：UserDefaults 不是 Sendable，而这个类型只在边界（CLI / UI 主 actor）用。
/// setter 一律 nonmutating：写的是 UserDefaults 这个引用，值本身没变，
/// 否则调用方连 `let settings = Settings()` 都改不了配置。
public struct Settings {
    public enum Key {
        public static let serverURL = "server.url"
        public static let serverUsername = "server.username"
        public static let dataUsage = "sync.dataUsage"
        public static let liteInterval = "sync.liteInterval"
        public static let fullInterval = "sync.fullInterval"
        public static let sort = "torrent.sort"
        public static let columns = "torrent.columns"
        public static let inspectorVisible = "ui.inspectorVisible"
        public static let archiveURL = "archive.url"
        public static let archiveEnabled = "archive.enabled"
    }

    /// 数据用量档位。自动是默认值——能自动判定的就别让用户手动选。
    public enum DataUsage: String, CaseIterable, Hashable, Sendable, Codable {
        case auto, full, lite

        public var displayName: String {
            switch self {
            case .auto: "自动"
            case .full: "完整"
            case .lite: "省流量"
            }
        }
    }

    public static let defaultLiteInterval: TimeInterval = 30
    public static let liteIntervalRange: ClosedRange<TimeInterval> = 5...300
    public static let defaultFullInterval: TimeInterval = 2

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var dataUsage: DataUsage {
        get { DataUsage(rawValue: defaults.string(forKey: Key.dataUsage) ?? "") ?? .auto }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.dataUsage) }
    }

    public var liteInterval: TimeInterval {
        get {
            let stored = defaults.double(forKey: Key.liteInterval)
            guard stored > 0 else { return Self.defaultLiteInterval }
            return min(max(stored, Self.liteIntervalRange.lowerBound), Self.liteIntervalRange.upperBound)
        }
        nonmutating set {
            let clamped = min(max(newValue, Self.liteIntervalRange.lowerBound), Self.liteIntervalRange.upperBound)
            defaults.set(clamped, forKey: Key.liteInterval)
        }
    }

    public var fullInterval: TimeInterval {
        get {
            let stored = defaults.double(forKey: Key.fullInterval)
            return stored > 0 ? stored : Self.defaultFullInterval
        }
        nonmutating set { defaults.set(newValue, forKey: Key.fullInterval) }
    }

    public var inspectorVisible: Bool {
        get { defaults.object(forKey: Key.inspectorVisible) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.inspectorVisible) }
    }

    /// `KeyPathComparator` 不是 Codable，所以持久化 SortSpec 这一层。
    public var sort: [SortSpec] {
        get {
            guard let data = defaults.data(forKey: Key.sort),
                  let specs = try? JSONDecoder().decode([SortSpec].self, from: data), !specs.isEmpty
            else { return [SortSpec(field: .addedOn, order: .reverse)] }
            return specs
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.sort)
        }
    }
}