import QBKit
import SwiftUI

/// 多维筛选。计数是**全局**的（与 qB WebUI 一致），切筛选零网络——数据已在内存。
struct SidebarView: View {
    @Bindable var model: AppModel

    private var facets: Facets { model.snapshot.facets }

    var body: some View {
        List {
            Section("状态") {
                ForEach(TorrentFilter.allCases, id: \.self) { filter in
                    row(
                        filter.displayName,
                        count: facets.status[filter] ?? 0,
                        systemImage: icon(filter),
                        selected: model.query.filter == filter
                    ) {
                        model.query.filter = filter
                        model.applyQuery()
                    }
                }
            }

            Section("分类") {
                row("全部分类", count: model.snapshot.loadedCount, systemImage: "square.stack.3d.up",
                    selected: model.query.category == nil) {
                    model.query.category = nil
                    model.applyQuery()
                }
                row("未分类", count: facets.categories[""] ?? 0, systemImage: "questionmark.folder",
                    selected: model.query.category == "") {
                    model.query.category = ""
                    model.applyQuery()
                }
                ForEach(model.snapshot.categories) { category in
                    row(category.name, count: facets.categories[category.name] ?? 0,
                        systemImage: "folder", selected: model.query.category == category.name) {
                        model.query.category = category.name
                        model.applyQuery()
                    }
                }
            }

            // 实测该服务器 0 个标签 → 整节不渲染，不摆空标题。
            if !model.snapshot.tags.isEmpty {
                Section("标签") {
                    ForEach(model.snapshot.tags, id: \.self) { tag in
                        row(tag, count: facets.tags[tag] ?? 0, systemImage: "tag",
                            selected: model.query.tags.contains(tag)) {
                            if model.query.tags.contains(tag) {
                                model.query.tags.remove(tag)
                            } else {
                                model.query.tags.insert(tag)
                            }
                            model.applyQuery()
                        }
                    }
                }
            }

            // 260 个 tracker 已按 host 归并，否则整节不可用。
            if !facets.trackerHosts.isEmpty {
                Section("Tracker") {
                    ForEach(sortedHosts, id: \.self) { host in
                        row(host, count: facets.trackerHosts[host] ?? 0, systemImage: "globe",
                            selected: model.query.trackerHost == host) {
                            model.query.trackerHost = model.query.trackerHost == host ? nil : host
                            model.applyQuery()
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        .safeAreaInset(edge: .bottom) {
            if !model.query.isUnfiltered {
                Button("清除筛选") { model.clearFilters() }
                    .buttonStyle(.borderless)
                    .padding(8)
            }
        }
    }

    /// 按命中数降序，同数按 host 字典序——260 个 host 里用户关心的就是头部那几个。
    private var sortedHosts: [String] {
        facets.trackerHosts.keys.sorted {
            let a = facets.trackerHosts[$0] ?? 0
            let b = facets.trackerHosts[$1] ?? 0
            return a != b ? a > b : $0 < $1
        }
    }

    private func row(
        _ title: String, count: Int, systemImage: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).frame(width: 16)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private func icon(_ filter: TorrentFilter) -> String {
        switch filter {
        case .all: "tray.full"
        case .downloading: "arrow.down.circle"
        case .seeding: "arrow.up.circle"
        case .completed: "checkmark.circle"
        case .stopped: "pause.circle"
        case .running: "play.circle"
        case .active: "bolt"
        case .inactive: "moon"
        case .stalled, .stalledUploading, .stalledDownloading: "hourglass"
        case .checking: "checkmark.shield"
        case .moving: "arrow.right.arrow.left"
        case .errored: "exclamationmark.triangle"
        }
    }
}