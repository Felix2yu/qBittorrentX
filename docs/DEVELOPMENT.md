# 开发笔记

本文记录实现过程中的实测数据、设计取舍与联调边界。面向使用者与安装说明见 [README](../README.md)；逐项 UI 验收状态见 [ACCEPTANCE.md](ACCEPTANCE.md)。

## 为什么拆成两个包

项目最初在一台只有 CommandLineTools、没有 Xcode 的机器上开发。当时实测缺少 `libSwiftUIMacros.dylib`，`@State`/`@Binding`/`@AppStorage` 全部无法编译（`libObservationMacros.dylib` 存在，所以 `@Observable` 本身可用）。

```
Package.swift        纯 Foundation 核心 QBKit + 验证 CLI qbx —— 可独立 build / test
App/Package.swift    SwiftUI 外壳 —— 需要 Xcode 工具链
```

**硬约束：`QBKit` 里不出现 `import SwiftUI`、不出现 `@Observable`/`@MainActor`。** 由 `CoreBoundaryTests` 强制，不靠自觉。状态传递靠 `actor` + `Sendable` struct + `AsyncStream<Snapshot>`，`@MainActor @Observable AppModel` 在 UI 包里消费这个 stream，主线程只做一次赋值。

现在 App 包已在 Xcode 27.2 上编译通过。注意路径依赖的包标识是目录名 `qBittorrentX`，不是根包的 `name`（`QBKit`）；写错会在解析依赖时直接失败。

## 数据策略

上千条任务时全量拉取很贵，计费网络下尤其。实测真实服务器 7283 条任务：

| 请求 | 大小 | 耗时 |
|---|---|---|
| `transfer/info` | **264 B** | 0.09 s |
| `torrents/info?filter=running` | **93,790 B**（91.59 KB） | 0.11 s |
| `torrents/info`（全量） | **21,596,980 B**（20.60 MB） | 2.57 s |
| `sync/maindata` 首次全量 | **28,781,968 B**（27.45 MB） | 4.24 s |
| `sync/maindata` 增量 | **10,414 B / 8,236 B** | 0.32 / 0.20 s |

字节数是稳定事实，耗时随链路波动：下面「真机端到端实测」那轮同一个全量端点是 2.38 s。

| 档位 | 冷启动 | 稳态 | 可见范围 |
|---|---|---|---|
| **完整** | 全量 **27.45 MB / 2.38 s**（真机实测）。磁盘快照只能让画面立刻出现，**省不掉这次下载**——rid 续传在真机上不成立，见下 | 增量 2 s，**7.63 / 7.85 / 6.58 KB** 实测 ≈ 13 MB/h | 全部，facet 完整 |
| **省流量** | **91.83 KB / 0.35 s / 33 条运行中**，**永不请求全量** | `transfer/info` 2 s（**264 B**）+ `info?filter=running` 30 s ≈ 11.5 MB/h | 仅运行中；全局速度仍 2 s 新鲜 |

**冷启动省流量档比完整档少 304×**（91.83 KB vs 27.45 MB，同一台真机同一批任务）。

- **首次全量闸门**：完整档第一次联网前**一个字节都不发**（连登录都没有），先弹确认框给出体积估算，用户点头才下载。批准只在本次运行内有效，重启重新问；换服务器作废。CLI 用 `--yes` 当这道确认，不加就拒绝执行。
- **自动判定只是参考**：`NWPathMonitor` 的 `isExpensive`（蜂窝/热点）或 `isConstrained`（低数据模式）为真 → 省流量，路径变化热切换。**实测它在 TUN 代理下看不穿计费热点**（见「真机端到端实测」负结果 2），所以另有首次全量闸门兜底。设置里可显式覆盖成完整/省流量。
- **只有 API key 时强制省流量**：rid 游标绑定 cookie 会话，没有密码就拿不到 cookie，无法增量。这条是硬保险——绝不退化成 20.6 MB 的全量轮询。
- **服务端恒回全量时立即暂停轮询**：带着非 0 rid 却拿回 `full_update`，说明游标被丢了。数据照用，但停掉自动同步并在状态栏说明原因与本轮字节数。实测不暂停的代价是**每 2 s 重下 27.45 MB，4 秒烧掉 54.90 MB**。手动刷新才重试。
- **省流量档不自动升级**。UI 标注「运行中 N · 缓存 M」，另给一个「加载全部」按钮，与闸门共用同一个确认框。缓存里不在本轮 running 集合的行会**变灰**，不能把已停止的任务显示成还在下载。
- 启动先读磁盘快照立即出画面（**0 网络**）并标注「缓存 · N 分钟前」，再带旧 cookie 试 `maindata?rid=N`。**退出前强制落盘**：persist 有 30 s 节流，不强制落盘就会把过期 rid 留给下次启动。

