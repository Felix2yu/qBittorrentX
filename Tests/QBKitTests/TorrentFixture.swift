import Foundation
@testable import QBKit

/// 构造测试任务。默认值刻意都相同，方便验证排序 tiebreak。
/// 单独一个文件：模型、查询、标签差集几个模块的测试都要用它，不能寄居在查询测试里。
func makeTorrent(
    hash: String, name: String = "任务", state: TorrentState = .downloading,
    dlspeed: Int64 = 0, upspeed: Int64 = 0, size: Int64 = 1024, progress: Double = 0,
    eta: Int64 = Torrent.etaUnknown, category: String = "", tags: String = "",
    tracker: String = "", addedOn: Int64 = 0, ratio: Double = 0
) -> Torrent {
    Torrent(
        hash: hash, name: name, state: state, progress: progress, size: size,
        dlspeed: dlspeed, upspeed: upspeed, eta: eta, ratio: ratio,
        category: category, tagsRaw: tags, addedOn: addedOn, tracker: tracker
    )
}