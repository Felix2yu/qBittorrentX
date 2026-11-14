import Foundation
import QBKit

/// `qbx history`：检索 qbhive 的退休账本。**只读**——不加种、不删账本、不碰 qB 写操作。
/// 条数/响应字节/耗时与 probe 同口径，好和 qB 全量那 27 MB 直接对比。
enum ArchiveCommands {
    static func history(_ args: Arguments) async {
        let connection = CredentialSource.resolveArchive()
        guard !connection.normalizedBaseURL.isEmpty else {
            print("未配置 qbhive 地址。用 qbx config --archive-url … 或环境变量 QBHIVE_URL。")
            exit(1)
        }
        let client = ArchiveClient(baseURL: connection.baseURL, token: connection.token)
        print("qbhive：\(connection.normalizedBaseURL)")
        print("令牌：\(connection.token.isEmpty ? "未配置（服务端开了鉴权会返回 401）" : "已设置（\(connection.token.count) 字符）")")

        let query = ArchiveQuery(
            q: args.string("query", default: ""),
            category: args.string("category", default: ""),
            tag: args.string("tag", default: ""),
            pending: args.has("pending"),
            sort: args.string("sort", default: ""),
            order: args.string("order", default: ""),
            limit: max(1, args.int("limit", default: 20)),
            offset: max(0, args.int("offset", default: 0))
        )
        print("条件：\(条件描述(query))")
        print("")

        do {
            let page = try await client.search(query)
            let traffic = await client.traffic()
            let 耗时 = await client.metrics().last?.duration ?? 0
            print("匹配 \(page.total) 条，本页 \(page.records.count) 条；响应 \(ByteFormat.bytes(traffic.totalBytes))，耗时 \(String(format: "%.2fs", 耗时))")
            print("")
            if page.records.isEmpty {
                print("没有匹配的记录。")
            } else if args.has("detail") {
                for r in page.records { 详情(r) }
            } else {
                表格(page.records)
            }
            let 已取 = query.offset + page.records.count
            if page.total > 已取 { print("… 其余 \(page.total - 已取) 条未取（--offset \(已取) 继续）") }
        } catch {
            report(error)
            exit(1)
        }
    }

    private static func 条件描述(_ q: ArchiveQuery) -> String {
        var parts: [String] = []
        if !q.q.isEmpty { parts.append("搜索「\(q.q)」") }
        if !q.category.isEmpty { parts.append("分类「\(q.category)」") }
        if !q.tag.isEmpty { parts.append("标签「\(q.tag)」") }
        if q.pending { parts.append("只看未退休候选") }
        if !q.sort.isEmpty { parts.append("排序 \(q.sort) \(q.order.isEmpty ? "desc" : q.order)") }
        parts.append("offset=\(q.offset) limit=\(q.limit)")
        return parts.joined(separator: "  ")
    }

    private static func 表格(_ records: [ArchiveRecord]) {
        print(TextTable.pad("名称", 34) + TextTable.pad("大小", 11) + TextTable.pad("分类", 12)
            + TextTable.pad("完成时间", 20) + TextTable.pad("退休时间", 20) + TextTable.pad("原因", 12) + "保存路径")
        print(String(repeating: "-", count: 120))
        for r in records {
            print(
                TextTable.pad(TextTable.截断(r.name, 32), 34) + TextTable.pad(ByteFormat.bytes(r.size), 11)
                + TextTable.pad(TextTable.截断(r.category, 10), 12)
                + TextTable.pad(ByteFormat.timestamp(r.completedOn), 20)
                + TextTable.pad(ByteFormat.timestamp(r.retiredAt), 20)
                + TextTable.pad(r.reason, 12) + r.savePath
            )
        }
    }

    /// 逐字段展开，含 hash 与磁链：真机验证守卫时要拿它重加，逃生口要拿 hash 删账本记录。
    /// 空值整行不打印。
    private static func 详情(_ r: ArchiveRecord) {
        print("名称：\(r.name)")
        print("hash：\(r.hash)")
        print("大小：\(ByteFormat.bytes(r.size))  分享率：\(ByteFormat.ratio(r.ratio))  上传：\(ByteFormat.bytes(r.uploaded))")
        var 归属: [String] = []
        if !r.category.isEmpty { 归属.append("分类：\(r.category)") }
        if !r.tags.isEmpty { 归属.append("标签：\(r.tags)") }
        if !归属.isEmpty { print(归属.joined(separator: "  ")) }
        var 时间: [String] = []
        if r.addedOn > 0 { 时间.append("添加：\(ByteFormat.timestamp(r.addedOn))") }
        if r.completedOn > 0 { 时间.append("完成：\(ByteFormat.timestamp(r.completedOn))") }
        if r.retiredAt > 0 { 时间.append("退休：\(ByteFormat.timestamp(r.retiredAt))") }
        if !时间.isEmpty { print(时间.joined(separator: "  ")) }
        if !r.reason.isEmpty { print("退休原因：\(r.reason)") }
        if !r.savePath.isEmpty { print("保存路径：\(r.savePath)") }
        if !r.contentPath.isEmpty { print("原路径：\(r.contentPath)") }
        if !r.tracker.isEmpty { print("tracker：\(r.tracker)") }
        if !r.magnet.isEmpty { print("磁链：\(r.magnet)") }
        print("")
    }

    private static func report(_ error: Error) {
        if let e = error as? QBError {
            print("失败：\(e.displayMessage)")
        } else {
            print("失败：\(error.localizedDescription)")
        }
    }
}