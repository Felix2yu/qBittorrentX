import Foundation
import Testing
@testable import QBKit

struct DataUsagePolicyTests {
    @Test func 自动档按网络路径判定() {
        #expect(DataUsagePolicy.mode(usage: .auto, isExpensive: false, isConstrained: false) == .full)
        #expect(DataUsagePolicy.mode(usage: .auto, isExpensive: true, isConstrained: false) == .lite)
        #expect(DataUsagePolicy.mode(usage: .auto, isExpensive: false, isConstrained: true) == .lite)
        #expect(DataUsagePolicy.mode(usage: .auto, isExpensive: true, isConstrained: true) == .lite)
    }

    @Test func 显式覆盖优先于网络路径() {
        #expect(DataUsagePolicy.mode(usage: .full, isExpensive: true, isConstrained: true) == .full)
        #expect(DataUsagePolicy.mode(usage: .lite, isExpensive: false, isConstrained: false) == .lite)
    }

    @Test func 只有APIkey时强制省流量() {
        // rid 游标绑定 cookie 会话，只有 API key 无法增量。
        // 绝不能退化成 20.6 MB 的全量轮询——这是原方案最危险的漏洞。
        #expect(DataUsagePolicy.effectiveMode(
            usage: .full, isExpensive: false, isConstrained: false, canUseIncrementalSync: false
        ) == .lite)
        #expect(DataUsagePolicy.effectiveMode(
            usage: .auto, isExpensive: false, isConstrained: false, canUseIncrementalSync: true
        ) == .full)
    }

    @Test func 全量体积估算贴着实测数字且无快照时不编数() throws {
        // 真机实测：7283 条 = 27.45 MB（28,783,411 B）。估算偏差控制在 10% 内才有参考价值。
        let 实测: Int64 = 28_783_411
        let 估算 = try #require(DataUsagePolicy.estimatedFullPullBytes(loadedCount: 7283))
        #expect(abs(Double(估算 - 实测)) / Double(实测) < 0.1)
        // 没有磁盘快照就不知道服务端有多少条，返回 nil，UI 不能摆一个编出来的数字。
        #expect(DataUsagePolicy.estimatedFullPullBytes(loadedCount: 0) == nil)
    }
}