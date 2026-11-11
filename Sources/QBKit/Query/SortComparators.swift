import Foundation

/// SwiftUI `Table` 的 `sortOrder` 是 `[KeyPathComparator<Torrent>]`，而持久化用的是 `[SortSpec]`
/// （`KeyPathComparator` 不是 Codable）。这里做双向桥接。
///
/// 放在 QBKit 而不是 UI 包：`KeyPathComparator` 属于标准库不是 SwiftUI，
/// 所以这段最容易写错的映射能在本机单测，不必等 Xcode。
extension SortSpec {
    public var comparator: KeyPathComparator<Torrent> {
        switch field {
        case .name: KeyPathComparator(\Torrent.name, comparator: .localizedStandard, order: order)
        case .size: KeyPathComparator(\Torrent.size, order: order)
        case .progress: KeyPathComparator(\Torrent.progress, order: order)
        case .dlspeed: KeyPathComparator(\Torrent.dlspeed, order: order)
        case .upspeed: KeyPathComparator(\Torrent.upspeed, order: order)
        case .eta: KeyPathComparator(\Torrent.etaKey, order: order)
        case .state: KeyPathComparator(\Torrent.stateRank, order: order)
        case .category: KeyPathComparator(\Torrent.categoryKey, order: order)
        case .tags: KeyPathComparator(\Torrent.tagsKey, order: order)
        case .ratio: KeyPathComparator(\Torrent.ratio, order: order)
        case .numSeeds: KeyPathComparator(\Torrent.numSeeds, order: order)
        case .numLeechs: KeyPathComparator(\Torrent.numLeechs, order: order)
        case .addedOn: KeyPathComparator(\Torrent.addedOn, order: order)
        case .completionOn: KeyPathComparator(\Torrent.completionOn, order: order)
        case .lastActivity: KeyPathComparator(\Torrent.lastActivity, order: order)
        case .downloaded: KeyPathComparator(\Torrent.downloaded, order: order)
        case .uploaded: KeyPathComparator(\Torrent.uploaded, order: order)
        case .savePath: KeyPathComparator(\Torrent.savePath, comparator: .localizedStandard, order: order)
        }
    }

    public static func comparators(_ specs: [SortSpec]) -> [KeyPathComparator<Torrent>] {
        specs.map(\.comparator)
    }

    /// Table 回传的 comparators → 可持久化的 specs。认不出的列直接丢弃。
    public static func specs(_ comparators: [KeyPathComparator<Torrent>]) -> [SortSpec] {
        comparators.compactMap { c in
            guard let field = SortField(keyPath: c.keyPath) else { return nil }
            return SortSpec(field: field, order: c.order)
        }
    }
}

extension SortField {
    /// 表格列用的就是这些 key path（含计算属性），所以能靠 `==` 反查字段。
    public init?(keyPath: PartialKeyPath<Torrent>) {
        switch keyPath {
        case \Torrent.name: self = .name
        case \Torrent.size: self = .size
        case \Torrent.progress: self = .progress
        case \Torrent.dlspeed: self = .dlspeed
        case \Torrent.upspeed: self = .upspeed
        case \Torrent.etaKey: self = .eta
        case \Torrent.stateRank: self = .state
        case \Torrent.categoryKey: self = .category
        case \Torrent.tagsKey: self = .tags
        case \Torrent.ratio: self = .ratio
        case \Torrent.numSeeds: self = .numSeeds
        case \Torrent.numLeechs: self = .numLeechs
        case \Torrent.addedOn: self = .addedOn
        case \Torrent.completionOn: self = .completionOn
        case \Torrent.lastActivity: self = .lastActivity
        case \Torrent.downloaded: self = .downloaded
        case \Torrent.uploaded: self = .uploaded
        case \Torrent.savePath: self = .savePath
        default: return nil
        }
    }
}