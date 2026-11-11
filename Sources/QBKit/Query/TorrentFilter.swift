import Foundation

/// 状态筛选档位。集合照搬 qbhive 对 qB 5.x `TorrentFilter` 的实测复刻
/// （`internal/qbittorrent/cache.go:444`），不是按官方 wiki 抄的。
public enum TorrentFilter: String, CaseIterable, Hashable, Sendable, Codable {
    case all
    case downloading
    case seeding
    case completed
    case stopped
    case running
    case active
    case inactive
    case stalled
    case stalledUploading = "stalled_uploading"
    case stalledDownloading = "stalled_downloading"
    case checking
    case moving
    case errored

    public var displayName: String {
        switch self {
        case .all: "全部"
        case .downloading: "下载中"
        case .seeding: "做种中"
        case .completed: "已完成"
        case .stopped: "已停止"
        case .running: "运行中"
        case .active: "活跃"
        case .inactive: "不活跃"
        case .stalled: "停滞"
        case .stalledUploading: "做种停滞"
        case .stalledDownloading: "下载停滞"
        case .checking: "校验中"
        case .moving: "移动中"
        case .errored: "异常"
        }
    }

    public func matches(_ t: Torrent) -> Bool {
        switch self {
        case .all:
            return true
        case .downloading:
            return Self.downloadingStates.contains(t.state)
        case .seeding:
            return Self.seedingStates.contains(t.state)
        case .completed:
            return Self.completedStates.contains(t.state)
        case .stopped:
            return Self.stoppedStates.contains(t.state)
        case .running:
            return !Self.stoppedStates.contains(t.state)
        case .active:
            return t.dlspeed > 0 || t.upspeed > 0
        case .inactive:
            return t.dlspeed <= 0 && t.upspeed <= 0
        case .stalled:
            return t.state == .stalledUP || t.state == .stalledDL
        case .stalledUploading:
            return t.state == .stalledUP
        case .stalledDownloading:
            return t.state == .stalledDL
        case .checking:
            return t.state == .checkingUP || t.state == .checkingDL || t.state == .checkingResumeData
        case .moving:
            return t.state == .moving
        case .errored:
            return t.state.isErrored
        }
    }

    static let downloadingStates: Set<TorrentState> = [
        .downloading, .forcedDL, .metaDL, .forcedMetaDL, .stalledDL, .checkingDL, .stoppedDL, .queuedDL
    ]
    static let seedingStates: Set<TorrentState> = [
        .uploading, .forcedUP, .stalledUP, .checkingUP, .queuedUP
    ]
    static let completedStates: Set<TorrentState> = seedingStates.union([.stoppedUP])
    static let stoppedStates: Set<TorrentState> = [.stoppedUP, .stoppedDL, .missingFiles, .error]
}