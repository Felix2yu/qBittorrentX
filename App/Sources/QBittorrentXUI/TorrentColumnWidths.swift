import AppKit
import QBKit
import SwiftUI

/// 表格 14 列的唯一布局真源：宽度约束、表头标题、双击自适应时的内容测量都从这里取。
///
/// 为什么要有这张表：SwiftUI `TableColumnCustomization` 虽然会在 `torrent.columns` 里编码
/// `currentWidth`，但没有公开读写接口；启动时 `Table` 又按 `.width(min:ideal:)` 的 ideal
/// 重新分配宽度，于是「看起来存了、重启却回退」。这里把宽度改成我们自己能读回的值，
/// 并且**每列都给有限的 max**，消除窗口变大时列被无上限拉伸。
public enum TorrentColumn: String, CaseIterable, Sendable {
    case name
    case size
    case progress
    case dlspeed
    case upspeed
    case eta
    case state
    case category
    case tags
    case ratio
    case peers
    case addedOn
    case completionOn
    case savePath

    /// 与 `TorrentTableView` 里的 `.customizationID` 完全一致。列顺序由用户拖动决定，
    /// 所以持久化与恢复一律按 id，绝不按下标。
    public var id: String { rawValue }

    /// 与列头标题一致，用于把底层 `NSTableColumn` 映射回 spec。
    public var title: String {
        switch self {
        case .name: "名称"
        case .size: "大小"
        case .progress: "进度"
        case .dlspeed: "下载速度"
        case .upspeed: "上传速度"
        case .eta: "剩余时间"
        case .state: "状态"
        case .category: "分类"
        case .tags: "标签"
        case .ratio: "分享率"
        case .peers: "种子/用户"
        case .addedOn: "添加时间"
        case .completionOn: "完成时间"
        case .savePath: "保存路径"
        }
    }

    public var minWidth: CGFloat {
        switch self {
        case .name: 180
        case .size: 70
        case .progress: 76
        case .dlspeed, .upspeed: 76
        case .eta: 64
        case .state: 72
        case .category: 70
        case .tags: 80
        case .ratio: 56
        case .peers: 64
        case .addedOn, .completionOn: 108
        case .savePath: 120
        }
    }

    /// 可见 12 列 ideal 合计 1198 pt（原先 1470 pt）；隐藏列不计入初始布局。
    public var idealWidth: CGFloat {
        switch self {
        case .name: 230
        case .size: 84
        case .progress: 90
        case .dlspeed, .upspeed: 92
        case .eta: 78
        case .state: 84
        case .category: 84
        case .tags: 96
        case .ratio: 70
        case .peers: 78
        case .addedOn, .completionOn: 120
        case .savePath: 180
        }
    }

    /// 有限上限：窗口变宽时列不再被无限拉伸，长文本列才有较大余量。
    public var maxWidth: CGFloat {
        switch self {
        case .name: 520
        case .size: 130
        case .progress: 160
        case .dlspeed, .upspeed: 140
        case .eta: 120
        case .state: 140
        case .category: 180
        case .tags: 240
        case .ratio: 110
        case .peers: 120
        case .addedOn, .completionOn: 190
        case .savePath: 520
        }
    }

    /// 进度列是 `ProgressView` + 百分比文本的 VStack，按文本测宽没有意义。
    public var isTextMeasurable: Bool { self != .progress }

    /// 把持久化值或测量结果钳制到本列的合法区间。
    public func clamped(_ width: Double) -> CGFloat {
        guard width.isFinite else { return idealWidth }
        return min(max(CGFloat(width), minWidth), maxWidth)
    }

    /// 与单元格渲染口径一致；空串表示该行这一格不渲染。
    public func displayText(for torrent: Torrent) -> String {
        switch self {
        case .name: torrent.name
        case .size: ByteFormat.bytes(torrent.size)
        case .progress: ByteFormat.percent(torrent.progress)
        case .dlspeed: torrent.dlspeed > 0 ? ByteFormat.speed(torrent.dlspeed) : ""
        case .upspeed: torrent.upspeed > 0 ? ByteFormat.speed(torrent.upspeed) : ""
        case .eta: ByteFormat.eta(torrent.eta)
        case .state: torrent.state.displayName
        case .category: torrent.category
        case .tags: torrent.tags.joined(separator: ", ")
        case .ratio: ByteFormat.ratio(torrent.ratio)
        case .peers: "\(torrent.numSeeds)/\(torrent.numLeechs)"
        case .addedOn: ByteFormat.timestamp(torrent.addedOn)
        case .completionOn: ByteFormat.timestamp(torrent.completionOn)
        case .savePath: torrent.savePath
        }
    }

    /// 双击列边界的目标宽度：表头（含排序箭头余量）与当前内容的最长文本取大者，
    /// 加 16 pt 内边距后钳制到 [min, max]。最多测 500 行，避免 7283 行全量测量。
    public func fittedWidth(rows: [Torrent]) -> CGFloat {
        guard isTextMeasurable else { return idealWidth }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        var widest = (title as NSString).size(withAttributes: attributes).width + 18
        for row in rows.prefix(500) {
            let text = displayText(for: row)
            guard !text.isEmpty else { continue }
            widest = max(widest, (text as NSString).size(withAttributes: attributes).width)
        }
        return clamped(Double(ceil(widest) + 16))
    }
}

public extension TableColumn {
    /// 已保存的宽度驱动 ideal：重启后 SwiftUI 一开始就把列放到用户设定的宽度，
    /// 而不是先按固定 ideal 分配、再靠 AppKit 桥接层纠正。
    func qbWidth(_ column: TorrentColumn, widths: [String: Double]) -> Self {
        let ideal = widths[column.id].map { column.clamped($0) } ?? column.idealWidth
        return width(min: column.minWidth, ideal: ideal, max: column.maxWidth)
    }
}
