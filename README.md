# qBittorrentX

原生 macOS qBittorrent WebAPI 客户端。Swift 6 + SwiftUI，**最低 macOS 26 / qBittorrent 5.2**，不向下兼容（直接用 5.x 的 `stop`/`start` 与 `stoppedUP`/`stoppedDL`）。

任务列表 + 多维筛选（状态/分类/标签/tracker）+ 多列排序，附带任务操作（启停/校验/删除/改分类标签/上传限速）与菜单栏速度常驻。**不含添加种子。**

## 为什么拆成两个包

本机只有 CommandLineTools，没有 Xcode。实测缺 `libSwiftUIMacros.dylib`，`@State`/`@Binding`/`@AppStorage` 全部编不过（`libObservationMacros.dylib` 在，所以 `@Observable` 本身可用）。

```
Package.swift        纯 Foundation 核心 QBKit + 验证 CLI qbx —— 本机可 build / test / 实测
App/Package.swift    SwiftUI 外壳 —— 只在有 Xcode 的机器上编译
```

**硬约束：`QBKit` 里不出现 `import SwiftUI`、不出现 `@Observable`/`@MainActor`。** 由 `CoreBoundaryTests` 强制，不靠自觉。状态传递靠 `actor` + `Sendable` struct + `AsyncStream<Snapshot>`，`@MainActor @Observable AppModel` 在 UI 包里消费这个 stream，主线程只做一次赋值。

## 本机能跑什么

```bash
make build        # 编译核心 + CLI
make test         # 146 个测试（swift-testing，不是 XCTest——CLT 里没有 XCTest.framework）
make perf         # release 性能测量
make check-model  # 单独 typecheck AppModel（它不 import SwiftUI，所以本机编得了）
```

不要手敲裸 `swift test`：`libTestingMacros.dylib` 在 `plugins/testing/` 子目录里，默认构建引擎不扫子目录，Makefile 已固化 `-load-plugin-library`。

CLI 是本机唯一的端到端验证载体：

```bash
export QBX_URL=https://bt.example.com QBX_USERNAME=admin QBX_PASSWORD='…'
qbx probe                      # 逐端点真实字节数与耗时
qbx sync --rounds 5            # 逐轮打印 rid / 变更条数 / 本轮字节 / 累计流量 / 内存
qbx sync --lite                # 省流量档
qbx restart-test               # 验证 cookie + rid 跨进程续传
qbx list --filter downloading --sort dlspeed --reverse
qbx help                       # 全部子命令与选项
```

密码与 API key 只进 Keychain（account = `"\(url)#password"` / `"\(url)#apiKey"`），**绝不进 UserDefaults**。

## 数据策略：三档，自动判定

上千条任务时全量拉取很贵，计费网络下尤其。实测真实服务器 7283 条任务：

| 请求 | 大小 | 耗时 |
|---|---|---|
| `transfer/info` | **264 B** | 0.09 s |
| `torrents/info?filter=running` | **93,790 B** | 0.11 s |
| `torrents/info`（全量） | **21,596,980 B** | 2.57 s |
| `sync/maindata` 首次全量 | **28,781,968 B** | 4.24 s |
| `sync/maindata` 增量 | **10,414 B / 8,236 B** | 0.32 / 0.20 s |

| 档位 | 冷启动 | 稳态 | 可见范围 |
|---|---|---|---|
| **完整** | 全量 28.8 MB；命中快照 + rid 续传时降到 ~10 KB | 增量 2 s，~10 KB/次 ≈ 18 MB/h | 全部，facet 完整 |
| **省流量** | ~93 KB，**永不请求全量** | `transfer/info` 2 s + `info?filter=running` 30 s ≈ 11.5 MB/h | 仅运行中；全局速度仍 2 s 新鲜 |

- **自动**：`NWPathMonitor` 的 `isExpensive`（蜂窝/热点）或 `isConstrained`（低数据模式）为真 → 省流量，路径变化热切换。设置里可显式覆盖成完整/省流量。
- **只有 API key 时强制省流量**：rid 游标绑定 cookie 会话，没有密码就拿不到 cookie，无法增量。这条是硬保险——绝不退化成 20.6 MB 的全量轮询。
- **省流量档不自动升级**。UI 标注「运行中 N · 缓存 M」，另给一个「加载全部」按钮，点它前提示约 21–29 MB。缓存里不在本轮 running 集合的行会**变灰**，不能把已停止的任务显示成还在下载。
- 启动先读磁盘快照立即出画面（**0 网络**）并标注「缓存 · N 分钟前」，再带旧 cookie 试 `maindata?rid=N`。

**筛选与排序全在本地做**，切筛选零网络零延迟——这对省流量档是刚需。服务端 `sort` 遇非法字段返回 400（实测），且服务端 filter 无法表达「分类 AND 标签 AND tracker AND 搜索」的组合。

