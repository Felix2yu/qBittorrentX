import Foundation
import QBKit

/// `qbx sync`：逐轮打印模式、rid、变更条数、本轮字节与累计流量。
/// `qbx restart-test`：验证 cookie + rid 跨进程续传能否免掉全量。
/// 两个命令都**只读**。
enum SyncCommand {
    static func run(_ args: Arguments) async {
        let credentials = CredentialSource.resolve()
        guard !credentials.normalizedBaseURL.isEmpty else {
            print("未配置服务器地址。用 qbx config --url … 或环境变量 QBX_URL。")
            exit(1)
        }

        let 轮数上限 = args.int("rounds", default: 5)
        let cache = SnapshotCache()
        let engine = SyncEngine(client: QBClient(credentials: credentials), cache: cache)
        let usage: Settings.DataUsage = args.has("lite") ? .lite : (args.has("full") ? .full : .auto)

        // 路径变化时热切换档位。代次号由引擎负责，在途结果不会串进新档位。
        let watcher = NetworkPathWatcher()
        watcher.start { expensive, constrained in
            let 新档 = DataUsagePolicy.effectiveMode(
                usage: usage, isExpensive: expensive, isConstrained: constrained,
                canUseIncrementalSync: credentials.canUseIncrementalSync
            )
            Task {
                guard await engine.currentMode() != 新档 else { return }
                await engine.setMode(新档)
                print("\n[路径变化] 切换到 \(新档.displayName) 档")
            }
        }
        // 首次 path 回调是异步的，等一下才能拿到真实的 isExpensive/isConstrained。
        try? await Task.sleep(for: .milliseconds(300))
        let path = watcher.current
        let mode = DataUsagePolicy.effectiveMode(
            usage: usage, isExpensive: path.isExpensive, isConstrained: path.isConstrained,
            canUseIncrementalSync: credentials.canUseIncrementalSync
        )

        let full间隔 = args.double("full-interval") ?? Settings.defaultFullInterval
        let lite间隔 = args.double("interval") ?? Double(Settings.defaultLiteInterval)
        await engine.setIntervals(full: full间隔, lite: lite间隔)
        await engine.setMode(mode)

        print("服务器：\(credentials.normalizedBaseURL)")
        print("档位：\(mode.displayName)（网络 isExpensive=\(path.isExpensive) isConstrained=\(path.isConstrained)）")
        if mode == .lite {
            print("任务列表间隔 \(Int(lite间隔))s，全局速度间隔 2s；永不请求全量")
        } else {
            print("增量间隔 \(full间隔)s")
        }
        if !credentials.canUseIncrementalSync {
            print("注意：只有 API key 时 rid 无法续传，已强制省流量档。")
        }

        if args.has("no-cache") {
            print("按 --no-cache 跳过磁盘快照，本轮走冷启动。")
        } else {
            await engine.restoreFromCache()
            let s = await engine.currentSnapshot()
            if s.loadedCount > 0 {
                let 时间 = ByteFormat.timestamp(Int64(s.updatedAt.timeIntervalSince1970))
                print("命中磁盘快照：\(s.loadedCount) 条，保存于 \(时间)，rid=\(await engine.debugState().rid)")
            } else {
                print("无磁盘快照，本轮走冷启动。")
            }
        }
        print("")
        print("轮次  档位  rid    已加载  变更  本轮字节    累计流量   耗时     内存")
        print(String(repeating: "-", count: 86))

        var 上一轮 = await engine.loadedTorrents()
        var 轮次 = 0
        while 轮数上限 == 0 || 轮次 < 轮数上限 {
            轮次 += 1
            let start = ContinuousClock.now
            await engine.refresh()
            let 用时 = ContinuousClock.now - start
            let 耗时 = Double(用时.components.seconds) + Double(用时.components.attoseconds) / 1e18

            let s = await engine.currentSnapshot()
            let 当前 = await engine.loadedTorrents()
            let 变更 = 当前.reduce(0) { $0 + (上一轮[$1.key] != $1.value ? 1 : 0) }
                + 上一轮.keys.reduce(0) { $0 + (当前[$1] == nil ? 1 : 0) }
            上一轮 = 当前

            if let err = s.errorMessage {
                print("\(pad("\(轮次)", 4))  \(pad(s.mode.rawValue, 4))  同步失败：\(err)")
            } else {
                print(
                    pad("\(轮次)", 4) + "  " + pad(s.mode.rawValue, 4) + "  "
                    + pad("\(await engine.debugState().rid)", 5) + "  "
                    + pad("\(s.loadedCount)", 6) + "  " + pad("\(变更)", 4) + "  "
                    + pad(ByteFormat.bytes(s.traffic.lastRoundBytes), 10) + "  "
                    + pad(ByteFormat.bytes(s.traffic.totalBytes), 9) + "  "
                    + pad(String(format: "%.2fs", 耗时), 7) + "  "
                    + String(format: "%.1f MB", 常驻内存())
                )
            }

            if 轮数上限 != 0 && 轮次 >= 轮数上限 { break }
            try? await Task.sleep(for: .seconds(s.mode == .full ? full间隔 : 2))
        }

        watcher.stop()
        await engine.stop()
        let s = await engine.currentSnapshot()
        print("")
        print("累计 \(s.traffic.requestCount) 次请求 / \(ByteFormat.bytes(s.traffic.totalBytes))")
        print("↓ \(ByteFormat.speed(s.serverState.dlInfoSpeed))  ↑ \(ByteFormat.speed(s.serverState.upInfoSpeed))")
        if let total = s.totalCount {
            print("服务端总数 \(total)，已加载 \(s.loadedCount)")
        } else {
            print("省流量档：只跟运行中 \(s.runningHashes.count) 条，服务端总数未知")
        }
        if cache.fileSize > 0 {
            print("磁盘快照：\(ByteFormat.bytes(cache.fileSize))")
        }
    }

