import Foundation
import QBKit

/// 启动迁移：剥掉 `TableColumnCustomization` 私有的 `currentWidth`。
///
/// 真机实测（macOS 27.2 / Xcode 27.2）：SwiftUI 会把每列宽度以 `currentWidth` 编进
/// `torrent.columns`，而且它的优先级**高于** `.width(min:ideal:max:)` 的 ideal ——
/// 旧偏好里 name=393，启动时列宽就是 393，spec 的 230 完全不生效，这正是「重启后回退」的根因。
/// 列宽改由 `torrent.columnWidths` 独占，所以每次启动把系统保存的宽度状态剥掉，
/// 只保留列顺序与显隐，SwiftUI 才会采用 `qbWidth` 的 ideal（用户保存值或默认 spec）。
///
/// JSON 结构属于 SwiftUI 私有格式，任何解析/写回失败都静默跳过，绝不影响列顺序与显隐。
public enum ColumnWidthMigration {
    public static func stripSavedWidths(defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: Settings.Key.columns),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var states = json["perColumnState"] as? [Any]
        else { return }

        var changed = false
        for (index, item) in states.enumerated() {
            guard var state = item as? [String: Any],
                  state["currentWidth"] != nil
            else { continue }
            state.removeValue(forKey: "currentWidth")
            states[index] = state
            changed = true
        }
        guard changed else { return }
        json["perColumnState"] = states
        guard let migrated = try? JSONSerialization.data(withJSONObject: json) else { return }
        defaults.set(migrated, forKey: Settings.Key.columns)
    }
}
