import Foundation
import Testing
@testable import QBKit

struct TagDiffTests {
    @Test func 覆盖式改标签算出双向差集() {
        let t = makeTorrent(hash: "h", tags: "iso,官方")
        let diff = TagDiff.compute(torrents: [t], desired: ["官方", "新标签"])
        #expect(diff.add == ["新标签"])
        #expect(diff.remove == ["iso"])
    }

    @Test func 目标与现状相同时不发请求() {
        let t = makeTorrent(hash: "h", tags: "iso,官方")
        #expect(TagDiff.compute(torrents: [t], desired: ["官方", "iso"]).isEmpty)
    }

    @Test func 清空标签只需移除() {
        let t = makeTorrent(hash: "h", tags: "iso,官方")
        let diff = TagDiff.compute(torrents: [t], desired: [])
        #expect(diff.add.isEmpty)
        #expect(diff.remove == ["iso", "官方"])
    }

    @Test func 多选时取并集() {
        let a = makeTorrent(hash: "a", tags: "iso")
        let b = makeTorrent(hash: "b", tags: "官方")
        let diff = TagDiff.compute(torrents: [a, b], desired: ["共同"])
        #expect(diff.add == ["共同"])
        #expect(diff.remove == ["iso", "官方"])
    }

    /// 多选里只要有一个已经带目标标签，就不该重复 add；但另一个缺，所以仍要 add。
    @Test func 多选里部分已有目标标签() {
        let a = makeTorrent(hash: "a", tags: "共同")
        let b = makeTorrent(hash: "b", tags: "iso")
        let diff = TagDiff.compute(torrents: [a, b], desired: ["共同"])
        #expect(diff.add == ["共同"])
        #expect(diff.remove == ["iso"])
    }

    @Test func 空白与空串被剔除() {
        let t = makeTorrent(hash: "h", tags: "iso")
        let diff = TagDiff.compute(torrents: [t], desired: ["  官方  ", "", "   "])
        #expect(diff.add == ["官方"])
        #expect(diff.remove == ["iso"])
    }

    @Test func 无选中任务时差集为空() {
        #expect(TagDiff.compute(torrents: [], desired: ["iso"]).isEmpty)
    }

    @Test func 无标签任务加标签() {
        let t = makeTorrent(hash: "h", tags: "")
        let diff = TagDiff.compute(torrents: [t], desired: ["iso"])
        #expect(diff.add == ["iso"])
        #expect(diff.remove.isEmpty)
    }
}