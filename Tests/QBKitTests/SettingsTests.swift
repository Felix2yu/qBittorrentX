import Foundation
import Testing
@testable import QBKit

struct SettingsTests {
    @Test func 省流量间隔夹在合法区间() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // 刻意用 let：setter 是 nonmutating，写的是 UserDefaults 那个引用，值本身没变。
        let s = Settings(defaults: defaults)
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
        let s = Settings(defaults: defaults)
        #expect(s.sort == [SortSpec(field: .addedOn, order: .reverse)])
        s.sort = [SortSpec(field: .dlspeed, order: .reverse), SortSpec(field: .name)]
        #expect(s.sort == [SortSpec(field: .dlspeed, order: .reverse), SortSpec(field: .name)])
    }

    @Test func 列宽持久化往返() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = Settings(defaults: defaults)
        #expect(s.columnWidths.isEmpty)
        s.columnWidths = ["name": 320, "size": 120]
        #expect(s.columnWidths == ["name": 320, "size": 120])
        // 第二次读取必须来自 UserDefaults，而不是内存缓存。
        let reloaded = Settings(defaults: defaults)
        #expect(reloaded.columnWidths == ["name": 320, "size": 120])
        reloaded.columnWidths = [:]
        #expect(reloaded.columnWidths.isEmpty)
        // 列宽与排序/显隐各存各的键，互不覆盖。
        s.sort = [SortSpec(field: .name)]
        #expect(s.columnWidths.isEmpty)
        #expect(s.sort == [SortSpec(field: .name)])
    }

    @Test func 列宽过滤非法值() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = Settings(defaults: defaults)
        // 非有限值无法被 JSONEncoder 编码，必须在写入前滤掉，否则整份字典都存不进去。
        s.columnWidths = [
            "name": 320,
            "": 100,
            "zero": 0,
            "negative": -20,
            "infinite": .infinity,
            "nan": .nan,
            "huge": 99_999,
        ]
        #expect(s.columnWidths == ["name": 320])
    }

    @Test func 列宽损坏数据回退为空() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: Settings.Key.columnWidths)
        #expect(Settings(defaults: defaults).columnWidths.isEmpty)
    }
}