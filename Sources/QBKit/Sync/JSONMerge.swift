import Foundation

public enum JSONMerge {
    /// 逐键覆盖合并。qB 的增量包只含变化字段（实测 11 个，且**不含 hash/name/state**），
    /// 直接反序列化 patch 会把未出现的字段清零，所以必须先合并原始 JSON 再解码。
    /// 数组整体替换——qB 的数组语义就是全量给出。
    public static func merge(_ base: JSONValue?, _ patch: JSONValue) -> JSONValue {
        guard let base, case .object(var merged) = base, case .object(let incoming) = patch else {
            return patch
        }
        for (key, value) in incoming {
            merged[key] = merge(merged[key], value)
        }
        return .object(merged)
    }

    /// 按 key 合并字典并处理 removed。用于 categories（同样是增量 + categories_removed）。
    /// 任务表走 TorrentMerger，不整表建 JSONValue 树。
    public static func mergeDictionary(
        base: [String: JSONValue],
        patch: [String: JSONValue],
        removed: [String]
    ) -> [String: JSONValue] {
        var result = base
        for hash in removed { result.removeValue(forKey: hash) }
        for (hash, value) in patch {
            result[hash] = merge(result[hash], value)
        }
        return result
    }
}