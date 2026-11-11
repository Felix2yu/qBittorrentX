import Foundation
import Testing
@testable import QBKit

struct SettingsTests {
    @Test func 省流量间隔夹在合法区间() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var s = Settings(defaults: defaults)
        #expect(s.liteInterval == 30)
        s.liteInterval = 1
        #expect(s.liteInterval == 5)
        s.liteInterval = 9999
        #expect(s.liteInterval == 300)
        s.liteInterval = 60
        #expect(s.liteInterval == 60)
    }

    @Test func 排序持久化往返() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var s = Settings(defaults: defaults)
        #expect(s.sort == [SortSpec(field: .addedOn, order: .reverse)])
        s.sort = [SortSpec(field: .dlspeed, order: .reverse), SortSpec(field: .name)]
        #expect(s.sort == [SortSpec(field: .dlspeed, order: .reverse), SortSpec(field: .name)])
    }
}