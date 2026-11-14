import AppKit
import QBKit
import SwiftUI

/// qbhive 退休账本。**只读**：不加种、不删账本记录、不碰 qB 写操作。
/// 过滤/排序/分页全在服务端，这里不二次加工，行序与 qbhive 网页一致。
struct ArchiveView: View {
    @Bindable var model: AppModel

    /// 与 qbhive 网页的排序下拉同一组取值。
    private static let sorts: [(value: String, label: String)] = [
        ("completedOn:desc", "完成时间 ↓"),
        ("completedOn:asc", "完成时间 ↑"),
        ("retiredAt:desc", "退休时间 ↓"),
        ("addedOn:desc", "添加时间 ↓"),
        ("name:asc", "名称 A→Z"),
        ("size:desc", "大小 ↓"),
        ("size:asc", "大小 ↑"),
    ]

    var body: some View {
        Table(model.archiveResult.records, selection: $model.archiveSelection) {
            TableColumn("名称") { r in
                Text(r.name).help(r.name)
            }
            .width(min: 200, ideal: 380)

            TableColumn("大小") { r in
                Text(ByteFormat.bytes(r.size)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            .alignment(.numeric)

            TableColumn("分类") { r in
                if !r.category.isEmpty { Text(r.category) }
            }
            .width(min: 70, ideal: 90)

            TableColumn("完成时间") { r in
                Text(ByteFormat.timestamp(r.completedOn)).monospacedDigit()
            }
            .width(min: 110, ideal: 140)

            TableColumn("退休时间") { r in
                Text(ByteFormat.timestamp(r.retiredAt)).monospacedDigit()
            }
            .width(min: 110, ideal: 140)

            TableColumn("原因") { r in
                if !r.reason.isEmpty { Text(r.reason) }
            }
            .width(min: 76, ideal: 96)

            TableColumn("保存路径") { r in
                if !r.savePath.isEmpty { Text(r.savePath).help(r.savePath) }
            }
            .width(min: 120, ideal: 200)
        }
        .searchable(text: searchText, placement: .toolbar, prompt: "搜索名称 / 保存路径")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle("只看候选", isOn: pendingOnly)
                    .toggleStyle(.switch)
                    .help("只看已建档、还没从 qB 移除的任务")
                Picker("排序", selection: sort) {
                    ForEach(Self.sorts, id: \.value) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.menu)
                Button {
                    model.turnArchivePage(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canTurnArchivePageBack)
                .help("上一页")
                Button {
                    model.turnArchivePage(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canTurnArchivePageForward)
                .help("下一页")
            }
        }
        .overlay { placeholder }
        .contextMenu(forSelectionType: String.self) { hashes in
            ArchiveRowActions(model: model, hashes: Array(hashes))
        }
        // 防抖：条件一变就取消上一次睡眠，300 ms 内连续输入只发一次请求。
        .task(id: searchID) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.searchArchive()
        }
    }

    /// 连接也要进 id：在设置里存完新地址/令牌，历史页得重搜，
    /// 否则它会一直停在「未配置」或上一次的 401 上。
    private struct SearchID: Hashable {
        var query: ArchiveQuery
        var url: String
        var token: String
        var enabled: Bool
    }

    private var searchID: SearchID {
        SearchID(
            query: model.archiveQuery, url: model.archiveURL,
            token: model.archiveToken, enabled: model.archiveEnabled
        )
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.archiveLoading {
            ProgressView().controlSize(.small)
        } else if let error = model.archiveError {
            ContentUnavailableView("检索失败", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.archiveURL.isEmpty {
            ContentUnavailableView(
                "未配置 qbhive 地址", systemImage: "link",
                description: Text("在设置 → QBHive 归档里填地址与令牌。"))
        } else if model.archiveResult.records.isEmpty {
            ContentUnavailableView(
                "没有匹配的记录", systemImage: "tray",
                description: Text("换个关键词，或关掉「只看候选」。"))
        }
    }

    // 改筛选条件一律回到第一页，否则会停在一个越界的 offset 上看到空表。
    private var searchText: Binding<String> {
        Binding(get: { model.archiveQuery.q }, set: { v in edit { $0.q = v } })
    }

    private var pendingOnly: Binding<Bool> {
        Binding(get: { model.archiveQuery.pending }, set: { v in edit { $0.pending = v } })
    }

    private var sort: Binding<String> {
        Binding(
            get: {
                let field = model.archiveQuery.sort.isEmpty ? "completedOn" : model.archiveQuery.sort
                let order = model.archiveQuery.order.isEmpty ? "desc" : model.archiveQuery.order
                return "\(field):\(order)"
            },
            set: { v in
                let parts = v.split(separator: ":")
                edit {
                    $0.sort = parts.first.map { String($0) } ?? "completedOn"
                    $0.order = parts.count > 1 ? String(parts[1]) : "desc"
                }
            }
        )
    }

    private func edit(_ mutate: (inout ArchiveQuery) -> Void) {
        var query = model.archiveQuery
        mutate(&query)
        query.offset = 0
        model.archiveQuery = query
    }
}

/// 行操作只有复制，没有任何写操作。多选时按行拼成多行文本。
struct ArchiveRowActions: View {
    let model: AppModel
    let hashes: [String]

    var body: some View {
        let ids = Set(hashes)
        let records = model.archiveResult.records.filter { ids.contains($0.hash) }
        Button("复制磁链") {
            copy(records.map(\.magnet))
        }
        .disabled(records.allSatisfy { $0.magnet.isEmpty })
        Button("复制保存路径") {
            copy(records.map(\.savePath))
        }
        .disabled(records.allSatisfy { $0.savePath.isEmpty })
    }

    /// 账本只存元数据：savePath 的目录仍在，contentPath 可能指向已被转码替换掉的原片，
    /// 所以复制的是保存路径而不是「当前文件」。
    private func copy(_ values: [String]) {
        let text = values.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}