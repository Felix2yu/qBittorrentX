import Foundation
import os

public enum Log {
    private static let subsystem = "im.yufei.qbittorrentx"

    public static let net = Logger(subsystem: subsystem, category: "net")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let query = Logger(subsystem: subsystem, category: "query")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}