**筛选与排序全在本地做**，切筛选零网络零延迟——这对省流量档是刚需。服务端 `sort` 遇非法字段返回 400（实测），且服务端 filter 无法表达「分类 AND 标签 AND tracker AND 搜索」的组合。

## 真机端到端实测

qB 5.3.0 / WebAPI 2.16.2，7283 条任务。网络恢复后对真实服务器跑完了联调：只读端点全覆盖，写操作只碰了一个已停止任务的标签（往返 8.74 KB，读回确认已还原，见「联调安全边界」）。服务端 4 个分类、0 个标签、260 个 tracker，其中 7155 条 missingFiles。

| 场景 | 请求数 | 流量 | 耗时 | 常驻内存 |
|---|---|---|---|---|
| `probe`（跳过全量端点） | 9 | **247.82 KB** | 单端点 0.04–0.09 s | — |
| 完整档冷启动 | 2 | **27.45 MB** | 2.38 s | 52.6 → 28.1 MB |
| 完整档稳态三轮 | 3 | **7.63 / 7.85 / 6.58 KB** | 0.16–0.19 s | 同上 |
| 省流量档冷启动 | 3 | **91.83 KB** | 0.35 s | **6.5 MB** |
| 省流量档三轮 | 6 | **92.35 KB** | — | 6.5 MB |
| 跨进程 rid 续传（`restart-test`） | 2 | **54.90 MB** | 4 s | 65.5 → 139.9 MB |

完整档磁盘快照 **5.05 MB**。省流量档全程**没有一次全量请求**，完整档留下的快照文件也没被改动（省流量档不写全量快照）。

**负结果 1：rid 续传在真机上不成立。** 装回磁盘上的 cookie 与 rid=5 后请求 `maindata?rid=5`，服务端回 `full_update=true` 且 rid 重置为 1，两次都是全量——4 秒 54.90 MB。客户端侧已核对无误：请求确实带着旧 rid、cookie 也装回了、且没有重新登录，所以这是服务端行为，它不接受跨会话的游标。**措施 1（磁盘快照）仍然有效，措施 2（rid 续传）在这台服务器上省不掉任何流量。**

**负结果 2：`NWPathMonitor` 看不穿 TUN 代理下的计费热点。** 接上热点后活动路径仍报 `isExpensive=false isConstrained=false`：默认路由走代理的 utun 接口，路径里同时挂着 utun/wiredEthernet/wifi，而热点接口自己的 `constrained` 标志落在另一条没有 inet 地址的 inactive 接口上，读不到。→ 自动判定不可信，改为**首次全量前弹确认**。

**这两个负结果各暴露一个真 bug，都已修并补回归测试（都验证过无修复时测试会红）：**

| bug | 真机代价 | 修法 |
|---|---|---|
| 退出前不落盘，盘上 rid 落后于服务端 | 盘上 rid=1 而服务端已到 rid=4，重启带旧 rid 被判过期 → 重下 27.45 MB | `stop()` 改 async 并 `persist(force: true)`；CLI 与 App 的 `applicationWillTerminate` 都调它 |
| 服务端恒回全量时客户端每轮重下 | 每 2 s 27.45 MB，4 秒 54.90 MB | 带非 0 rid 拿回 `full_update` 即暂停自动轮询并告知用户；`refresh()` **不**解除暂停（CLI 逐轮调的就是它），只有 `start()` 解除 |

## 实测性能

release，合成 7283 条 / 6.46 MB payload：

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
11. **SwiftUI `Table` 的私有 `currentWidth` 会覆盖 `.width(min:ideal:max:)` 的 ideal**（macOS 27.2 真机实测）：`TableColumnCustomization` 编进 `torrent.columns` 的 `perColumnState[].currentWidth` 优先级更高——旧偏好里 name=393，启动时列宽就是 393，spec 的 230 完全不生效。所以只调 `.width()` 参数修不好「重启回退」：启动时必须把私有宽度状态剥掉（保留显隐与列顺序），再用自己的 `torrent.columnWidths` 驱动 ideal。
    同轮另外两条实测：`NSTableColumn.identifier` 是**每次启动都变的随机 UUID**，列映射只能靠表头标题，不能靠 id 或下标（验收环境里首列是「大小」而非「名称」）；`NSTableView` 自身也响应双击分隔线，自定义 fit 必须抑制随后 0.4 s 的自动保存，否则原生结果会把按内容测量并钳制过的值覆盖成上限。
