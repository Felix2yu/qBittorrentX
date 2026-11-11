import Foundation

/// 增量合并到任务表。
///
/// 实测 qB 5.3 的增量包只含 11 个变化字段，**不含 hash/name/state**，直接反序列化 patch
/// 会把其余字段清零。所以必须先合并再解码。
///
/// 但**不整表保留 JSONValue 树**：实测 7283 条建树 907 ms + 二次编解码 230 ms，
/// 而直接从 wire Data 解成 [Torrent] 只要 73 ms（15.6×），还省掉一棵大树的内存。
/// 折中做法是只把「本轮有变更且有基线」的那几十条编回 JSON 合并，再整批解码一次。
public enum TorrentMerger {
    public static func apply(
        base: [String: Torrent], patch: [String: JSONValue], removed: [String]
    ) throws -> [String: Torrent] {
        var result = base
        for hash in removed { result.removeValue(forKey: hash) }
        guard !patch.isEmpty else { return result }

        var 基线: [String: JSONValue] = [:]
        let 有基线 = patch.keys.filter { base[$0] != nil }
        if !有基线.isEmpty {
            var subset: [String: Torrent] = [:]
            subset.reserveCapacity(有基线.count)
            for hash in 有基线 { subset[hash] = base[hash] }
            let data = try JSONEncoder().encode(subset)
            基线 = try JSONDecoder().decode([String: JSONValue].self, from: data)
        }

        var 待解码: [String: JSONValue] = [:]
        待解码.reserveCapacity(patch.count)
        for (hash, value) in patch {
            // 新增任务没有基线，patch 本身就是完整条目。
            待解码[hash] = JSONMerge.merge(基线[hash], value)
        }

        let data = try JSONEncoder().encode(JSONValue.object(待解码))
        var decoded = try JSONDecoder().decode([String: Torrent].self, from: data)
        for hash in decoded.keys { decoded[hash]?.hash = hash }
        for (hash, torrent) in decoded { result[hash] = torrent }
        return result
    }

    /// 全量响应直接解码，不经 JSONValue 树。hash 在 maindata 的条目里缺失，用字典 key 注入。
    public static func injectHash(_ torrents: [String: Torrent]) -> [String: Torrent] {
        var result = torrents
        for hash in result.keys { result[hash]?.hash = hash }
        return result
    }
}