## 实测性能（release，合成 7283 条 / 6.46 MB payload）

| 环节 | release | debug |
|---|---|---|
| 冷启动 Data → Maindata → [Torrent] | **73.7 ms** | 76.5 ms |
| 对照：整表建 JSONValue 树（**不采用**） | 1106.6 ms | 1149.5 ms |
| 过滤 downloading + 排序 + 全局 facet | **6.9 ms** | 27.6 ms |
| 全表按名称排序 + facet | 93.0 ms | 136.9 ms |
| 稳态一轮（解码 + 合并 31 条 + 查询排序） | **12.1 ms** | 32.8 ms |
| 磁盘快照编码 / 解码 | 54.6 / 58.4 ms | 56.3 / 60.5 ms |
| 快照体积 | **4.83 MB** | 同 |
| 全表驻留内存增量 | 45.7 MB | 35.3 MB |

**未达标项照实说**：全表名称排序 93 ms，原目标 50 ms。成本在 `localizedStandardCompare`（中文+数字混排必须用它）。两个替代方案实测都更差——`compare(options: [.numeric,…])` 221 ms 且排序结果不同（Latin 排在中文前），裸 `<` 4.2 ms 但「第10集」会排在「第2集」前面。排序在 actor 内不占主线程，接受 93 ms。

## 实现中被实测推翻的设计

1. **不整表保留 JSON 树。** 原方案「按 hash 存原始 JSON 再合并」在 7283 条上建树 907 ms + 二次编解码 230 ms = 1137 ms；直接从 wire Data 解成 `[String: Torrent]` 只要 73 ms（**15.6×**）。改为 `TorrentPayload` 枚举：全量走 `.full` 直接解码，增量走 `.patch`，`TorrentMerger.apply` **只把本轮有变更的那几十条**编回 JSON 合并。语义等价（有反证测试），但不需要全表建树。
2. **增量包里没有 `hash`/`name`/`state`**，只有 11 个变化字段，且 **`full_update` 键直接缺失**（不是 `false`）→ 必须是 `Bool?`，否则整体解码失败。
3. **字段名是 `private` 不是 wiki 写的 `isPrivate`**，`Category.savePath` 是 camelCase → 用显式 CodingKeys，不用 `.convertFromSnakeCase`。
4. **cookie 名带端口后缀**（实测 `QBT_SID_8989`）→ 从 `Set-Cookie` 里取名字含 `SID` 的那条，不硬编码。
5. **`filter=running`(33) ≠ `active`(21) ≠ `downloading`(38)** → 省流量档统一用 `running`，避免任务在 active/running 间抖动导致行忽隐忽现。
6. **`serverState` 的「解码缓存」与「发布短路比较值」必须是两个字段**，否则完整档第二轮起速度卡住不动。已加回归测试。
7. **URLProtocol 桩必须按 host 分桶**：`.serialized` 只管同一套件内部，swift-testing 默认跨套件并行，共用一份 handler 会互相清空剧本。
8. **`TableColumnBuilder` 的 `buildBlock` 只到 10 个参数，且没有 `buildPartialBlock`**（已核对 SDK swiftinterface）→ 14 列必须拆成两个 `Group`，否则直接编不过。`ViewBuilder` 有变参 `buildBlock`，不受此限。
9. **`Settings` 的 setter 必须 `nonmutating`**：它只是 UserDefaults 的门面，否则 `let settings = Settings()` 连配置都改不了。
10. **`QueryPipeline` 与 Table comparator 的 `savePath` 排序口径必须一致**：一处用裸 `<`、一处用 `.localizedStandard`，`Season10` 与 `Season2` 的先后就相反。已统一为 `localizedStandard` 并加断言全 18 字段行序一致的测试。

## 到有 Xcode 的机器上：验收清单

**本机没有编译过任何 SwiftUI 视图，也没有目视过任何界面。** 已验证的只有：`AppModel` 的 Swift 6 严格并发 typecheck（`make check-model`）、以及每个用到的 SwiftUI API 签名都对着 SDK 的 `.swiftinterface` 核对过。

```bash
cd App
swift build -c release -Xswiftc -disable-sandbox
./build-app.sh
open .build/release/qBittorrentX.app
/usr/sbin/screencapture -x -o /tmp/qbx.png
```

截图注意：需屏幕录制权限；**被拒时会静默返回只含桌面的图，必须检查图里有没有窗口，不能只看退出码**。

逐项核对：

