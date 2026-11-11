import Foundation
import Testing
@testable import QBKit

struct ByteFormatTests {
    @Test func 字节按1024换算() {
        #expect(ByteFormat.bytes(0) == "0 B")
        #expect(ByteFormat.bytes(1023) == "1023 B")
        #expect(ByteFormat.bytes(1024) == "1.00 KB")
        #expect(ByteFormat.bytes(1_048_576) == "1.00 MB")
        #expect(ByteFormat.bytes(1_073_741_824) == "1.00 GB")
        #expect(ByteFormat.bytes(1_099_511_627_776) == "1.00 TB")
        #expect(ByteFormat.bytes(1_125_899_906_842_624) == "1.00 PB")
        // 超过 PB 不再进位，避免数组越界。
        #expect(ByteFormat.bytes(2_251_799_813_685_248) == "2.00 PB")
        #expect(ByteFormat.bytes(-5) == "0 B")
    }

    @Test func 速度带单位后缀() {
        #expect(ByteFormat.speed(1_048_576) == "1.00 MB/s")
        #expect(ByteFormat.speed(0) == "0 B/s")
    }

    @Test func ETA未知与已完成返回空串() {
        // 空串让调用方整格不渲染，而不是摆「—」占位。
        #expect(ByteFormat.eta(Torrent.etaUnknown) == "")
        #expect(ByteFormat.eta(Torrent.etaUnknown + 1) == "")
        #expect(ByteFormat.eta(0) == "")
        #expect(ByteFormat.eta(-1) == "")
    }

    @Test func ETA逐级降精度() {
        #expect(ByteFormat.eta(45) == "45秒")
        #expect(ByteFormat.eta(125) == "2分5秒")
        #expect(ByteFormat.eta(3725) == "1时2分")
        #expect(ByteFormat.eta(90000) == "1天1时")
    }

    @Test func 分享率与百分比() {
        #expect(ByteFormat.ratio(1.234) == "1.23")
        #expect(ByteFormat.ratio(-1) == "0.00")
        #expect(ByteFormat.percent(0.5) == "50.0%")
        #expect(ByteFormat.percent(1.5) == "100.0%")
        #expect(ByteFormat.percent(-0.2) == "0.0%")
    }

    @Test func 时间戳为0时返回空串() {
        #expect(ByteFormat.timestamp(0) == "")
        #expect(ByteFormat.timestamp(-1) == "")
        #expect(!ByteFormat.timestamp(1_760_000_000).isEmpty)
    }

    @Test func 限速零与负一都是无限制() {
        #expect(ByteFormat.limit(0) == "无限制")
        #expect(ByteFormat.limit(-1) == "无限制")
        #expect(ByteFormat.limit(1024) == "1.00 KB/s")
    }
}