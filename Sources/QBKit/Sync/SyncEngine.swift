import Foundation

/// 同步引擎。**所有重活都在 actor 内**，主线程只做一次赋值。
///
/// 完整档走 `sync/maindata` 增量；省流量档走 `transfer/info`（2 s）+ `torrents/info?filter=running`
/// （默认 30 s）两条独立节奏，**永不请求全量**。
public actor SyncEngine {
    private let client: QBClient
    private let cache: SnapshotCache

    private var torrents: [String: Torrent] = [:]
    private var serverStateRaw: JSONValue?
    private var categoriesRaw: [String: JSONValue] = [:]
    private var cachedCategories: [Category]?
    private var tags: [String] = []
    private var runningHashes: Set<String> = []

    private var rid = 0
    /// 代次号：凭据/模式变更时 +1，在途结果回来先比 gen，不等就丢弃。
    private var gen = 0
    private var mode: SyncMode = .full
    private var query = TorrentQuery()
    private var sort: [SortSpec] = [SortSpec(field: .addedOn, order: .reverse)]

    /// 当前权威值。完整档由合并后的 raw 解码而来，省流量档由 transfer/info 直接改写。
    private var serverState = ServerState()
    private var lastResult: QueryResult?
    /// 只用于发布短路比较，**不能**当作解码缓存——否则完整档第二轮起就读不到新合并的 raw 了。
    private var lastPublishedState: ServerState?
    private var totalCount: Int?
    private var isFromCache = false
    private var updatedAt = Date.distantPast
    private var errorMessage: String?

    private var fullInterval: TimeInterval = Settings.defaultFullInterval
    private var liteInterval: TimeInterval = Settings.defaultLiteInterval
    /// 省流量档的全局速度仍是 2 s 新鲜度，只有单任务列表放慢。
    private let liteTransferInterval: TimeInterval = 2
    private var lastTorrentFetch = Date.distantPast
    private var lastSave = Date.distantPast
    /// 4.83 MB 的快照每 2 s 写一次纯属浪费磁盘，节流到 30 s。
    private let saveInterval: TimeInterval = 30

    private var continuation: AsyncStream<Snapshot>.Continuation?
    private var loopTask: Task<Void, Never>?
    private var lastTraffic = TrafficStats()

    public init(client: QBClient, cache: SnapshotCache = SnapshotCache()) {
        self.client = client
        self.cache = cache
    }

    // MARK: - 订阅

    /// 只保留最新一份：UI 消费慢时不该堆积过期快照。
    public func snapshots() -> AsyncStream<Snapshot> {
        continuation?.finish()
        let (stream, next) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = next
        next.yield(currentSnapshot())
        return stream
    }

    public func currentSnapshot() -> Snapshot {
        let result = lastResult ?? QueryPipeline.run(torrents, query: query, sort: sort)
        return Snapshot(
            rows: result.rows, facets: result.facets,
            serverState: serverState, categories: decodedCategories(), tags: tags,
            mode: mode, loadedCount: torrents.count, totalCount: totalCount,
            updatedAt: updatedAt, isFromCache: isFromCache, traffic: lastTraffic,
            runningHashes: mode == .lite ? runningHashes : [], errorMessage: errorMessage
        )
    }

    // MARK: - 配置

    public func setQuery(_ new: TorrentQuery) {
        query = new
        // 切换筛选**零网络**：数据已在内存，这对省流量档尤其重要。
        recompute(force: true)
    }

    public func setSort(_ new: [SortSpec]) {
        sort = new.isEmpty ? [SortSpec(field: .addedOn, order: .reverse)] : new
        recompute(force: true)
    }

    public func setIntervals(full: TimeInterval, lite: TimeInterval) {
        fullInterval = max(0.5, full)
        liteInterval = min(max(lite, Settings.liteIntervalRange.lowerBound), Settings.liteIntervalRange.upperBound)
    }

    public func setMode(_ new: SyncMode) {
        guard new != mode else { return }
        mode = new
        gen += 1
        rid = 0
        runningHashes = []
        lastTorrentFetch = .distantPast
        // 换档不删表：省流量档仍要显示缓存行，完整档回来时也不必从零开始。
        recompute(force: true)
    }

    public func currentMode() -> SyncMode { mode }

    /// 换凭据。URL 变了必须清空全表——旧服务器的任务对新服务器毫无意义。
    public func applyCredentials(_ new: Credentials) async {
        let old = await client.currentCredentials()
        let urlChanged = old.normalizedBaseURL != new.normalizedBaseURL
        await client.configure(new)
        gen += 1
        rid = 0
        errorMessage = nil
        if urlChanged {
            torrents = [:]
            serverStateRaw = nil
            categoriesRaw = [:]
            tags = []
            runningHashes = []
            totalCount = nil
            isFromCache = false
            lastResult = nil
            lastPublishedState = nil
            serverState = ServerState()
            cachedCategories = nil
            cache.delete()
        }
        recompute(force: true)
    }

    // MARK: - 缓存

    /// 启动先读缓存立即显示，0 网络。同时把 cookie 装回去试着续传 rid。
    public func restoreFromCache() async {
        let credentials = await client.currentCredentials()
        guard let cached = cache.load(serverURL: credentials.normalizedBaseURL) else { return }
        torrents = cached.torrents
        serverStateRaw = nil
        serverState = cached.serverState
        categoriesRaw = [:]
        tags = cached.tags
        rid = cached.rid
        totalCount = cached.torrents.count
        isFromCache = true
        updatedAt = cached.savedAt
        await client.restore(cookie: cached.cookie)
        // 分类没有单独存原始 JSON，直接用缓存里的成品。
        cachedCategories = cached.categories
        recompute(force: true)
    }

    public func persist(force: Bool = false) async {
        // 省流量档没拉过全量，不写全量快照（否则会把「只有 33 条」当成完整表存下去）。
        guard mode == .full, !torrents.isEmpty else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastSave) >= saveInterval else { return }
        lastSave = now
        let credentials = await client.currentCredentials()
        let snapshot = CachedSnapshot(
            serverURL: credentials.normalizedBaseURL, savedAt: now, rid: rid,
            cookie: await client.currentCookie(), torrents: torrents,
            serverState: serverState, categories: decodedCategories(), tags: tags
        )
        do {
            try cache.save(snapshot)
        } catch {
            Log.sync.error("快照写入失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 轮询

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = await self.tick()
                if interval <= 0 { return }
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
    }

    /// 停止前必须强制落盘：persist 有 30s 节流，运行不足 30s 就退出会把**过期 rid** 留在盘上。
    /// 真机实测过代价——盘上 rid=1 而服务端已到 rid=4，重启带旧 rid 请求被判过期，
    /// 直接回 full_update 重下 27.45 MB，措施 2（rid 续传）完全失效。
    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
        await persist(force: true)
    }

    /// 跑一轮，返回下一轮该等多久。
    private func tick() async -> TimeInterval {
        await refresh()
        return mode == .full ? fullInterval : liteTransferInterval
    }

    /// 手动刷新 / 单轮同步。
    public func refresh() async {
        let myGen = gen
        var 失败原因: String?
        do {
            if mode == .full {
                try await refreshFull(gen: myGen)
            } else {
                try await refreshLite(gen: myGen)
            }
        } catch is CancellationError {
            return
        } catch let error as QBError {
            if error == .cancelled { return }
            失败原因 = error.displayMessage
        } catch {
            失败原因 = error.localizedDescription
        }

        guard myGen == gen else { return }
        await updateTraffic()
        if let 失败原因 {
            errorMessage = 失败原因
            Log.sync.error("同步失败：\(失败原因, privacy: .public)")
            publish()
        } else {
            errorMessage = nil
            isFromCache = false
            updatedAt = Date()
            recompute()
            await persist()
        }
    }

    private func refreshFull(gen myGen: Int) async throws {
        let maindata = try await client.maindata(rid: rid)
        guard myGen == gen else { return }

        switch maindata.torrents {
        case .full(let list):
            torrents = list
            totalCount = list.count
        case .patch(let patch):
            torrents = try TorrentMerger.apply(
                base: torrents, patch: patch, removed: maindata.torrentsRemoved
            )
            totalCount = torrents.count
        }
        // 响应 rid 非 0 才更新；为 0 说明服务端没接受我们的游标。
        if maindata.rid != 0 { rid = maindata.rid }

        if let state = maindata.serverState {
            serverStateRaw = JSONMerge.merge(serverStateRaw, state)
            if let raw = serverStateRaw, let decoded = try? raw.decoded(ServerState.self) {
                serverState = decoded
            }
        }
        if !maindata.categories.isEmpty || !maindata.categoriesRemoved.isEmpty {
            categoriesRaw = JSONMerge.mergeDictionary(
                base: categoriesRaw, patch: maindata.categories, removed: maindata.categoriesRemoved
            )
            cachedCategories = nil
        }
        if !maindata.tags.isEmpty || !maindata.tagsRemoved.isEmpty {
            // tags 是全量给出的数组，removed 是增量删除。
            if !maindata.tags.isEmpty { tags = maindata.tags }
            if !maindata.tagsRemoved.isEmpty { tags.removeAll { maindata.tagsRemoved.contains($0) } }
        }
    }

    private func refreshLite(gen myGen: Int) async throws {
        // 全局速度 264 B，每 2 s 都要；单任务列表 92 KB，按 liteInterval 放慢。
        let now = Date()
        let 需要任务列表 = now.timeIntervalSince(lastTorrentFetch) >= liteInterval

        if 需要任务列表 {
            async let transfer = client.transferInfo()
            async let running = client.torrents(filter: "running")
            let (info, list) = try await (transfer, running)
            guard myGen == gen else { return }
            lastTorrentFetch = now
            runningHashes = Set(list.map(\.hash))
            // 只覆盖运行中那批，不清空其余缓存行。
            for torrent in list { torrents[torrent.hash] = torrent }
            applyTransferInfo(info)
        } else {
            let info = try await client.transferInfo()
            guard myGen == gen else { return }
            applyTransferInfo(info)
        }
        // 省流量档不知道服务端总数，**不能假装有**。
        totalCount = nil
    }

    private func applyTransferInfo(_ info: TransferInfo) {
        serverState.dlInfoSpeed = info.dlInfoSpeed
        serverState.upInfoSpeed = info.upInfoSpeed
        serverState.dlRateLimit = info.dlRateLimit
        serverState.upRateLimit = info.upRateLimit
        serverState.connectionStatus = info.connectionStatus
        serverState.dhtNodes = info.dhtNodes
    }

    // MARK: - 发布

    private func recompute(force: Bool = false) {
        let result = QueryPipeline.run(torrents, query: query, sort: sort)
        // 短路：7155/7283 是静态 missingFiles，rows 与 serverState 都没变就不发布。
        // 代价是流量计数要搭下一次发布的车——空闲时它不是用户在盯的数字。
        if !force, result == lastResult, serverState == lastPublishedState { return }
        lastResult = result
        lastPublishedState = serverState
        publish()
    }

    private func publish() {
        continuation?.yield(currentSnapshot())
    }

    private func decodedCategories() -> [Category] {
        if let cachedCategories { return cachedCategories }
        let list: [Category] = categoriesRaw.compactMap { entry in
            guard var category = try? entry.value.decoded(Category.self) else { return nil }
            if category.name.isEmpty { category.name = entry.key }
            return category
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cachedCategories = list
        return list
    }

    /// 每轮结束后把 client 的流量统计取回来。currentSnapshot 是同步的，只能读这份缓存值。
    private func updateTraffic() async {
        let t = await client.traffic()
        let metrics = await client.metrics()
        let 本轮 = metrics.suffix(max(0, t.requestCount - lastTraffic.requestCount))
        lastTraffic = TrafficStats(
            totalBytes: t.totalBytes,
            lastRoundBytes: Int64(本轮.map(\.bytes).reduce(0, +)),
            requestCount: t.requestCount
        )
    }

    // MARK: - 写操作后的乐观更新

    /// 就地改状态，下一轮同步会校正。避免用户点了「停止」还要等 2 s 才看到变化。
    public func optimisticStop(_ hashes: [String]) {
        for hash in hashes {
            guard var t = torrents[hash] else { continue }
            t.state = t.progress >= 1 ? .stoppedUP : .stoppedDL
            t.dlspeed = 0
            t.upspeed = 0
            torrents[hash] = t
        }
        recompute(force: true)
    }

    public func optimisticStart(_ hashes: [String]) {
        for hash in hashes {
            guard var t = torrents[hash] else { continue }
            t.state = t.progress >= 1 ? .uploading : .downloading
            torrents[hash] = t
        }
        recompute(force: true)
    }

    public func optimisticCategory(_ hashes: [String], category: String) {
        for hash in hashes {
            guard var t = torrents[hash] else { continue }
            t.category = category
            torrents[hash] = t
        }
        recompute(force: true)
    }

    /// qB 没有覆盖式改标签端点，差集自己算。
    public func optimisticTags(_ hashes: [String], tags newTags: [String]) {
        for hash in hashes {
            guard var t = torrents[hash] else { continue }
            t.tagsRaw = newTags.joined(separator: ",")
            torrents[hash] = t
        }
        recompute(force: true)
    }

    public func optimisticUploadLimit(_ hashes: [String], bytesPerSecond: Int64) {
        for hash in hashes {
            guard var t = torrents[hash] else { continue }
            t.upLimit = bytesPerSecond
            torrents[hash] = t
        }
        recompute(force: true)
    }

    public func removeLocally(_ hashes: [String]) {
        for hash in hashes { torrents.removeValue(forKey: hash) }
        totalCount = torrents.count
        recompute(force: true)
    }

    /// 供 CLI 与测试观察内部状态。
    public func debugState() -> (rid: Int, gen: Int, count: Int, mode: SyncMode) {
        (rid, gen, torrents.count, mode)
    }

    public func loadedTorrents() -> [String: Torrent] { torrents }
}