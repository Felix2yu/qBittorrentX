import Foundation

/// 磁盘快照的内容。连同 cookie 与 rid 一起存，启动时先试着只拿增量。
public struct CachedSnapshot: Codable, Sendable {
    public var serverURL: String
    public var savedAt: Date
    public var rid: Int
    public var cookie: SessionCookie?
    public var torrents: [String: Torrent]
    public var serverState: ServerState
    public var categories: [Category]
    public var tags: [String]

    public init(
        serverURL: String, savedAt: Date = Date(), rid: Int = 0, cookie: SessionCookie? = nil,
        torrents: [String: Torrent] = [:], serverState: ServerState = ServerState(),
        categories: [Category] = [], tags: [String] = []
    ) {
        self.serverURL = serverURL
        self.savedAt = savedAt
        self.rid = rid
        self.cookie = cookie
        self.torrents = torrents
        self.serverState = serverState
        self.categories = categories
        self.tags = tags
    }
}

/// 启动先读缓存立即显示，**0 网络**。实测 7283 条快照 4.83 MB、编解码各约 55 ms。
public struct SnapshotCache: Sendable {
    public let directory: URL
    public let fileURL: URL

    /// 默认 ~/Library/Application Support/qBittorrentX。测试可注入临时目录。
    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qBittorrentX", isDirectory: true)
        self.directory = dir
        self.fileURL = dir.appendingPathComponent("snapshot.json")
    }

    /// 服务器地址变了就丢弃缓存——旧任务表对新服务器毫无意义。
    public func load(serverURL: String) -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let cached = try? JSONDecoder().decode(CachedSnapshot.self, from: data) else { return nil }
        guard cached.serverURL == serverURL else { return nil }
        return cached
    }

    public func save(_ snapshot: CachedSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        // 先写临时文件再原子替换：半截的快照会让下次启动直接丢掉缓存。
        let temp = fileURL.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
    }

    public func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public var fileSize: Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}