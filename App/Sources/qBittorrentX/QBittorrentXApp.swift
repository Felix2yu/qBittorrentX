import AppKit
import QBittorrentXUI
import SwiftUI

@main
struct QBittorrentXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("qBittorrentX", id: "main") {
            RootView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1280, height: 760)

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// 激活策略恒为 .regular：Dock 图标与菜单栏并存，不做 LSUIElement 切换。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 退出前强制落盘。引擎的 persist 有 30s 节流，不落盘就会把过期 rid 留给下次启动，
    /// 服务端判过期后回 full_update——真机上实测重下过 27.45 MB。
    /// 这里必须阻塞等一下：Task 是异步的，不等就会在落盘完成前退出。
    func applicationWillTerminate(_ notification: Notification) {
        guard let engine = model?.syncEngine else { return }
        let done = DispatchSemaphore(value: 0)
        Task { await engine.stop(); done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }
}