import Foundation
@testable import QBKit

/// 合成数据集，规模与状态分布照实测服务器：7283 条，其中 missingFiles 7155、
/// stoppedUP 90、downloading 22、stalledDL 11、stoppedDL 5。
/// **不提交 28 MB 真实 fixture**，用固定种子的 LCG 生成，保证每次跑的数字可比。
enum SyntheticData {
    static let 总数 = 7283

    /// 实测服务器 0 个标签，这里给 20% 的任务挂 2 个标签，比真实情况更悲观。
    private static let 分类 = ["", "linux", "影视", "软件"]
    private static let tracker主机 = (0..<40).map { "tracker\($0).example.com" }

    private struct LCG {
        var state: UInt64 = 0x5DEECE66D
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private static func 状态(_ i: Int) -> TorrentState {
        switch i {
        case 0..<22: .downloading
        case 22..<33: .stalledDL
        case 33..<38: .stoppedDL
        case 38..<128: .stoppedUP
        default: .missingFiles
        }
    }

    static func torrents() -> [String: Torrent] {
        var rng = LCG()
        var result: [String: Torrent] = [:]
        result.reserveCapacity(总数)
        for i in 0..<总数 {
            let hash = String(format: "%040x", i)
            let state = 状态(i)
            let size = Int64(rng.next(50_000) + 1) * 1_048_576
            let progress = state == .downloading || state == .stalledDL ? Double(rng.next(1000)) / 1000 : 1
            let tags = rng.next(5) == 0 ? "iso,官方" : ""
            result[hash] = Torrent(
                hash: hash,
                name: "示例资源 第\(i)集 Ubuntu 24.04.\(i % 10) LTS Desktop amd64 完整版本",
                state: state,
                progress: progress,
                size: size,
                downloaded: Int64(Double(size) * progress),
                uploaded: Int64(rng.next(10_000)) * 1_048_576,
                dlspeed: state == .downloading ? Int64(rng.next(5_000_000)) : 0,
                upspeed: state == .stoppedUP ? Int64(rng.next(500_000)) : 0,
                eta: state == .downloading ? Int64(rng.next(86400)) : Torrent.etaUnknown,
                ratio: Double(rng.next(500)) / 100,
                numSeeds: rng.next(200),
                numLeechs: rng.next(100),
                category: 分类[rng.next(分类.count)],
                tagsRaw: tags,
                savePath: "/data/downloads/\(分类[rng.next(分类.count)])",
                contentPath: "/data/downloads/示例资源 第\(i)集",
                addedOn: 1_700_000_000 + Int64(rng.next(10_000_000)),
                completionOn: progress >= 1 ? 1_750_000_000 : 0,
                lastActivity: 1_760_000_000 - Int64(rng.next(1_000_000)),
                tracker: "https://\(tracker主机[rng.next(tracker主机.count)])/announce",
                amountLeft: Int64(Double(size) * (1 - progress)),
                availability: Double(rng.next(300)) / 100,
                isPrivate: rng.next(2) == 0,
                dlLimit: -1,
                upLimit: -1
            )
        }
        return result
    }

    /// maindata 形状：torrents 字典的 value **不含 hash**，另有 5.3 才有的未建模字段。
    static func rawJSON() -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        result.reserveCapacity(总数)
        for (hash, t) in torrents() {
            result[hash] = .object([
                "name": .string(t.name), "state": .string(t.state.rawValue),
                "progress": .double(t.progress), "size": .int(t.size),
                "downloaded": .int(t.downloaded), "uploaded": .int(t.uploaded),
                "dlspeed": .int(t.dlspeed), "upspeed": .int(t.upspeed),
                "eta": .int(t.eta), "ratio": .double(t.ratio),
                "num_seeds": .int(Int64(t.numSeeds)), "num_leechs": .int(Int64(t.numLeechs)),
                "category": .string(t.category), "tags": .string(t.tagsRaw),
                "save_path": .string(t.savePath), "content_path": .string(t.contentPath),
                "added_on": .int(t.addedOn), "completion_on": .int(t.completionOn),
                "last_activity": .int(t.lastActivity), "tracker": .string(t.tracker),
                "amount_left": .int(t.amountLeft), "availability": .double(t.availability),
                "private": .bool(t.isPrivate), "dl_limit": .int(t.dlLimit), "up_limit": .int(t.upLimit),
                // 5.3 新增、本客户端未建模的键，解码时应被忽略。
                "root_path": .string(t.savePath), "download_path": .string(t.savePath),
                "infohash_v1": .string(hash), "infohash_v2": .string(""),
                "popularity": .double(1.5), "reannounce": .int(300),
                "seen_complete": .int(t.lastActivity), "time_active": .int(3600),
                "connections_count": .int(12), "comment": .string(""), "seq_dl": .bool(false)
            ])
        }
        return result
    }

    /// 实测的增量 patch：只有 11 个变化字段，**不含 hash/name/state**。
    static func 增量patch(_ hash: String, 序号: Int) -> JSONValue {
        .object([
            "availability": .double(0.5), "connections_count": .int(12),
            "dlspeed": .int(Int64(序号) * 1024), "downloaded": .int(Int64(序号) * 2048),
            "eta": .int(600), "last_activity": .int(1_760_000_000),
            "popularity": .double(1.5), "ratio": .double(0.25),
            "reannounce": .int(300), "seen_complete": .int(1_759_000_000),
            "time_active": .int(3600)
        ])
    }
}