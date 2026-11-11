import AppKit
import QBKit
import SwiftUI

/// 菜单栏常驻速度。只列运行中的任务——7283 条全塞进菜单不可用。
public struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let running = model.snapshot.rows.filter { $0.dlspeed > 0 || $0.upspeed > 0 }
        if running.isEmpty {
            Text("无活动任务")
        } else {
            ForEach(running.prefix(10)) { t in
                Text("\(t.name) ↓\(ByteFormat.speed(t.dlspeed))")
            }
            if running.count > 10 {
                Text("…另外 \(running.count - 10) 个")
            }
        }
        Divider()
        if let error = model.snapshot.errorMessage {
            Text(error)
            Divider()
        }
        Button("打开主窗口") { openWindow(id: "main") }
        Button("立即刷新") { model.refresh() }
        Divider()
        Button("退出 qBittorrentX") { NSApplication.shared.terminate(nil) }
    }
}

/// 菜单栏标签。**单个 Text**：.menu 风格下复合 label 视图渲染不可靠。
/// monospacedDigit 是必需的，否则数字跳动会让整个菜单栏左右抖。
public struct MenuBarLabel: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Text(title).monospacedDigit()
    }

    private var title: String {
        let s = model.snapshot.serverState
        var parts: [String] = []
        if s.dlInfoSpeed > 0 { parts.append("↓ \(ByteFormat.speed(s.dlInfoSpeed))") }
        if s.upInfoSpeed > 0 { parts.append("↑ \(ByteFormat.speed(s.upInfoSpeed))") }
        return parts.isEmpty ? "↓ ↑" : parts.joined(separator: " ")
    }
}