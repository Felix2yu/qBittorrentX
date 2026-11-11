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
}