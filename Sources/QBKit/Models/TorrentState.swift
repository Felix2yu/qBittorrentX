import Foundation

/// qBittorrent 5.x 的任务状态。
/// 用 `stoppedUP`/`stoppedDL` 而不是官方 wiki 仍写着的 `pausedUP`/`pausedDL`——wiki 滞后，
/// 5.3.0 实测返回的是 stopped 系。`unknown` 兜底保证 qB 升级新增状态时不崩、不丢行。
public enum TorrentState: Hashable, Sendable {
    case error
    case missingFiles
    case uploading
    case stoppedUP
    case forcedUP
    case stalledUP
    case checkingUP
    case queuedUP
    case downloading
    case stoppedDL
    case forcedDL
    case stalledDL
    case checkingDL
    case queuedDL
    case metaDL
    case forcedMetaDL
    case checkingResumeData
    case moving
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "error": self = .error
        case "missingFiles": self = .missingFiles
        case "uploading": self = .uploading
        case "stoppedUP": self = .stoppedUP
        case "forcedUP": self = .forcedUP
        case "stalledUP": self = .stalledUP
        case "checkingUP": self = .checkingUP
        case "queuedUP": self = .queuedUP
        case "downloading": self = .downloading
        case "stoppedDL": self = .stoppedDL
        case "forcedDL": self = .forcedDL
        case "stalledDL": self = .stalledDL
        case "checkingDL": self = .checkingDL
        case "queuedDL": self = .queuedDL
        case "metaDL": self = .metaDL
        case "forcedMetaDL": self = .forcedMetaDL
        case "checkingResumeData": self = .checkingResumeData
        case "moving": self = .moving
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .error: "error"
        case .missingFiles: "missingFiles"
        case .uploading: "uploading"
        case .stoppedUP: "stoppedUP"
        case .forcedUP: "forcedUP"
        case .stalledUP: "stalledUP"
        case .checkingUP: "checkingUP"
        case .queuedUP: "queuedUP"
        case .downloading: "downloading"
        case .stoppedDL: "stoppedDL"
        case .forcedDL: "forcedDL"
        case .stalledDL: "stalledDL"
        case .checkingDL: "checkingDL"
        case .queuedDL: "queuedDL"
        case .metaDL: "metaDL"
        case .forcedMetaDL: "forcedMetaDL"
        case .checkingResumeData: "checkingResumeData"
        case .moving: "moving"
        case .unknown(let raw): raw
        }
    }

    public var displayName: String {
        switch self {
        case .error: "错误"
        case .missingFiles: "文件缺失"
        case .uploading: "做种中"
        case .stoppedUP: "已停止做种"
        case .forcedUP: "强制做种"
        case .stalledUP: "做种停滞"
        case .checkingUP: "做种校验中"
        case .queuedUP: "排队做种"
        case .downloading: "下载中"
        case .stoppedDL: "已停止下载"
        case .forcedDL: "强制下载"
        case .stalledDL: "下载停滞"
        case .checkingDL: "下载校验中"
        case .queuedDL: "排队下载"
        case .metaDL: "获取元数据"
        case .forcedMetaDL: "强制获取元数据"
        case .checkingResumeData: "校验恢复数据"
        case .moving: "移动中"
        case .unknown(let raw): raw
        }
    }

    /// 排序用的展示序：下载类 → 做种类 → 校验/移动 → 异常。
    /// 直接排 rawValue 字符串会把 checkingDL 排到 downloading 前面，与用户看到的分组不符。
    public var rank: Int {
        switch self {
        case .downloading: 0
        case .forcedDL: 1
        case .metaDL: 2
        case .forcedMetaDL: 3
        case .stalledDL: 4
        case .queuedDL: 5
        case .checkingDL: 6
        case .stoppedDL: 7
        case .uploading: 8
        case .forcedUP: 9
        case .stalledUP: 10
        case .queuedUP: 11
        case .checkingUP: 12
        case .stoppedUP: 13
        case .checkingResumeData: 14
        case .moving: 15
        case .missingFiles: 16
        case .error: 17
        case .unknown: 18
        }
    }

    public var isErrored: Bool { self == .error || self == .missingFiles }
    public var isStopped: Bool { self == .stoppedUP || self == .stoppedDL || isErrored }
}

extension TorrentState: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}