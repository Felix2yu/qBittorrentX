import QBKit
import SwiftUI

/// 任务表格。**排序不在这里做**：点列头只改 sortOrder，落回 SortSpec 后交 SyncEngine 重排，
/// 这样 CLI 与 UI 的行序永远一致（SortComparatorBridgeTests 守着这条）。
struct TorrentTableView: View {
    @Bindable var model: AppModel
    @Binding var columns: TableColumnCustomization<Torrent>

    private func cmp(_ field: SortField) -> KeyPathComparator<Torrent> {
        SortSpec(field: field).comparator
    }

    /// 省流量档只实时刷新运行中的那批，缓存里其余行是陈旧的，必须看得出区别。
    private func isStale(_ torrent: Torrent) -> Bool {
        model.snapshot.mode == .lite && !model.snapshot.runningHashes.contains(torrent.hash)
    }

    var body: some View {
        Table(
            model.snapshot.rows,
            selection: $model.selection,
            sortOrder: $model.sortOrder,
            columnCustomization: $columns
        ) {
            // TableColumnBuilder 的 buildBlock 只到 10 个参数，且**没有 buildPartialBlock**
            // （已核对 SDK swiftinterface）。14 列必须拆成两个 Group，否则直接编不过。
            Group {
                TableColumn("名称", sortUsing: cmp(.name)) { torrent in
                    Text(torrent.name)
                        .foregroundStyle(isStale(torrent) ? .secondary : .primary)
                        .help(isStale(torrent) ? "缓存数据，非实时" : torrent.name)
                }
                .width(min: 200, ideal: 380)
                .customizationID("name")

                TableColumn("大小", sortUsing: cmp(.size)) { torrent in
                    Text(ByteFormat.bytes(torrent.size)).monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                .alignment(.numeric)
                .customizationID("size")

                TableColumn("进度", sortUsing: cmp(.progress)) { torrent in
                    ProgressCell(torrent: torrent)
                }
                .width(min: 80, ideal: 110)
                .customizationID("progress")

                TableColumn("下载速度", sortUsing: cmp(.dlspeed)) { torrent in
                    if torrent.dlspeed > 0 {
                        Text(ByteFormat.speed(torrent.dlspeed)).monospacedDigit()
                    }
                }
                .width(min: 80, ideal: 100)
                .alignment(.numeric)
                .customizationID("dlspeed")

                TableColumn("上传速度", sortUsing: cmp(.upspeed)) { torrent in
                    if torrent.upspeed > 0 {
                        Text(ByteFormat.speed(torrent.upspeed)).monospacedDigit()
                    }
                }
                .width(min: 80, ideal: 100)
                .alignment(.numeric)
                .customizationID("upspeed")

                TableColumn("剩余时间", sortUsing: cmp(.eta)) { torrent in
                    Text(ByteFormat.eta(torrent.eta)).monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                .alignment(.numeric)
                .customizationID("eta")

                TableColumn("状态", sortUsing: cmp(.state)) { torrent in
                    Text(torrent.state.displayName)
                        .foregroundStyle(StateStyle.color(torrent.state))
                }
                .width(min: 76, ideal: 90)
                .customizationID("state")
            }

            Group {
                TableColumn("分类", sortUsing: cmp(.category)) { torrent in
                    Text(torrent.category)
                }
                .width(min: 70, ideal: 90)
                .customizationID("category")

                TableColumn("标签", sortUsing: cmp(.tags)) { torrent in
                    Text(torrent.tags.joined(separator: ", "))
                }
                .width(min: 80, ideal: 120)
                .customizationID("tags")

                TableColumn("分享率", sortUsing: cmp(.ratio)) { torrent in
                    Text(ByteFormat.ratio(torrent.ratio)).monospacedDigit()
                }
                .width(min: 60, ideal: 80)
                .alignment(.numeric)
                .customizationID("ratio")

                TableColumn("种子/用户", sortUsing: cmp(.numSeeds)) { torrent in
                    Text("\(torrent.numSeeds)/\(torrent.numLeechs)").monospacedDigit()
                }
                .width(min: 66, ideal: 80)
                .alignment(.numeric)
                .customizationID("peers")

                TableColumn("添加时间", sortUsing: cmp(.addedOn)) { torrent in
                    Text(ByteFormat.timestamp(torrent.addedOn)).monospacedDigit()
                }
                .width(min: 110, ideal: 140)
                .customizationID("addedOn")

                TableColumn("完成时间", sortUsing: cmp(.completionOn)) { torrent in
                    Text(ByteFormat.timestamp(torrent.completionOn)).monospacedDigit()
                }
                .width(min: 110, ideal: 140)
                .customizationID("completionOn")
                .defaultVisibility(.hidden)

                TableColumn("保存路径", sortUsing: cmp(.savePath)) { torrent in
                    Text(torrent.savePath).help(torrent.savePath)
                }
                .width(min: 120, ideal: 200)
                .customizationID("savePath")
                .defaultVisibility(.hidden)
            }
        }
        .contextMenu(forSelectionType: String.self) { hashes in
            RowActions(model: model, hashes: Array(hashes))
        }
    }
}

/// 工具栏与右键菜单共用同一组动作，避免两处各写一遍启停逻辑。
struct RowActions: View {
    let model: AppModel
    let hashes: [String]

    var body: some View {
        let busy = hashes.isEmpty || hashes.contains { model.busyHashes.contains($0) }
        Button("开始") { model.perform(.start, hashes: hashes) }.disabled(busy)
        Button("停止") { model.perform(.stop, hashes: hashes) }.disabled(busy)
        Button("强制校验") { model.perform(.recheck, hashes: hashes) }.disabled(busy)
        Divider()
        Button("删除…", role: .destructive) { model.activeSheet = .delete(hashes) }.disabled(busy)
    }
}