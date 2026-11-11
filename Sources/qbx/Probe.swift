import Foundation
import QBKit

/// `qbx probe`：逐个端点打印真实字节数与耗时，复现计划里那张 payload 表。
/// **只读**，不做任何写操作。
enum Probe {
    static func run(_ args: Arguments) async {
        let credentials = CredentialSource.resolve()
        guard !credentials.normalizedBaseURL.isEmpty else {
            print("未配置服务器地址。用 qbx config --url … 或环境变量 QBX_URL。")
            exit(1)
        }
        let client = QBClient(credentials: credentials)
        print("服务器：\(credentials.normalizedBaseURL)")
        print("鉴权：\(credentials.usesAPIKey ? "API key" : "账号密码")")
        print("")

        do {
            let version = try await client.version()
            let api = try await client.webapiVersion()
            print("qBittorrent \(version) / WebAPI \(api)")
            if let cookie = await client.currentCookie() {
                print("会话 cookie 名：\(cookie.name)")
            } else {
                print("会话 cookie 名：(无 —— API key 模式或登录未下发)")
            }
            print("")
        } catch {
            report(error)
            exit(1)
        }

        print(行("端点", "字节", "耗时", "条数"))
        print(String(repeating: "-", count: 72))

        await measure(client, "transfer/info") { _ = try await client.transferInfo() }
        await measure(client, "torrents/tags") { print("  标签：\(try await client.tags())") }
        await measure(client, "torrents/categories") {
            let list = try await client.categories()
            print("  分类：\(list.map(\.name).joined(separator: ", "))")
        }
        for filter in ["active", "running", "downloading"] {
            await measure(client, "torrents/info?filter=\(filter)") {
                let list = try await client.torrents(filter: filter)
                print("  条数：\(list.count)")
            }
        }

        if args.has("full") {
            await measure(client, "torrents/info（全量）") {
                let list = try await client.torrents()
                print("  条数：\(list.count)")
                状态分布(list)
            }
            await measure(client, "sync/maindata?rid=0（全量）") {
                let m = try await client.maindata(rid: 0)
                print("  rid=\(m.rid) full_update=\(m.fullUpdate) 条数=\(m.torrents.count)")
                // 紧接着再请一次，量增量包。
                await measure(client, "sync/maindata?rid=\(m.rid)（增量）") {
                    let d = try await client.maindata(rid: m.rid)
                    print("  rid=\(d.rid) full_update=\(d.fullUpdate) 变更=\(d.torrents.count)")
                    if case .patch(let p) = d.torrents, let first = p.first {
                        let keys = (first.value.objectValue ?? [:]).keys.sorted()
                        print("  增量字段（\(keys.count) 个）：\(keys.joined(separator: ", "))")
                        print("  含 hash？\(keys.contains("hash"))  含 name？\(keys.contains("name"))  含 state？\(keys.contains("state"))")
                    }
                }
            }
        } else {
            print("")
            print("（跳过全量端点：加 --full 才请求，全量约 21–29 MB）")
        }

        let traffic = await client.traffic()
        print("")
        print("本次探测总流量：\(ByteFormat.bytes(traffic.totalBytes))，请求数：\(traffic.requestCount)")
    }

    private static func 状态分布(_ list: [Torrent]) {
        var counts: [String: Int] = [:]
        for t in list { counts[t.state.rawValue, default: 0] += 1 }
        let sorted = counts.sorted { $0.value > $1.value }
        print("  状态分布：\(sorted.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
    }

    /// 手动对齐。`String(format:)` 的 `%s` 对 Swift String、`%d` 对 Int64 都不可靠。
    private static func 行(_ label: String, _ bytes: String, _ seconds: String, _ extra: String = "") -> String {
        let l = label.padding(toLength: max(38, label.count), withPad: " ", startingAt: 0)
        let b = String(repeating: " ", count: max(0, 12 - bytes.count)) + bytes
        let s = String(repeating: " ", count: max(0, 10 - seconds.count)) + seconds
        return extra.isEmpty ? "\(l) \(b) \(s)" : "\(l) \(b) \(s)  \(extra)"
    }

    private static func measure(
        _ client: QBClient, _ label: String, _ body: () async throws -> Void
    ) async {
        let before = await client.traffic()
        let start = ContinuousClock.now
        do {
            try await body()
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let after = await client.traffic()
            let bytes = after.totalBytes - before.totalBytes
            print(行(label, "\(bytes)", String(format: "%.2fs", seconds)))
        } catch {
            print(行(label, "—", "失败"))
            report(error)
        }
    }

    static func report(_ error: any Error) {
        if let qb = error as? QBError {
            print("  错误：\(qb.displayMessage)")
        } else {
            print("  错误：\(error.localizedDescription)")
        }
    }
}