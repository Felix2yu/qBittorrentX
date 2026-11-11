import Foundation
import QBKit

/// `qbx list` 与任务写操作。筛选排序**全在本地**做，验证的是 UI 将要用的同一条 QueryPipeline。
///
/// 安全边界：`delete` 需要显式 `--yes`，`--delete-files` 默认关。
/// 真实服务器上只跑可逆操作（改分类/标签后改回、限速后清零）。
enum TorrentCommands {
    static func list(_ args: Arguments) async {
        let client = 已配置客户端()
        do {
            // 默认只拉运行中（实测 93 KB）。全量 21 MB 必须显式 --all。
            let 全量 = args.has("all")
            if 全量 { print("注意：--all 会下载全表，实测约 21 MB。") }
            let list = try await client.torrents(filter: 全量 ? nil : "running")
            let query = TorrentQuery(
                filter: args.string("filter").flatMap(TorrentFilter.init(rawValue:)) ?? .all,
                category: args.string("category"),
                tags: Set(args.list("tags")),
                trackerHost: args.string("tracker"),
                search: args.string("search", default: "")
            )
            let 字段 = args.string("sort").flatMap(SortField.init(rawValue:)) ?? .dlspeed
            let spec = SortSpec(field: 字段, order: args.has("reverse") ? .reverse : .forward)
            let result = QueryPipeline.run(
                Dictionary(uniqueKeysWithValues: list.map { ($0.hash, $0) }),
                query: query, sort: [spec]
            )

            let 上限 = args.int("limit", default: 20)
            print("范围：\(全量 ? "全表" : "仅运行中") \(list.count) 条 → 筛选后 \(result.rows.count) 条，按 \(字段.displayName)\(args.has("reverse") ? "降序" : "升序")")
            let traffic = await client.traffic()
            print("本次流量：\(ByteFormat.bytes(traffic.totalBytes))")
            print("")
            print(pad("名称", 34) + pad("状态", 14) + pad("大小", 11) + pad("进度", 8)
                + pad("↓速度", 12) + pad("↑速度", 12) + pad("剩余", 9) + "分类")
            print(String(repeating: "-", count: 110))
            for t in result.rows.prefix(上限) {
                print(
                    pad(截断(t.name, 32), 34) + pad(t.state.rawValue, 14)
                    + pad(ByteFormat.bytes(t.size), 11) + pad(ByteFormat.percent(t.progress), 8)
                    + pad(ByteFormat.speed(t.dlspeed), 12) + pad(ByteFormat.speed(t.upspeed), 12)
                    + pad(ByteFormat.eta(t.eta), 9) + t.category
                )
            }
            if result.rows.count > 上限 { print("… 其余 \(result.rows.count - 上限) 条省略（--limit N 调整）") }

            print("")
            let 状态计数 = result.facets.status
                .filter { $0.value > 0 }
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.displayName) \($0.value)" }
            print("全局状态计数：\(状态计数.joined(separator: " / "))")
            print("分类计数：\(result.facets.categories.sorted { $0.key < $1.key }.map { "\($0.key.isEmpty ? "(无)" : $0.key) \($0.value)" }.joined(separator: " / "))")
            if !result.facets.tags.isEmpty {
                print("标签计数：\(result.facets.tags.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " / "))")
            }
            print("tracker host 数：\(result.facets.trackerHosts.count)")
        } catch {
            report(error)
            exit(1)
        }
    }

    static func write(_ command: String, _ args: Arguments) async {
        let client = 已配置客户端()
        let hashes = args.list("hashes")
        guard !hashes.isEmpty else {
            print("缺少 --hashes a,b（可用 qbx list 查 hash）。")
            exit(1)
        }
        do {
            switch command {
            case "stop":
                try await client.stop(hashes)
            case "start":
                try await client.start(hashes)
            case "recheck":
                print("注意：强制校验会触发磁盘 IO，\(hashes.count) 个任务。")
                try await client.recheck(hashes)
            case "delete":
                let 删文件 = args.has("delete-files")
                guard args.has("yes") else {
                    print("删除不可逆。确认请加 --yes\(删文件 ? "（当前还带了 --delete-files，会连磁盘文件一起删）" : "")。")
                    exit(1)
                }
                try await client.delete(hashes, deleteFiles: 删文件)
            case "category":
                try await client.setCategory(hashes, category: args.string("name", default: ""))
            case "tags":
                try await 改标签(client, hashes, args)
            case "limit":
                guard let 值 = args.int("up") else {
                    print("缺少 --up N（字节/秒，0 表示无限制）。")
                    exit(1)
                }
                try await client.setUploadLimit(hashes, bytesPerSecond: Int64(值))
            default:
                print("未知写操作：\(command)")
                exit(1)
            }
            let traffic = await client.traffic()
            let 请求 = await client.metrics()
            print("已提交 \(command)，\(hashes.count) 个任务。")
            print("请求：\(请求.map(\.path).joined(separator: " → "))")
            print("本次流量：\(ByteFormat.bytes(traffic.totalBytes))")
        } catch {
            report(error)
            exit(1)
        }
    }

    /// qB 没有覆盖式改标签端点，差集自己算——这正是 UI 要走的同一段逻辑。
    private static func 改标签(_ client: QBClient, _ hashes: [String], _ args: Arguments) async throws {
        if let 加 = args.string("add") {
            try await client.addTags(hashes, tags: 加.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            return
        }
        if let 删 = args.string("remove") {
            try await client.removeTags(hashes, tags: 删.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            return
        }
        let 现状 = try await client.torrents(hashes: hashes)
        let diff = TagDiff.compute(torrents: 现状, desired: args.list("set"))
        print("差集：新增 [\(diff.add.joined(separator: ","))]，移除 [\(diff.remove.joined(separator: ","))]")
        if !diff.add.isEmpty { try await client.addTags(hashes, tags: diff.add) }
        if !diff.remove.isEmpty { try await client.removeTags(hashes, tags: diff.remove) }
    }

    private static func 已配置客户端() -> QBClient {
        let credentials = CredentialSource.resolve()
        guard !credentials.normalizedBaseURL.isEmpty else {
            print("未配置服务器地址。用 qbx config --url … 或环境变量 QBX_URL。")
            exit(1)
        }
        return QBClient(credentials: credentials)
    }

    /// 按显示宽度截断：中文占 2 列，直接 prefix 会把表格撑歪。
    private static func 截断(_ s: String, _ 列宽: Int) -> String {
        var 宽 = 0
        var out = ""
        for ch in s {
            let w = ch.unicodeScalars.allSatisfy { $0.value < 0x1100 } ? 1 : 2
            if 宽 + w > 列宽 { return out + "…" }
            out.append(ch)
            宽 += w
        }
        return out
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        let 显示宽 = s.reduce(0) { $0 + ($1.unicodeScalars.allSatisfy { $0.value < 0x1100 } ? 1 : 2) }
        return 显示宽 >= width ? s + " " : s + String(repeating: " ", count: width - 显示宽)
    }

    private static func report(_ error: Error) {
        if let e = error as? QBError {
            print("失败：\(e.displayMessage)")
        } else {
            print("失败：\(error.localizedDescription)")
        }
    }
}