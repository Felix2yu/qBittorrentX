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
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}