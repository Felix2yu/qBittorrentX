// swift-tools-version: 6.2
import PackageDescription

// 核心包刻意不含 SwiftUI、不含任何宏（@Observable 等）：本机只有 CommandLineTools，
// 宏插件能否工作没有编译证据，把 UI 隔离到 App/ 子包后核心才能在这里 build/test。
let package = Package(
    name: "QBKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "QBKit", targets: ["QBKit"])
    ],
    targets: [
        .target(name: "QBKit", path: "Sources/QBKit"),
        .testTarget(name: "QBKitTests", dependencies: ["QBKit"], path: "Tests/QBKitTests")
    ]
)