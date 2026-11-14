import QBKit
import SwiftUI

public struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage(Settings.Key.columns) private var columns = TableColumnCustomization<Torrent>()

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            if model.section == .archive {
                ArchiveView(model: model)
            } else {
                TorrentTableView(model: model, columns: $columns)
                    .searchable(text: $model.query.search, placement: .toolbar, prompt: "搜索名称")
                    .toolbar { toolbarContent }
                    .inspector(isPresented: $model.inspectorVisible) {
                        TorrentInspector(torrents: model.selectedTorrents)
                            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                    }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(model: model) }
        .onChange(of: model.query) { model.applyQuery() }
        .onChange(of: model.sortOrder) { model.applySort() }
        .onChange(of: model.inspectorVisible) { model.applyInspectorVisible() }
        .sheet(item: $model.activeSheet) { sheet in
            ActionSheetView(model: model, sheet: sheet)
        }
        .confirmationDialog("下载全部任务？", isPresented: $model.isConfirmingFullPull) {
            Button("下载全部（\(model.fullPullEstimate)）") { model.confirmFullPull() }
            Button(model.snapshot.mode == .lite ? "取消" : "改用省流量档", role: .cancel) {
                model.declineFullPull()
            }
        } message: {
            Text(model.fullPullWarning)
        }
        // 引擎拦下首次全量时弹框。取消即降为省流量档，所以这里只负责打开。
        .onChange(of: model.snapshot.needsFullPullApproval) { _, needs in
            if needs { model.isConfirmingFullPull = true }
        }
        .task { await model.bootstrap() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)
            .help("立即刷新")

            Button {
                model.perform(.start, hashes: Array(model.selection))
            } label: {
                Image(systemName: "play")
            }
            .disabled(!canAct)
            .help("开始")

            Button {
                model.perform(.stop, hashes: Array(model.selection))
            } label: {
                Image(systemName: "pause")
            }
            .disabled(!canAct)
            .help("停止")

            Menu {
                Button("强制校验") { model.perform(.recheck, hashes: Array(model.selection)) }
                    .disabled(!canAct)
                Divider()
                Button("设置分类…") { model.activeSheet = .category(Array(model.selection)) }
                    .disabled(!canAct)
                Button("设置标签…") { model.activeSheet = .tags(Array(model.selection)) }
                    .disabled(!canAct)
                Button("上传限速…") { model.activeSheet = .limit(Array(model.selection)) }
                    .disabled(!canAct)
                Divider()
                Button("删除…", role: .destructive) {
                    model.activeSheet = .delete(Array(model.selection))
                }
                .disabled(!canAct)
            } label: {
                Image(systemName: "ellipsis.circle")
            }

            if model.snapshot.mode == .lite {
                Button("加载全部") { model.requestLoadAll() }
            }

            Button {
                model.inspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("显示/隐藏详情")
        }
    }

    private var canAct: Bool {
        !model.selection.isEmpty && !model.selection.contains { model.busyHashes.contains($0) }
    }
}

/// 底部单行状态栏。省流量档必须说实话：只覆盖运行中那批，其余是缓存。
struct StatusBar: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.snapshot.errorMessage ?? model.actionError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                Divider()
            }
            HStack(spacing: 8) {
                let state = model.snapshot.serverState
                Text("↓ \(ByteFormat.speed(state.dlInfoSpeed))").monospacedDigit()
                Text("↑ \(ByteFormat.speed(state.upInfoSpeed))").monospacedDigit()
                separator
                Text(countText).monospacedDigit()
                if selectedCount > 0 {
                    separator
                    Text("已选 \(selectedCount)").monospacedDigit()
                }
                separator
                Text(modeText)
                if model.snapshot.isFromCache {
                    separator
                    Text(cacheText).foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                Text("本次 \(ByteFormat.bytes(trafficBytes))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(trafficHelp)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }

    private var separator: some View {
        Divider().frame(height: 11)
    }

    private var countText: String {
        let s = model.snapshot
        if model.section == .archive {
            return "历史 \(model.archiveResult.total) 条 · 本页 \(model.archiveResult.records.count)"
        }
        if s.mode == .lite {
            return "运行中 \(s.runningHashes.count) · 缓存 \(s.loadedCount)"
        }
        return "\(s.rows.count)/\(s.loadedCount) 个任务"
    }

    private var selectedCount: Int {
        model.section == .archive ? model.archiveSelection.count : model.selection.count
    }

    /// 看历史时报的是 qbhive 的字节，别和 qB 的流量混成一个数。
    private var trafficBytes: Int64 {
        model.section == .archive ? model.archiveResult.bytes : model.snapshot.traffic.totalBytes
    }

    private var trafficHelp: String {
        if model.section == .archive {
            let elapsed = String(format: "%.2fs", model.archiveResult.elapsed)
            return "本次启动以来向 qbhive 请求的字节数；最近一次检索耗时 \(elapsed)"
        }
        return "本次启动以来向服务器请求的字节数"
    }

    private var modeText: String {
        let s = model.snapshot
        if s.mode == .lite {
            return "省流量 · \(Int(model.liteInterval))s"
        }
        return "完整 · \(Int(Settings.defaultFullInterval))s"
    }

    private var cacheText: String {
        let age = Date().timeIntervalSince(model.snapshot.updatedAt)
        if age < 60 { return "缓存 · 刚刚" }
        if age < 3600 { return "缓存 · \(Int(age / 60)) 分钟前" }
        return "缓存 · \(Int(age / 3600)) 小时前"
    }
}