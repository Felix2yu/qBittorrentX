// swift-tools-version: 6.4
import PackageDescription

// SwiftUI 外壳。**本机不编译**：CommandLineTools 缺 libSwiftUIMacros.dylib，
// @State / @AppStorage / @Binding 全部不可用（已实测）。到有 Xcode 的机器上再 build。
// 核心逻辑全在 QBKit（纯 Foundation），这里只做视图与 @MainActor 状态。
let package = Package(
    name: "qBittorrentX",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "qBittorrentX", targets: ["qBittorrentX"])
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .target(
            name: "QBittorrentXUI",
            dependencies: [.product(name: "QBKit", package: "qBittorrentX")],
            path: "Sources/QBittorrentXUI",
            swiftSettings: [
                // Swift 6.2 默认 MainActor 隔离：UI 层整体在主线程，减少标注。
                .defaultIsolation(MainActor.self)
            ]
        ),
        .executableTarget(
            name: "qBittorrentX",
            dependencies: ["QBittorrentXUI"],
            path: "Sources/qBittorrentX",
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ]
        ),
        .testTarget(
            name: "QBittorrentXUITests",
            dependencies: ["QBittorrentXUI"],
            path: "Tests/QBittorrentXUITests"
        )
    ]
)