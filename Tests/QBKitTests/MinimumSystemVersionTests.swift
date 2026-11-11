import Foundation
import Testing

/// 两个包的 platforms 与 Info.plist 的 LSMinimumSystemVersion 必须一致，
/// 否则装上去会在启动时被系统拒掉，而且报错信息毫无指向性。
struct MinimumSystemVersionTests {
    /// 用 #filePath 定位仓库根，不依赖 swift test 的当前目录。
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // QBKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // 仓库根

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func 两个包都声明macOS26() throws {
        for path in ["Package.swift", "App/Package.swift"] {
            let text = try read(path)
            #expect(text.contains(".macOS(.v26)"), "\(path) 未声明 .macOS(.v26)")
        }
    }

    @Test func InfoPlist最低版本与包一致() throws {
        let text = try read("App/Resources/Info.plist")
        let data = try #require(text.data(using: .utf8))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        #expect(plist["LSMinimumSystemVersion"] as? String == "26.0")
        #expect(plist["CFBundleIdentifier"] as? String == "im.yufei.qbittorrentx")
        #expect(plist["CFBundleExecutable"] as? String == "qBittorrentX")
        // Dock 图标与菜单栏并存，不能是 LSUIElement。
        #expect(plist["LSUIElement"] as? Bool == false)
        // 非沙箱、无 NSPrincipalClass：SwiftUI 的 @main 自己接管。
        #expect(plist["NSPrincipalClass"] == nil)
    }

    @Test func 局域网http未被ATS挡住() throws {
        let text = try read("App/Resources/Info.plist")
        let data = try #require(text.data(using: .utf8))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let ats = try #require(plist["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        // 裸 IP 是否被 NSAllowsLocalNetworking 放行未验证，所以留了兜底。
        #expect(ats["NSAllowsArbitraryLoads"] as? Bool == true)
        #expect(plist["NSLocalNetworkUsageDescription"] as? String != nil)
    }
}