12. **钥匙串「始终允许」反复失效，根因是 ad-hoc 签名的 designated requirement 只有 cdhash**（macOS 27.2 实测）：`security dump-keychain -a` 里是 `entry 1 … requirement: cdhash H"1e8e…" (status -2147415734)`，当前 App 的 cdhash 却已是 `ae946…`。`build-app.sh` 原先每次 `codesign --force --sign -` 重打包，二进制一变 cdhash 就变，ACL 里的旧授权立刻作废 → 每次启动重新弹窗；`CredentialStore.load()` 每个地址读 password / apiKey 两个 item，启动时 2 次、打开设置页又 2 次，所以一不留神连着弹好几个框。
    对照实验（同一 bundle，主可执行只改 1 字节）：ad-hoc 的 DR 从 `cdhash H"ae946…"` 变成 `ac16b…`；改成本机 `Apple Development` 证书签名后，DR 恒为 `identifier "im.yufei.qbittorrentx" and anchor apple generic and certificate leaf…`，两次完全相同。**修法**：打包默认用 `security find-identity -v -p codesigning` 选证书（无证书才退回 ad-hoc 并警告）；`AppModel` 缓存凭据，钥匙串只在启动读一次、保存写一次。旧 item 上仍需点最后一次「始终允许」把新 DR 写进 ACL，之后无论怎么重新打包都不再弹。

## 每个提交都能 build + test

每个提交都在临时 worktree 里单独 checkout 后跑 `swift build --build-tests` + `swift test`，**fail=0**。分两轮：前 16 个一轮（测试数 33 → 65 → 113 → 115 → 133 → 135 → 143 → 146），真机联调后新增的 6 个一轮（**147 → 149 → 149 → 154 → 154 → 154，24 个套件**）；其后的文档提交同样逐个跑过。

第一版历史有四处真缺陷，全是同一类——**文件按目录分模块，但依赖不按目录走**：

| 缺陷 | 症状 | 修法 |
|---|---|---|
| manifest 提前声明 `qbx` 可执行目标 | 前 8 个提交连 manifest 都解析不了：`invalid custom path 'Sources/qbx'` | manifest 随 CLI 演进，可执行目标第 9 个提交才声明 |
| `Maindata.swift:73` 调 `TorrentMerger.injectHash` | 第 2–5 个提交 `cannot find 'TorrentMerger' in scope` | `TorrentMerger` 与模型同批 |
| `Snapshot.swift:20` 的 `Facets.status` 键是 `TorrentFilter` | 第 2 个提交 `cannot find type 'TorrentFilter' in scope`，连带 `Facets` 不满足 Hashable | `TorrentFilter` 只依赖 Torrent/TorrentState，与模型同批 |
| `NetTests.swift` 里塞着 `DataUsagePolicyTests`（测的是 Sync 与 Store） | 第 4–5 个提交 `cannot find 'DataUsagePolicy' in scope` | 拆成 `DataUsagePolicyTests`（随同步）、`SettingsTests`（随存储），NetTests 只留 `CredentialsTests`；`makeTorrent` 抽成 `TorrentFixture.swift` 随模型 |

**教训：靠「跑一遍看哪步红」找这类缺陷太慢**（一轮 5 分钟，跑了三轮）。改成先做静态依赖检查：扫出所有顶层声明建「名字 → 文件」表，再对每个提交的文件集算出「已提交的名字」，逐文件找引用了但尚未提交的项目内名字（剥掉注释与字符串避免误报）。一次就列出全部四处，确认修正后的分配零缺依赖，然后才重建历史、跑一次真实逐提交验证收尾。

## 本机假服务器的端到端数字

合成 payload 3.05 MB，真机 maindata 27.45 MB，故绝对值偏小，比例关系可参考：

