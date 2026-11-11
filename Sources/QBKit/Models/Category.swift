import Foundation

/// qB 的分类。实测 `savePath` 是 camelCase（不是 save_path），所以不需要 CodingKeys 映射。
public struct Category: Identifiable, Hashable, Sendable, Codable {
    public var id: String { name }
    public var name: String
    public var savePath: String

    public init(name: String, savePath: String = "") {
        self.name = name
        self.savePath = savePath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        savePath = try c.decodeIfPresent(String.self, forKey: .savePath) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case name, savePath
    }
}