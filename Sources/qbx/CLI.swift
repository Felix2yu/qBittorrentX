import Foundation
import QBKit

@main
struct QBX {
    static func main() async {
        let raw = Array(CommandLine.arguments.dropFirst())
        let args = Arguments(raw)
        let command = args.positional.first ?? "help"

        switch command {
        case "help", "--help", "-h":
            usage()
        case "version":
            print("qbx \(QBKit.version)")
        case "config":
            config(args)
        case "probe":
            await Probe.run(args)
        case "sync":
            await SyncCommand.run(args)
        case "restart-test":
            await SyncCommand.restartTest(args)
        case "list":
            await TorrentCommands.list(args)
        case "history":
            await ArchiveCommands.history(args)
        case "stop", "start", "recheck", "delete", "category", "tags", "limit":
            await TorrentCommands.write(command, args)
        default:
            print("未知命令：\(command)\n")
            usage()
            exit(1)
        }
    }

    private static func usage() {
        print("""
        qbx \(QBKit.version) —— qBittorrentX 的验证 CLI（本机没有 Xcode，端到端验证都靠它）

        用法：qbx <命令> [选项]

        命令：
          config              查看或写入凭据（密码/API key 只进 Keychain）
          probe               逐端点打印真实字节数与耗时（只读）
          sync                逐轮同步，打印 rid/变更条数/流量（只读）
          restart-test        验证 cookie + rid 跨进程续传能否免掉全量（只读）
          list                筛选 + 排序后的任务列表（只读，默认只拉运行中）
          history             检索 qbhive 退休账本（只读，走 qbhive 而非 qB）
          stop / start        停止 / 启动任务
          recheck             强制校验（会触发磁盘 IO）
          delete              删除任务（需 --yes，默认不删文件）
          category            改分类
          tags                改标签（--set 覆盖，自己算差集）
          limit               单任务上传限速
          help                显示本帮助

        probe 选项：
          --full              额外请求全量端点（约 21–29 MB，默认跳过）

        sync 选项：
          --lite              强制省流量档（只跟运行中任务，永不请求全量）
          --full              强制完整档（只有 API key 时仍会被强制降为省流量）
          --rounds N          跑 N 轮，0 = 一直跑到 Ctrl-C（默认 5）
          --interval N        省流量档的任务列表间隔秒数（默认 30，范围 5–300）
          --full-interval N   完整档的增量间隔秒数（默认 2）
          --no-cache          跳过磁盘快照，强制冷启动
          --yes               批准首次全量（真机实测 7283 条 = 27.45 MB）；不加则拒绝跑完整档

        restart-test 选项：
          --wait [N]          两段之间等待 N 秒模拟关机（默认 5）
          --yes               批准两次全量下载（合计约 55 MB），不加则拒绝执行

        list 选项：
          --all               拉全表（约 21 MB），默认只拉运行中（约 93 KB）
          --filter F          all/downloading/seeding/completed/stopped/running/active/…
          --category C        分类名，空串表示无分类
          --tags a,b          多标签 AND
          --tracker HOST      按 tracker host
          --search S          名称模糊搜索
          --sort FIELD        name/size/progress/dlspeed/upspeed/eta/state/category/…
          --reverse           降序
          --limit N           最多打印 N 行（默认 20）

        history 选项：
          --query S           名称 / 保存路径模糊搜索
          --category C        分类精确匹配
          --tag T             命中该标签
          --pending           只看已建档未退休的候选
          --sort FIELD        completedOn（默认）/retiredAt/addedOn/name/size
          --order asc|desc    默认 desc
          --limit N           本页条数（默认 20）
          --offset N          翻页起点（默认 0）
          --detail            逐条展开 hash / 路径 / 磁链，空值整行不打印

        写操作选项：
          --hashes a,b        目标任务 hash（必填）
          --name C            category 用的分类名
          --set a,b           tags 覆盖式设置（差集自动算）
          --add a,b           tags 只加
          --remove a,b        tags 只删
          --up N              limit 用的字节/秒，0 表示无限制
          --delete-files      delete 时连磁盘文件一起删（默认不删）
          --yes               delete 的二次确认；sync / restart-test 用它批准全量下载

        config 选项：
          --url URL           服务器地址
          --username NAME     用户名
          --password PASS     密码（写入 Keychain）
          --api-key KEY       API key（写入 Keychain）
          --clear             清除当前服务器的密码与 API key
          --archive-url URL   qbhive 地址（历史检索用，与 qB 地址各自独立）
          --archive-token KEY qbhive 的 QBHIVE_TOKEN（写入 Keychain，不是登录密码）

        凭据也可以用环境变量临时提供，不落盘：
          QBX_URL / QBX_USERNAME / QBX_PASSWORD / QBX_API_KEY
          QBHIVE_URL / QBHIVE_TOKEN

        示例：
          qbx config --url https://bt.example.com --username admin --password '…'
          qbx probe
          qbx sync --lite --rounds 10 --interval 60
          qbx sync --full --yes --rounds 3
          qbx restart-test --wait 10 --yes
          QBX_URL=https://bt.example.com QBX_USERNAME=admin QBX_PASSWORD='…' qbx probe
          qbx config --archive-url http://127.0.0.1:8080 --archive-token '…'
          qbx history --query 沙丘 --limit 10
          qbx history --pending --detail
        """)
    }

    private static func config(_ args: Arguments) {
        let store = CredentialStore()
        var current = store.load()

        if args.has("clear") {
            do {
                try store.clearSecrets()
                print("已清除 \(current.normalizedBaseURL) 的密码与 API key。")
            } catch {
                print("清除失败：\(error)")
                exit(1)
            }
            return
        }

        let 归档改动 = args.string("archive-url") != nil || args.string("archive-token") != nil
        if 归档改动 {
            let archiveStore = ArchiveCredentialStore()
            var connection = archiveStore.load()
            if let v = args.string("archive-url") { connection.baseURL = v }
            if let v = args.string("archive-token") { connection.token = v }
            do {
                try archiveStore.save(connection)
                print("已保存 qbhive 归档连接。令牌写入 Keychain，地址写入 UserDefaults。\n")
                print(归档描述(connection))
            } catch {
                print("保存失败：\(error)")
                exit(1)
            }
        }

        let 有改动 = args.string("url") != nil || args.string("username") != nil
            || args.string("password") != nil || args.string("api-key") != nil
        guard 有改动 else {
            if !归档改动 {
                print(CredentialSource.describe(CredentialSource.resolve()))
                print("")
                print(归档描述(CredentialSource.resolveArchive()))
            }
            return
        }

        if let v = args.string("url") { current.baseURL = v }
        if let v = args.string("username") { current.username = v }
        if let v = args.string("password") { current.password = v }
        if let v = args.string("api-key") { current.apiKey = v }

        do {
            try store.save(current)
            print("已保存。密码与 API key 写入 Keychain，地址与用户名写入 UserDefaults。\n")
            print(CredentialSource.describe(current))
        } catch {
            print("保存失败：\(error)")
            exit(1)
        }
    }

    private static func 归档描述(_ c: ArchiveConnection) -> String {
        [
            "qbhive 地址：\(c.normalizedBaseURL.isEmpty ? "(未配置)" : c.normalizedBaseURL)",
            "qbhive 令牌：\(c.token.isEmpty ? "(未配置)" : "已设置（\(c.token.count) 字符）")",
            "历史视图：\(c.enabled ? "启用" : "未启用（只影响界面，history 命令不看这个开关）")"
        ].joined(separator: "\n")
    }
}