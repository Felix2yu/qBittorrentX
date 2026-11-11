import Foundation

public enum SortField: String, CaseIterable, Codable, Hashable, Sendable {
    case name, size, progress, dlspeed, upspeed, eta, state, category, tags, ratio
    case numSeeds, numLeechs, addedOn, completionOn, lastActivity, downloaded, uploaded, savePath

    public var displayName: String {
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
        case .numSeeds: "种子数"
        case .numLeechs: "用户数"
        case .addedOn: "添加时间"
        case .completionOn: "完成时间"
        case .lastActivity: "最后活动"
        case .downloaded: "已下载"
        case .uploaded: "已上传"
        case .savePath: "保存路径"
        }
    }
}

/// 可持久化的排序描述符。`KeyPathComparator` 是 Sendable + Hashable 但**不是 Codable**，
/// 所以存这一层，到 UI 再映射成 comparator。`SortOrder` 本身是 Codable（已核实 SDK 声明）。
public struct SortSpec: Codable, Hashable, Sendable {
    public var field: SortField
    public var order: SortOrder

    public init(field: SortField, order: SortOrder = .forward) {
        self.field = field
        self.order = order
    }

    public var reversed: SortSpec {
        SortSpec(field: field, order: order == .forward ? .reverse : .forward)
    }
}