| 场景 | 实测 |
|---|---|
| 完整档冷启动（`--no-cache`） | 3.05 MB / 0.26 s / 7283 条 |
| 完整档稳态一轮 | **8.59 KB / 0.07–0.10 s / 变更 31 条** |
| 完整档缓存命中 + rid 续传冷启动 | **8.60 KB**（而非 3.05 MB）——**真机上不成立，见负结果 1** |
| 省流量档冷启动（无缓存） | **14.68 KB / 33 条运行中** |
| 省流量档只刷全局速度的一轮 | **201 B** |
| 只有 API key + 显式 `--full` | 仍被强制降为省流量，14.68 KB，无全量请求 |

假服务器本来就是按「接受 rid」写的，所以续传成功只证明客户端管路正确，不证明真服务器行为——真机实测推翻的正是这一点。

## 联调安全边界

真实服务器 7283 条任务、其中 7155 条 missingFiles。**真机上实际执行过的写操作只有一次标签往返**，挑的是一个已停止（`stoppedUP`）、原本无标签的任务，hash 从本地磁盘快照里挑（**0 网络**，不必为了拿 hash 去拉 91 KB 的运行中列表）：

| 步骤 | 请求 | 流量 | 读回结果 |
|---|---|---|---|
| 基线 | `auth/login → torrents/info?hashes=` | 2.91 KB | 差集 新增 [] 移除 [] |
| 加标签 | `auth/login → torrents/addTags` | 0 B | — |
| 覆盖式设回空 | `auth/login → torrents/info → torrents/removeTags` | 2.92 KB | 差集 移除 [qbx-verify] ← **证明真机读回看到了刚加的标签** |
| 复核 | `auth/login → torrents/info?hashes=` | 2.91 KB | 差集 新增 [] 移除 [] ← **已还原** |

合计 **8.74 KB**，服务端状态与联调前一致。这条路径正是 UI 要走的同一段 `TagDiff`（qB 没有覆盖式改标签端点）。

**流量统计只算响应体字节（下行）**，所以 `addTags` 这类 POST 显示 0 B——qB 的写操作响应体是空的。请求体（几十字节的表单）未计入；相对 27 MB 的全量下行可忽略，但读数时要知道这个口径。

**刻意没在真机上做的写操作**：

- `delete` / `recheck`：不可逆 / 触发大批量磁盘 IO，计划里就排除了。
- `stop` / `start`：会真的打断用户正在跑的任务，不属于「无副作用的可逆」。
- `category`：qB 的自动任务管理可能按分类保存路径**搬动磁盘文件**，改回来也不保证搬回原位。
- `limit`：与 `addTags` 走完全相同的 POST 表单路径，标签往返已经证明了这条管路，没必要再动一次真实任务的配置。

这些操作全部在本机假服务器与 URLProtocol 桩上端到端验证过：`tags --set` 差集（449 B）、`category`、`limit 4096 → 0`、`stop → start`、`delete --yes`（7283 → 7282）、`recheck`。`delete` 无 `--yes` 拒绝执行，空 `--hashes` 不发请求。

## 明确未验证

1. **SwiftUI 视图已编译、已启动，但未完成人工逐项目视验收。** 当前验证环境是 SSH 后台会话，`screencapture` 无法访问显示器；已用 App 自截图验证工具栏、搜索框、状态栏等静态布局，其余项见 [ACCEPTANCE.md](ACCEPTANCE.md)。
2. **写操作只验证了标签这一条路径**：真机上做过一次单任务标签往返并读回确认还原（8.74 KB）。`category` / `limit` / `stop` / `start` / `delete` / `recheck` **未在真机上执行**，只在本机假服务器与 URLProtocol 桩上端到端验证过。
3. **API key 的正确 header**：实测那台服务器对客户端出口 IP 免鉴权，带 `X-Webapi-Key`、带 `Authorization: Bearer`、完全不带鉴权头三者都返回完整数据，判定不了。故**双发两个头**兜底，换成开了鉴权的服务器后删掉无效的那个。401/403/重登嗅探分支只能靠 URLProtocol 桩覆盖。
4. **ATS 对裸 IP http 的行为**：`NSAllowsLocalNetworking` 是否放行裸 IP 未验证，故留了 `NSAllowsArbitraryLoads` 兜底。
5. **档位热切换没有被真实路径变化触发过**：只有桩级代次号测试覆盖。而 `NWPathMonitor` 的判定本身已被实测证伪（见负结果 2），所以热切换准不准已经不重要——首次全量闸门才是那道保险。
