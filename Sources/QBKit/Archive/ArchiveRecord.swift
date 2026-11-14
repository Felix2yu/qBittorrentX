import Foundation

/// qbhive 退休账本的一条记录，JSON 键与 qbhive `archive.Record` 一一对应。
/// 账本是 append-only 演进的老文件，早期记录可能缺键，所以全字段 decodeIfPresent。
public struct ArchiveRecord: Identifiable, Hashable, Sendable, Codable {
    public var id: String { hash }

    public var hash: String
    public var name: String
    public var category: String
    public var tags: String
    public var savePath: String
    public var contentPath: String
    public var tracker: String
    public var magnet: String
    public var size: Int64
    public var uploaded: Int64
    public var addedOn: Int64
    public var completedOn: Int64
    public var retiredAt: Int64
    public var ratio: Double
    public var reason: String

    public init(
        hash: String = "", name: String = "", category: String = "", tags: String = "",
        savePath: String = "", contentPath: String = "", tracker: String = "", magnet: String = "",
        size: Int64 = 0, uploaded: Int64 = 0, addedOn: Int64 = 0, completedOn: Int64 = 0,
        retiredAt: Int64 = 0, ratio: Double = 0, reason: String = ""
    ) {
        self.hash = hash
        self.name = name
        self.category = category
        self.tags = tags
        self.savePath = savePath
        self.contentPath = contentPath
        self.tracker = tracker
        self.magnet = magnet
        self.size = size
        self.uploaded = uploaded
        self.addedOn = addedOn
        self.completedOn = completedOn
        self.retiredAt = retiredAt
        self.ratio = ratio
        self.reason = reason
    }

    /// retiredAt == 0 是「已建档未移除」的候选，> 0 才是真退休。
    public var isRetired: Bool { retiredAt > 0 }

    public enum CodingKeys: String, CodingKey {
        case hash, name, category, tags, savePath, contentPath, tracker, magnet
        case size, uploaded, addedOn, completedOn, retiredAt, ratio, reason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = try c.decodeIfPresent(String.self, forKey: .hash) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        tags = try c.decodeIfPresent(String.self, forKey: .tags) ?? ""
        savePath = try c.decodeIfPresent(String.self, forKey: .savePath) ?? ""
        contentPath = try c.decodeIfPresent(String.self, forKey: .contentPath) ?? ""
        tracker = try c.decodeIfPresent(String.self, forKey: .tracker) ?? ""
        magnet = try c.decodeIfPresent(String.self, forKey: .magnet) ?? ""
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        uploaded = try c.decodeIfPresent(Int64.self, forKey: .uploaded) ?? 0
        addedOn = try c.decodeIfPresent(Int64.self, forKey: .addedOn) ?? 0
        completedOn = try c.decodeIfPresent(Int64.self, forKey: .completedOn) ?? 0
        retiredAt = try c.decodeIfPresent(Int64.self, forKey: .retiredAt) ?? 0
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

/// 服务端分页结果。total 是过滤后的总条数，不是本页条数。
public struct ArchivePage: Hashable, Sendable, Codable {
    public var records: [ArchiveRecord]
    public var total: Int

    public init(records: [ArchiveRecord] = [], total: Int = 0) {
        self.records = records
        self.total = total
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decodeIfPresent([ArchiveRecord].self, forKey: .records) ?? []
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
    }
}