    /// 计划里明确标注「未验证」的一项：重启后带旧 cookie + 旧 rid 请求，服务端还给不给增量。
    static func restartTest(_ args: Arguments) async {
        let credentials = CredentialSource.resolve()
        guard !credentials.normalizedBaseURL.isEmpty else {
            print("未配置服务器地址。用 qbx config --url … 或环境变量 QBX_URL。")
            exit(1)
        }
        guard credentials.canUseIncrementalSync else {
            print("只有 API key 时没有 cookie 会话，rid 无从续传——本测试不适用。")
            exit(1)
        }

        let cache = SnapshotCache()
        print("服务器：\(credentials.normalizedBaseURL)")
        print("第一段：全新会话拉一次全量，然后把 cookie + rid 写盘。")
        let 首个 = QBClient(credentials: credentials)
        do {
            let m = try await 首个.maindata(rid: 0)
            guard case .full(let list) = m.torrents else {
                print("首轮竟然不是 full_update，服务端行为与预期不符。")
                exit(1)
            }
            let cookie = await 首个.currentCookie()
            let 字节 = await 首个.traffic().totalBytes
            let 状态 = m.serverState.flatMap { try? $0.decoded(ServerState.self) } ?? ServerState()
            print("  full_update=\(m.fullUpdate) rid=\(m.rid) 条数=\(list.count) 流量=\(ByteFormat.bytes(字节))")
            print("  cookie 名：\(cookie?.name ?? "(无)")")
            try cache.save(CachedSnapshot(
                serverURL: credentials.normalizedBaseURL, savedAt: Date(), rid: m.rid,
                cookie: cookie, torrents: list, serverState: 状态,
                categories: [], tags: []
            ))
            print("  快照已写盘：\(ByteFormat.bytes(cache.fileSize))")

            if args.has("wait") {
                let 秒 = args.int("wait", default: 5)
                print("  等待 \(秒)s 模拟关机…")
                try? await Task.sleep(for: .seconds(秒))
            }

            print("")
            print("第二段：新 client（无任何内存状态），只装回磁盘上的 cookie，带旧 rid 请求。")
            let 重启后 = QBClient(credentials: credentials)
            await 重启后.restore(cookie: cookie)
            let start = ContinuousClock.now
            let d = try await 重启后.maindata(rid: m.rid)
            let 用时 = ContinuousClock.now - start
            let 耗时 = Double(用时.components.seconds) + Double(用时.components.attoseconds) / 1e18
            let 新流量 = await 重启后.traffic()
            let 请求 = await 重启后.metrics()

            print("  请求序列：\(请求.map { "\($0.path)(\($0.bytes) B)" }.joined(separator: " → "))")
            print("  full_update=\(d.fullUpdate) rid=\(d.rid) 变更条数=\(d.torrents.count)")
            print("  流量=\(ByteFormat.bytes(新流量.totalBytes)) 耗时=\(String(format: "%.2fs", 耗时))")
            print("")
            if d.fullUpdate {
                print("结论：续传失败。服务端仍返回全量，重启免不了这次下载。")
                print("      磁盘快照（措施 1）仍然有效，但 rid 续传（措施 2）在这台服务器上不成立。")
            } else {
                print("结论：续传成功。重启后只下载了 \(ByteFormat.bytes(新流量.totalBytes))，而不是全量。")
            }
            if 请求.contains(where: { $0.path == "/api/v2/auth/login" }) {
                print("      注意：旧 cookie 被拒，重新登录过——续传的前提没成立。")
            }
        } catch {
            report(error)
            exit(1)
        }
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    private static func 常驻内存() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private static func report(_ error: Error) {
        if let e = error as? QBError {
            print("失败：\(e.displayMessage)")
        } else {
            print("失败：\(error.localizedDescription)")
        }
    }
}