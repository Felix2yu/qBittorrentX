import Foundation
import QBKit
import Testing
@testable import QBittorrentXUI

struct ColumnWidthMigrationTests {
    private func stored(_ defaults: UserDefaults) -> [String: Any]? {
        guard let data = defaults.data(forKey: Settings.Key.columns),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return json
    }

    private func fixture(includeWidths: Bool) -> [String: Any] {
        var nameState: [String: Any] = ["visibility": ["automatic": [:]]]
        if includeWidths { nameState["currentWidth"] = 393 }
        return [
            "perColumnState": [
                ["base": ["explicit": ["_0": "name"]]],
                nameState,
                ["base": ["explicit": ["_0": "tags"]]],
                ["visibility": ["hidden": [:]]]
            ],
            "columnOrder": [
                ["base": ["explicit": ["_0": "name"]]],
                ["base": ["explicit": ["_0": "tags"]]]
            ]
        ]
    }

    @Test func 剥掉系统私有宽度但保留显隐与顺序() throws {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            try JSONSerialization.data(withJSONObject: fixture(includeWidths: true)),
            forKey: Settings.Key.columns
        )

        ColumnWidthMigration.stripSavedWidths(defaults: defaults)

        let json = try #require(stored(defaults))
        let states = try #require(json["perColumnState"] as? [[String: Any]])
        #expect(states[1]["currentWidth"] == nil)
        #expect((states[1]["visibility"] as? [String: Any])?["automatic"] != nil)
        #expect((states[3]["visibility"] as? [String: Any])?["hidden"] != nil)
        #expect((json["columnOrder"] as? [Any])?.count == 2)
    }

    @Test func 没有宽度时不动数据() throws {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = try JSONSerialization.data(withJSONObject: fixture(includeWidths: false))
        defaults.set(original, forKey: Settings.Key.columns)

        ColumnWidthMigration.stripSavedWidths(defaults: defaults)

        #expect(defaults.data(forKey: Settings.Key.columns) == original)
    }

    @Test func 损坏数据不会崩溃也不改动() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let broken = Data("not json".utf8)
        defaults.set(broken, forKey: Settings.Key.columns)

        ColumnWidthMigration.stripSavedWidths(defaults: defaults)

        #expect(defaults.data(forKey: Settings.Key.columns) == broken)
    }
}
