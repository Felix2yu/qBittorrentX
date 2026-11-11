import QBKit
import SwiftUI

/// 属性概览。**零额外请求**：全部字段来自 maindata，不碰 files/trackers/peers 端点。
/// 空值整行不渲染——不摆「—」占位。
struct TorrentInspector: View {
    let torrents: [Torrent]

    var body: some View {
        if torrents.isEmpty {
            ContentUnavailableView("未选中任务", systemImage: "sidebar.right")
        } else if torrents.count > 1 {
            multiSelection
        } else if let torrent = torrents.first {
            single(torrent)
        }
    }

    private func single(_ t: Torrent) -> some View {
        Form {
            Section {
                Text(t.name).font(.headline).textSelection(.enabled)
                LabeledContent("状态") {
                    Text(t.state.displayName).foregroundStyle(StateStyle.color(t.state))
                }
                LabeledContent("进度", value: ByteFormat.percent(t.progress))
                LabeledContent("大小", value: ByteFormat.bytes(t.size))
            }
            Section("传输") {
                if t.dlspeed > 0 { LabeledContent("下载速度", value: ByteFormat.speed(t.dlspeed)) }
                if t.upspeed > 0 { LabeledContent("上传速度", value: ByteFormat.speed(t.upspeed)) }
                if !ByteFormat.eta(t.eta).isEmpty {
                    LabeledContent("剩余时间", value: ByteFormat.eta(t.eta))
                }
                if t.downloaded > 0 { LabeledContent("已下载", value: ByteFormat.bytes(t.downloaded)) }
                if t.uploaded > 0 { LabeledContent("已上传", value: ByteFormat.bytes(t.uploaded)) }
                LabeledContent("分享率", value: ByteFormat.ratio(t.ratio))
                if t.amountLeft > 0 { LabeledContent("剩余", value: ByteFormat.bytes(t.amountLeft)) }
                if t.upLimit > 0 { LabeledContent("上传限速", value: ByteFormat.speed(t.upLimit)) }
                if t.dlLimit > 0 { LabeledContent("下载限速", value: ByteFormat.speed(t.dlLimit)) }
            }
            Section("连接") {
                LabeledContent("种子/用户", value: "\(t.numSeeds)/\(t.numLeechs)")
                if t.availability > 0 {
                    LabeledContent("可用性", value: String(format: "%.2f", t.availability))
                }
                if !t.tracker.isEmpty { LabeledContent("Tracker", value: t.tracker) }
                if t.isPrivate { LabeledContent("私有种子", value: "是") }
            }
            Section("归属") {
                if !t.category.isEmpty { LabeledContent("分类", value: t.category) }
                if !t.tags.isEmpty { LabeledContent("标签", value: t.tags.joined(separator: ", ")) }
                if !t.savePath.isEmpty { LabeledContent("保存路径", value: t.savePath) }
                if !t.contentPath.isEmpty { LabeledContent("内容路径", value: t.contentPath) }
            }
            Section("时间") {
                if t.addedOn > 0 { LabeledContent("添加时间", value: ByteFormat.timestamp(t.addedOn)) }
                if t.completionOn > 0 {
                    LabeledContent("完成时间", value: ByteFormat.timestamp(t.completionOn))
                }
                if t.lastActivity > 0 {
                    LabeledContent("最后活动", value: ByteFormat.timestamp(t.lastActivity))
                }
            }
            Section {
                LabeledContent("Hash") {
                    Text(t.hash).font(.caption).monospaced().textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var multiSelection: some View {
        let totalSize = torrents.reduce(Int64(0)) { $0 + $1.size }
        let dl = torrents.reduce(Int64(0)) { $0 + $1.dlspeed }
        let up = torrents.reduce(Int64(0)) { $0 + $1.upspeed }
        return Form {
            Section {
                LabeledContent("已选中", value: "\(torrents.count) 个任务")
                LabeledContent("合计大小", value: ByteFormat.bytes(totalSize))
                if dl > 0 { LabeledContent("合计下载", value: ByteFormat.speed(dl)) }
                if up > 0 { LabeledContent("合计上传", value: ByteFormat.speed(up)) }
            }
        }
        .formStyle(.grouped)
    }
}