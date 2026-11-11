import Foundation

/// `sync/maindata` 的 `server_state`，也是全局速度的唯一来源（省流量档不必再请求 transfer/info 之外的东西）。
/// 字段名是 `dl_info_speed` 而不是 `dl_speed`——后者是 `torrents/info` 里单任务的字段。
public struct ServerState: Hashable, Sendable, Codable {
    public var dlInfoSpeed: Int64
    public var upInfoSpeed: Int64
    public var dlInfoData: Int64
    public var upInfoData: Int64
    public var dlRateLimit: Int64
    public var upRateLimit: Int64
    public var dhtNodes: Int
    public var connectionStatus: String
    public var freeSpaceOnDisk: Int64
    public var globalRatio: Double
    public var queueing: Bool
    public var useAltSpeedLimits: Bool
    /// 服务端建议的刷新间隔（秒）。
    public var refreshInterval: Int

    public init(
        dlInfoSpeed: Int64 = 0, upInfoSpeed: Int64 = 0, dlInfoData: Int64 = 0, upInfoData: Int64 = 0,
        dlRateLimit: Int64 = 0, upRateLimit: Int64 = 0, dhtNodes: Int = 0,
        connectionStatus: String = "", freeSpaceOnDisk: Int64 = 0, globalRatio: Double = 0,
        queueing: Bool = false, useAltSpeedLimits: Bool = false, refreshInterval: Int = 0
    ) {
        self.dlInfoSpeed = dlInfoSpeed
        self.upInfoSpeed = upInfoSpeed
        self.dlInfoData = dlInfoData
        self.upInfoData = upInfoData
        self.dlRateLimit = dlRateLimit
        self.upRateLimit = upRateLimit
        self.dhtNodes = dhtNodes
        self.connectionStatus = connectionStatus
        self.freeSpaceOnDisk = freeSpaceOnDisk
        self.globalRatio = globalRatio
        self.queueing = queueing
        self.useAltSpeedLimits = useAltSpeedLimits
        self.refreshInterval = refreshInterval
    }

    enum CodingKeys: String, CodingKey {
        case dlInfoSpeed = "dl_info_speed"
        case upInfoSpeed = "up_info_speed"
        case dlInfoData = "dl_info_data"
        case upInfoData = "up_info_data"
        case dlRateLimit = "dl_rate_limit"
        case upRateLimit = "up_rate_limit"
        case dhtNodes = "dht_nodes"
        case connectionStatus = "connection_status"
        case freeSpaceOnDisk = "free_space_on_disk"
        case globalRatio = "global_ratio"
        case queueing
        case useAltSpeedLimits = "use_alt_speed_limits"
        case refreshInterval = "refresh_interval"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dlInfoSpeed = try c.decodeIfPresent(Int64.self, forKey: .dlInfoSpeed) ?? 0
        upInfoSpeed = try c.decodeIfPresent(Int64.self, forKey: .upInfoSpeed) ?? 0
        dlInfoData = try c.decodeIfPresent(Int64.self, forKey: .dlInfoData) ?? 0
        upInfoData = try c.decodeIfPresent(Int64.self, forKey: .upInfoData) ?? 0
        dlRateLimit = try c.decodeIfPresent(Int64.self, forKey: .dlRateLimit) ?? 0
        upRateLimit = try c.decodeIfPresent(Int64.self, forKey: .upRateLimit) ?? 0
        dhtNodes = try c.decodeIfPresent(Int.self, forKey: .dhtNodes) ?? 0
        connectionStatus = try c.decodeIfPresent(String.self, forKey: .connectionStatus) ?? ""
        freeSpaceOnDisk = try c.decodeIfPresent(Int64.self, forKey: .freeSpaceOnDisk) ?? 0
        globalRatio = try c.decodeIfPresent(Double.self, forKey: .globalRatio) ?? 0
        queueing = try c.decodeIfPresent(Bool.self, forKey: .queueing) ?? false
        useAltSpeedLimits = try c.decodeIfPresent(Bool.self, forKey: .useAltSpeedLimits) ?? false
        refreshInterval = try c.decodeIfPresent(Int.self, forKey: .refreshInterval) ?? 0
    }
}

/// `transfer/info` 的响应。字段与 server_state 同名，省流量档用它拿全局速度（实测 264 B）。
public struct TransferInfo: Hashable, Sendable, Codable {
    public var dlInfoSpeed: Int64
    public var upInfoSpeed: Int64
    public var dlRateLimit: Int64
    public var upRateLimit: Int64
    public var connectionStatus: String
    public var dhtNodes: Int

    enum CodingKeys: String, CodingKey {
        case dlInfoSpeed = "dl_info_speed"
        case upInfoSpeed = "up_info_speed"
        case dlRateLimit = "dl_rate_limit"
        case upRateLimit = "up_rate_limit"
        case connectionStatus = "connection_status"
        case dhtNodes = "dht_nodes"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dlInfoSpeed = try c.decodeIfPresent(Int64.self, forKey: .dlInfoSpeed) ?? 0
        upInfoSpeed = try c.decodeIfPresent(Int64.self, forKey: .upInfoSpeed) ?? 0
        dlRateLimit = try c.decodeIfPresent(Int64.self, forKey: .dlRateLimit) ?? 0
        upRateLimit = try c.decodeIfPresent(Int64.self, forKey: .upRateLimit) ?? 0
        connectionStatus = try c.decodeIfPresent(String.self, forKey: .connectionStatus) ?? ""
        dhtNodes = try c.decodeIfPresent(Int.self, forKey: .dhtNodes) ?? 0
    }

    public init(
        dlInfoSpeed: Int64 = 0, upInfoSpeed: Int64 = 0, dlRateLimit: Int64 = 0,
        upRateLimit: Int64 = 0, connectionStatus: String = "", dhtNodes: Int = 0
    ) {
        self.dlInfoSpeed = dlInfoSpeed
        self.upInfoSpeed = upInfoSpeed
        self.dlRateLimit = dlRateLimit
        self.upRateLimit = upRateLimit
        self.connectionStatus = connectionStatus
        self.dhtNodes = dhtNodes
    }
}