- [ ] 1280×760 默认尺寸下工具栏**一行摆完**，名称列不被裁，底部状态栏不换行
- [ ] 再缩到 ~900 px 宽截一张，同样确认上面三条
- [ ] 14 列都在（完成时间、保存路径默认隐藏），右键列头能显隐、能拖动顺序，重启后保留
- [ ] 点列头排序：下载速度、剩余时间（未知的排最后）、状态、名称（「第2集」在「第10集」前）
- [ ] 侧边栏状态/分类/tracker 计数正确；标签为 0 时整节不渲染；切筛选**不产生网络请求**
- [ ] 详情面板空值整行不渲染（`completionOn == 0`、tracker 空、tags 空都不出现）
- [ ] 设置里填服务器 → 保存并连接 → 数据用量三选 picker 生效
- [ ] 省流量档状态栏显示「运行中 N · 缓存 M」，陈旧行变灰，「加载全部」有流量提示
- [ ] 菜单栏显示 ↓/↑ 速度，数字跳动时菜单栏**不左右抖**
- [ ] 删除弹框「同时删除硬盘上的文件」**默认不勾**
- [ ] 改标签是覆盖式：不在列表里的现有标签被移除

若 SwiftUI 编译失败（宏插件等），退路：`@Observable` → `ObservableObject + @Published`。核心包不受影响，它本来就没用宏。

## 明确未验证

1. **全部 SwiftUI 视图未编译、未运行、未目视。**
2. **cookie + rid 跨进程续传在真机上能否免掉全量**：本机假服务器上成立（`full_update=false`、8.59 KB、未重登），但假服务器本来就是按「接受 rid」写的，**这只证明客户端管路正确，不证明真服务器行为**。
3. **API key 的正确 header**：实测那台服务器对客户端出口 IP 免鉴权，带 `X-Webapi-Key`、带 `Authorization: Bearer`、完全不带鉴权头三者都返回完整数据，判定不了。故**双发两个头**兜底，换成开了鉴权的服务器后删掉无效的那个。401/403/重登嗅探分支只能靠 URLProtocol 桩覆盖。
4. **ATS 对裸 IP http 的行为**：`NSAllowsLocalNetworking` 是否放行裸 IP 未验证，故留了 `NSAllowsArbitraryLoads` 兜底。
5. **`NWPathMonitor` 对 USB 共享网络/热点的 `isExpensive` 判定是否准确**：本机恒为 `false`，热切换分支只有桩级测试覆盖，**没有真实路径变化被触发过**。
6. **真机 payload 与耗时之外的端到端数字都来自本机假服务器**（合成 payload 3.05 MB，真实 maindata 28.78 MB，故绝对值偏小，比例关系可参考）：

   | 场景 | 实测 |
   |---|---|
   | 完整档冷启动（`--no-cache`） | 3.05 MB / 0.26 s / 7283 条 |
   | 完整档稳态一轮 | **8.59 KB / 0.07–0.10 s / 变更 31 条** |
   | 完整档缓存命中 + rid 续传冷启动 | **8.60 KB**（而非 3.05 MB） |
   | 省流量档冷启动（无缓存） | **14.68 KB / 33 条运行中** |
   | 省流量档只刷全局速度的一轮 | **201 B** |
   | 只有 API key + 显式 `--full` | 仍被强制降为省流量，14.68 KB，无全量请求 |

7. **真机联调被网络阻塞，且不是 DNS 问题**：系统 DNS 把服务器域名解析到代理的 fake-IP 段，TLS 握手即断（`SSL_ERROR_SYSCALL`），`apple.com` 正常。绕过 DNS 也一样——公共 DNS（`dig @1.1.1.1` 与 `@223.5.5.5`）给出的是真实的局域网地址，`nc` 探 443 与 8989 均「连接成功」，但 `curl --resolve` 钉到该 IP 后 HTTPS 仍 `SSL_ERROR_SYSCALL`、明文 HTTP 8 s 超时零字节。本机存在 TUN 模式代理的 utun 接口，连裸 IP 的 TCP 也被接管；Cloudflare / Google 的 DoH 同样超时。**要联调得先让代理放行到服务器所在局域网的直连或关掉 TUN**——那是用户的网络配置，没有擅自改动。

## 联调安全边界

真实服务器 7283 条任务、其中 7155 条 missingFiles。联调**只做读操作 + 对单个任务的可逆写操作**（改分类/标签后改回、限速后清零）。**删除与强制校验不在真实服务器上验证**（不可逆 / 会触发大批量磁盘 IO），改用 URLProtocol 桩与本机假服务器覆盖。

写操作已在本机假服务器上端到端验证并全部改回：`tags --set` 差集（`auth/login → torrents/info → addTags → removeTags`，449 B）、`category`、`limit 4096 → 0`、`stop → start`、`delete --yes`、`recheck`。`delete` 无 `--yes` 拒绝执行，空 `--hashes` 不发请求。

## 零第三方依赖

核心：Foundation + Network + Security + os.Logger。UI：SwiftUI + Observation + AppKit。