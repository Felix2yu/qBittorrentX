import AppKit
import QBKit
import Testing
@testable import QBittorrentXUI

struct TorrentColumnTests {
    @Test func 十四列的标识与表头标题都唯一() {
        #expect(TorrentColumn.allCases.count == 14)
        #expect(Set(TorrentColumn.allCases.map(\.id)).count == 14)
        #expect(Set(TorrentColumn.allCases.map(\.title)).count == 14)
        // 顺序即 TorrentTableView 里 .customizationID 的顺序，改一处就必须改这里。
        #expect(TorrentColumn.allCases.map(\.id) == [
            "name", "size", "progress", "dlspeed", "upspeed", "eta", "state",
            "category", "tags", "ratio", "peers", "addedOn", "completionOn", "savePath"
        ])
    }

    @Test func 初始宽度合理且每列都有有限上限() {
        let visible = TorrentColumn.allCases.filter { $0 != .completionOn && $0 != .savePath }
        let total = visible.reduce(CGFloat(0)) { $0 + $1.idealWidth }
        // 原先可见 ideal 合计 1470 pt，现在收敛到 1200 pt 以内。
        #expect(total <= 1200)
        #expect(total >= 1100)
        for column in TorrentColumn.allCases {
            #expect(column.minWidth <= column.idealWidth)
            #expect(column.idealWidth <= column.maxWidth)
            #expect(column.maxWidth.isFinite)
            #expect(column.maxWidth <= 520)
        }
        #expect(TorrentColumn.name.idealWidth <= 240)
    }

    @Test func 持久化值一律钳制到本列区间() {
        #expect(TorrentColumn.name.clamped(320) == 320)
        #expect(TorrentColumn.name.clamped(9_999) == TorrentColumn.name.maxWidth)
        #expect(TorrentColumn.name.clamped(1) == TorrentColumn.name.minWidth)
        #expect(TorrentColumn.name.clamped(.nan) == TorrentColumn.name.idealWidth)
        #expect(TorrentColumn.name.clamped(.infinity) == TorrentColumn.name.idealWidth)
    }

    @Test func 双击自适应按内容增长且受上限约束() {
        let short = Torrent(name: "短")
        let long = Torrent(name: String(repeating: "很长的任务名称", count: 20))
        let shortWidth = TorrentColumn.name.fittedWidth(rows: [short])
        let longWidth = TorrentColumn.name.fittedWidth(rows: [short, long])
        #expect(longWidth > shortWidth)
        #expect(longWidth <= TorrentColumn.name.maxWidth)
        #expect(shortWidth >= TorrentColumn.name.minWidth)
        // 进度列是进度条 + 百分比的 VStack，不按文本测宽，保持默认。
        #expect(TorrentColumn.progress.fittedWidth(rows: [long]) == TorrentColumn.progress.idealWidth)
    }
}
