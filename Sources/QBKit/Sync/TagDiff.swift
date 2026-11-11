import Foundation

/// qB 没有覆盖式改标签端点，只有 addTags / removeTags，覆盖语义必须自己算差集。
/// 多选时取并集：qB 的两个端点都接受多个 hash，一次请求就能改完。
public struct TagDiff: Hashable, Sendable {
    public var add: [String]
    public var remove: [String]

    public var isEmpty: Bool { add.isEmpty && remove.isEmpty }

    public static func compute(torrents: [Torrent], desired: [String]) -> TagDiff {
        let 目标 = Set(desired.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        var 待加: Set<String> = []
        var 待删: Set<String> = []
        for t in torrents {
            let 现有 = Set(t.tags)
            待加.formUnion(目标.subtracting(现有))
            待删.formUnion(现有.subtracting(目标))
        }
        return TagDiff(add: 待加.sorted(), remove: 待删.sorted())
    }
}