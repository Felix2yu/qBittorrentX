import Foundation
import Network

/// 档位判定。纯函数部分可单测；NWPathMonitor 只负责把 path 喂进来。
public enum DataUsagePolicy {
    /// `isExpensive` = 蜂窝/个人热点，`isConstrained` = 低数据模式。两者任一为真就走省流量。
    public static func mode(usage: Settings.DataUsage, isExpensive: Bool, isConstrained: Bool) -> SyncMode {
        switch usage {
        case .full: return .full
        case .lite: return .lite
        case .auto: return (isExpensive || isConstrained) ? .lite : .full
        }
    }

    /// 只有 API key 时拿不到 cookie 会话，rid 游标无从续传 → **强制省流量**。
    /// 这是最危险的漏洞：绝不能退化成 20.6 MB 的全量轮询。
    public static func effectiveMode(
        usage: Settings.DataUsage, isExpensive: Bool, isConstrained: Bool, canUseIncrementalSync: Bool
    ) -> SyncMode {
        guard canUseIncrementalSync else { return .lite }
        return mode(usage: usage, isExpensive: isExpensive, isConstrained: isConstrained)
    }
}

/// 网络路径监测。路径变化时热切换档位，不需要重启。
///
/// **未验证**：macOS 上 USB 共享网络/热点的 `isExpensive` 判定是否准确，
/// 本机没有蜂窝网卡可测。判定不准时用户仍可在设置里显式覆盖。
public final class NetworkPathWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "im.yufei.qbittorrentx.path")
    private let lock = NSLock()
    private var expensive = false
    private var constrained = false
    private var onChange: (@Sendable (Bool, Bool) -> Void)?

    public init() {}

    public func start(onChange: @escaping @Sendable (Bool, Bool) -> Void) {
        lock.lock()
        self.onChange = onChange
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let e = path.isExpensive
            let c = path.isConstrained
            self.lock.lock()
            let changed = e != self.expensive || c != self.constrained
            self.expensive = e
            self.constrained = c
            let callback = self.onChange
            self.lock.unlock()
            if changed { callback?(e, c) }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
        lock.lock()
        onChange = nil
        lock.unlock()
    }

    public var current: (isExpensive: Bool, isConstrained: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (expensive, constrained)
    }
}