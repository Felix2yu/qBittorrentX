import Foundation
import Testing

/// 守住两包拆分的编译边界：QBKit 一旦碰 SwiftUI 或宏，本机就再也 build/test 不了，
/// 整个「本机拿真实数字」的前提就没了。这条约束必须由测试而不是自觉来保证。
struct CoreBoundaryTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func coreSources() throws -> [URL] {
        let dir = root.appendingPathComponent("Sources/QBKit")
        let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
        return files.filter { $0.hasSuffix(".swift") }.map { dir.appendingPathComponent($0) }
    }

    @Test func 核心包不importSwiftUI() throws {
        let files = try Self.coreSources()
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("import SwiftUI"), "\(file.lastPathComponent) 引入了 SwiftUI")
            #expect(!text.contains("import SwiftUICore"), "\(file.lastPathComponent) 引入了 SwiftUICore")
        }
    }

    @Test func 核心包不用宏() throws {
        for file in try Self.coreSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("@Observable"), "\(file.lastPathComponent) 用了 @Observable")
            #expect(!text.contains("@MainActor"), "\(file.lastPathComponent) 用了 @MainActor")
        }
    }

    @Test func 核心包无第三方依赖() throws {
        let text = try String(
            contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!text.contains(".package(url:"))
        #expect(!text.contains("defaultLocalization"))
    }
}