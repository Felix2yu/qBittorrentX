import Foundation

/// 展示用格式化。纯函数，CLI 与 UI 共用。
/// 手写字节换算而不是每次 new 一个 ByteCountFormatter：7283 行 × 数列 × 每 2s 一轮，
/// 分配 formatter 的开销会盖过换算本身。
public enum ByteFormat {
    private static let units = ["KB", "MB", "GB", "TB", "PB"]

    public static func bytes(_ value: Int64) -> String {
        let v = max(0, value)
        if v < 1024 { return "\(v) B" }
        var scaled = Double(v)
        var index = -1
        repeat {
            scaled /= 1024
            index += 1
        } while scaled >= 1024 && index < units.count - 1
        return String(format: "%.2f", scaled) + " " + units[index]
    }

    public static func speed(_ value: Int64) -> String {
        bytes(value) + "/s"
    }

    /// 未知（qB 的 8640000 哨兵）与已完成都返回空串，让调用方整行/整格不渲染，
    /// 而不是摆一个「—」占位。
    public static func eta(_ seconds: Int64) -> String {
        guard seconds > 0, seconds < Torrent.etaUnknown else { return "" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if days > 0 { return "\(days)天\(hours)时" }
        if hours > 0 { return "\(hours)时\(minutes)分" }
        if minutes > 0 { return "\(minutes)分\(secs)秒" }
        return "\(secs)秒"
    }

    public static func ratio(_ value: Double) -> String {
        String(format: "%.2f", max(0, value))
    }

    public static func percent(_ progress: Double) -> String {
        String(format: "%.1f%%", min(max(progress, 0), 1) * 100)
    }

    private static let timestampStyle = Date.FormatStyle(date: .numeric, time: .shortened)

    public static func timestamp(_ epoch: Int64) -> String {
        guard epoch > 0 else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(timestampStyle)
    }

    /// qB 用 -1 或 0 表示不限速。
    public static func limit(_ bytesPerSecond: Int64) -> String {
        bytesPerSecond <= 0 ? "无限制" : speed(bytesPerSecond)
    }
}