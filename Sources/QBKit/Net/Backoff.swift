import Foundation

/// 登录失败退避。**qB 默认 5 次失败登录就封 IP 1 小时**，所以凭据类错误绝不能密集重试。
/// 纯函数，便于单测；调用方持有 failCount。
public enum Backoff {
    public static let baseSeconds = 5
    public static let capSeconds = 300

    /// failCount 从 1 开始：5 → 10 → 20 → 40 → 80 → 160 → 300（封顶）。
    public static func delay(failCount: Int) -> Int {
        guard failCount > 0 else { return 0 }
        // 移位前先夹住指数，避免 failCount 很大时 Int 溢出。
        let exponent = min(failCount - 1, 16)
        let scaled = baseSeconds << exponent
        return min(scaled, capSeconds)
    }

    /// 距离上次失败是否已经等够了。
    public static func canAttempt(failCount: Int, lastFailure: Date?, now: Date = Date()) -> Bool {
        guard failCount > 0, let lastFailure else { return true }
        return now.timeIntervalSince(lastFailure) >= Double(delay(failCount: failCount))
    }

    public static func remainingSeconds(failCount: Int, lastFailure: Date?, now: Date = Date()) -> Int {
        guard failCount > 0, let lastFailure else { return 0 }
        let waited = now.timeIntervalSince(lastFailure)
        return max(0, Int((Double(delay(failCount: failCount)) - waited).rounded(.up)))
    }
}