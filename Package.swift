// swift-tools-version: 6.4
import PackageDescription

// 核心包刻意不含 SwiftUI、不含任何宏（@Observable 等）：本机只有 CommandLineTools，
// 宏插件能否工作没有编译证据，把 UI 隔离到 App/ 子包后核心才能在这里 build/test。
let package = Package(
    name: "QBKit",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "QBKit", targets: ["QBKit"]),
        .executable(name: "qbx", targets: ["qbx"])
    ],
    targets: [
        .target(
            name: "QBKit",
            path: "Sources/QBKit",
            swiftSettings: [
                // Swift 6.2 的诊断组控制：升级到 6.4 后把警告当错误。
                .treatAllWarnings(as: .error)
            ]
        ),
        .executableTarget(name: "qbx", dependencies: ["QBKit"], path: "Sources/qbx"),
        .testTarget(name: "QBKitTests", dependencies: ["QBKit"], path: "Tests/QBKitTests")
    ]
)