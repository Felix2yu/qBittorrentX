import Foundation
import Testing
@testable import QBKit

struct TorrentFilterTests {
    /// 逐状态断言归属，集合来自 qbhive 对 qB 5.x 的实测复刻。
    @Test func 下载中集合() {
        let expected: [TorrentState] = [
            .downloading, .forcedDL, .metaDL, .forcedMetaDL, .stalledDL, .checkingDL, .stoppedDL, .queuedDL
        ]
        for state in expected {
            #expect(TorrentFilter.downloading.matches(makeTorrent(hash: "h", state: state)))
        }
        for state in [TorrentState.uploading, .stoppedUP, .missingFiles, .error, .moving] {
            #expect(!TorrentFilter.downloading.matches(makeTorrent(hash: "h", state: state)))
        }
    }

    @Test func 做种中不含已停止做种() {
        for state in [TorrentState.uploading, .forcedUP, .stalledUP, .checkingUP, .queuedUP] {
            #expect(TorrentFilter.seeding.matches(makeTorrent(hash: "h", state: state)))
        }
        // stoppedUP 属于「已完成」但不属于「做种中」——实测服务器上 90 条 stoppedUP、seeding 返回 0 条。
        #expect(!TorrentFilter.seeding.matches(makeTorrent(hash: "h", state: .stoppedUP)))
        #expect(TorrentFilter.completed.matches(makeTorrent(hash: "h", state: .stoppedUP)))
    }

    @Test func 已停止含异常状态() {
        for state in [TorrentState.stoppedUP, .stoppedDL, .missingFiles, .error] {
            #expect(TorrentFilter.stopped.matches(makeTorrent(hash: "h", state: state)))
            #expect(!TorrentFilter.running.matches(makeTorrent(hash: "h", state: state)))
        }
        #expect(TorrentFilter.running.matches(makeTorrent(hash: "h", state: .downloading)))
        #expect(TorrentFilter.errored.matches(makeTorrent(hash: "h", state: .missingFiles)))
        #expect(TorrentFilter.errored.matches(makeTorrent(hash: "h", state: .error)))
    }

    @Test func 活跃按速度而非状态判定() {
        let 停滞但有速度 = makeTorrent(hash: "h", state: .stalledDL, dlspeed: 1)
        #expect(TorrentFilter.active.matches(停滞但有速度))
        let 下载中但零速度 = makeTorrent(hash: "h", state: .downloading)
        #expect(!TorrentFilter.active.matches(下载中但零速度))
        #expect(TorrentFilter.inactive.matches(下载中但零速度))
        #expect(TorrentFilter.active.matches(makeTorrent(hash: "h", state: .stoppedUP, upspeed: 5)))
    }

    @Test func 停滞与校验与移动() {
        #expect(TorrentFilter.stalled.matches(makeTorrent(hash: "h", state: .stalledUP)))
        #expect(TorrentFilter.stalled.matches(makeTorrent(hash: "h", state: .stalledDL)))
        #expect(!TorrentFilter.stalled.matches(makeTorrent(hash: "h", state: .downloading)))
        #expect(TorrentFilter.stalledUploading.matches(makeTorrent(hash: "h", state: .stalledUP)))
        #expect(!TorrentFilter.stalledUploading.matches(makeTorrent(hash: "h", state: .stalledDL)))
        #expect(TorrentFilter.stalledDownloading.matches(makeTorrent(hash: "h", state: .stalledDL)))
        for state in [TorrentState.checkingUP, .checkingDL, .checkingResumeData] {
            #expect(TorrentFilter.checking.matches(makeTorrent(hash: "h", state: state)))
        }
        #expect(TorrentFilter.moving.matches(makeTorrent(hash: "h", state: .moving)))
    }

    @Test func 全部放行且未知状态不丢行() {
        let 未知 = makeTorrent(hash: "h", state: .unknown("brandNewState"))
        #expect(TorrentFilter.all.matches(未知))
        #expect(!TorrentFilter.downloading.matches(未知))
        #expect(!TorrentFilter.stopped.matches(未知))
        // 未知状态算「运行中」（不在 stopped 集合里），不会被误藏。
        #expect(TorrentFilter.running.matches(未知))
        #expect(未知.state.displayName == "brandNewState")
    }
}

struct TorrentQueryTests {
    @Test func 各维度之间是AND() {
        let t = makeTorrent(
            hash: "h", name: "Ubuntu 24.04", state: .downloading,
            category: "linux", tags: "iso, 官方", tracker: "https://tracker.example.com/announce"
        )
        #expect(TorrentQuery(filter: .downloading, category: "linux").matches(t))
        #expect(!TorrentQuery(filter: .seeding, category: "linux").matches(t))
        #expect(!TorrentQuery(filter: .downloading, category: "windows").matches(t))
        #expect(TorrentQuery(tags: ["iso"]).matches(t))
        #expect(!TorrentQuery(tags: ["iso", "缺失"]).matches(t))
        #expect(TorrentQuery(trackerHost: "tracker.example.com").matches(t))
        #expect(!TorrentQuery(trackerHost: "other.com").matches(t))
    }

    @Test func 空分类用空串筛选() {
        let 无分类 = makeTorrent(hash: "a", category: "")
        let 有分类 = makeTorrent(hash: "b", category: "linux")
        #expect(TorrentQuery(category: "").matches(无分类))
        #expect(!TorrentQuery(category: "").matches(有分类))
        #expect(TorrentQuery(category: nil).matches(无分类))
        #expect(TorrentQuery(category: nil).matches(有分类))
    }

    @Test func 搜索忽略首尾空白且大小写不敏感() {
        let t = makeTorrent(hash: "h", name: "Ubuntu 24.04 LTS")
        #expect(TorrentQuery(search: "  ubuntu  ").matches(t))
        #expect(TorrentQuery(search: "24.04").matches(t))
        #expect(!TorrentQuery(search: "fedora").matches(t))
        #expect(TorrentQuery(search: "   ").matches(t))
        #expect(TorrentQuery().isUnfiltered)
        #expect(!TorrentQuery(search: "x").isUnfiltered)
    }
}

struct TagsTests {
    @Test func 逗号串拆分并去空白() {
        #expect(makeTorrent(hash: "h", tags: "iso, 官方 ,linux").tags == ["iso", "官方", "linux"])
        #expect(makeTorrent(hash: "h", tags: "").tags == [])
        #expect(makeTorrent(hash: "h", tags: " , ,, ").tags == [])
        #expect(makeTorrent(hash: "h", tags: "单个").tags == ["单个"])
    }

    @Test func trackerHost取URL主机() {
        #expect(makeTorrent(hash: "h", tracker: "https://tracker.example.com:443/announce").trackerHost == "tracker.example.com")
        #expect(makeTorrent(hash: "h", tracker: "udp://open.stealth.si:80/announce").trackerHost == "open.stealth.si")
        #expect(makeTorrent(hash: "h", tracker: "").trackerHost == "")
    }
}