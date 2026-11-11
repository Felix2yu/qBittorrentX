import QBKit
import SwiftUI

/// 分类 / 标签 / 限速 / 删除四个弹框。共用一个外壳，各自只负责取值。
struct ActionSheetView: View {
    let model: AppModel
    let sheet: AppModel.ActionSheet

    @Environment(\.dismiss) private var dismiss
    @State private var category = ""
    @State private var tagsText = ""
    @State private var limitKB = ""
    @State private var deleteFiles = false

    private var torrents: [Torrent] {
        let hashes = Set(sheet.hashes)
        return model.snapshot.rows.filter { hashes.contains($0.hash) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            switch sheet {
            case .category: categoryForm
            case .tags: tagsForm
            case .limit: limitForm
            case .delete: deleteForm
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: isDestructive ? ButtonRole.destructive : nil) {
                    apply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: prefill)
    }

    private var title: String {
        switch sheet {
        case .category: "设置分类"
        case .tags: "设置标签"
        case .limit: "上传限速"
        case .delete: "删除 \(sheet.hashes.count) 个任务"
        }
    }

    private var confirmTitle: String {
        switch sheet {
        case .delete: "删除"
        default: "应用"
        }
    }

    private var isDestructive: Bool {
        if case .delete = sheet { return true }
        return false
    }

    private var isValid: Bool {
        switch sheet {
        case .limit: (Int(limitKB) ?? -1) >= 0
        case .delete: !sheet.hashes.isEmpty
        default: true
        }
    }

    // MARK: - 各表单

    private var categoryForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("作用于 \(sheet.hashes.count) 个任务").foregroundStyle(.secondary)
            Picker("分类", selection: $category) {
                Text("未分类").tag("")
                ForEach(model.snapshot.categories) { c in
                    Text(c.name).tag(c.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var tagsForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("作用于 \(sheet.hashes.count) 个任务").foregroundStyle(.secondary)
            TextField("标签", text: $tagsText, prompt: Text("逗号分隔，留空则清空"))
                .textFieldStyle(.roundedBorder)
            Text("这是覆盖式设置：不在列表里的现有标签会被移除。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var limitForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("作用于 \(sheet.hashes.count) 个任务").foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("0", text: $limitKB)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Text("KB/s")
                Text("0 表示不限速").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var deleteForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(torrents.prefix(5)) { t in
                Text(t.name).lineLimit(1).truncationMode(.middle)
            }
            if torrents.count > 5 {
                Text("…另外 \(torrents.count - 5) 个").foregroundStyle(.secondary)
            }
            Toggle("同时删除硬盘上的文件", isOn: $deleteFiles)
            if deleteFiles {
                Text("文件将被永久删除，无法撤销。")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - 取值与提交

    private func prefill() {
        switch sheet {
        case .category:
            let names = Set(torrents.map(\.category))
            category = names.count == 1 ? (names.first ?? "") : ""
        case .tags:
            // 多选时取并集，让用户看到全部现有标签再决定删哪些。
            let all = Set(torrents.flatMap(\.tags))
            tagsText = all.sorted().joined(separator: ", ")
        case .limit:
            let limits = Set(torrents.map(\.upLimit))
            let current = limits.count == 1 ? (limits.first ?? 0) : 0
            limitKB = current > 0 ? String(current / 1024) : "0"
        case .delete:
            deleteFiles = false
        }
    }

    private func apply() {
        let hashes = sheet.hashes
        switch sheet {
        case .category:
            model.perform(.category(category), hashes: hashes)
        case .tags:
            let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            model.perform(.tags(tags.filter { !$0.isEmpty }), hashes: hashes)
        case .limit:
            let kb = Int64(limitKB) ?? 0
            model.perform(.uploadLimit(kb * 1024), hashes: hashes)
        case .delete:
            model.perform(.delete(deleteFiles: deleteFiles), hashes: hashes)
        }
    }
}