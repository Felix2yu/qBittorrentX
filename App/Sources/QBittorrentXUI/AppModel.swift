import Foundation
import Observation
import QBKit

/// UI 的唯一状态源。**主线程只做一次赋值**：过滤/排序/facet 全在 SyncEngine actor 内算完，
/// 这里消费 `AsyncStream<Snapshot>` 把成品整体换上去。
@MainActor
@Observable
public final class AppModel {
    // MARK: - 展示状态

    public var snapshot = Snapshot()
    public var selection: Set<String> = []
    public var query = TorrentQuery()
    /// Table 直接绑这个数组；点列头由 SwiftUI 改写，再经 onChange 落回 SortSpec 持久化。
    public var sortOrder: [KeyPathComparator<Torrent>] = []
    public var inspectorVisible = true
    public var dataUsage: Settings.DataUsage = .auto
    public var liteInterval = Settings.defaultLiteInterval
    /// 正在执行写操作的 hash，用来禁用按钮防重复点击。
    public var busyHashes: Set<String> = []
    public var actionError: String?
    public var isRefreshing = false
    /// 「加载全部」的确认框。省流量档下点它才会拉全量。
    public var isConfirmingLoadAll = false
    /// 所有弹框走这一个入口：同一个视图上挂两个 .sheet 会互相吞掉。
    public var activeSheet: ActionSheet?

    public enum ActionSheet: Identifiable, Hashable {
        case category([String])
        case tags([String])
        case limit([String])
        case delete([String])

        public var id: String {
            switch self {
            case .category: "category"
            case .tags: "tags"
            case .limit: "limit"
            case .delete: "delete"
            }
        }

        public var hashes: [String] {
            switch self {
            case .category(let h), .tags(let h), .limit(let h), .delete(let h): h
            }
        }
    }

    // MARK: - 非展示状态

    @ObservationIgnored private let settings = Settings()
    @ObservationIgnored private let credentialStore = CredentialStore()
    @ObservationIgnored private let watcher = NetworkPathWatcher()
    @ObservationIgnored private let client: QBClient
    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored private var canUseIncrementalSync = false
    @ObservationIgnored private var isExpensive = false
    @ObservationIgnored private var isConstrained = false
    @ObservationIgnored private var didBootstrap = false

    public init() {
        let store = CredentialStore()
        let credentials = store.load()
        client = QBClient(credentials: credentials)
        engine = SyncEngine(client: client)
        canUseIncrementalSync = credentials.canUseIncrementalSync
        inspectorVisible = settings.inspectorVisible
        dataUsage = settings.dataUsage
        liteInterval = settings.liteInterval
        sortOrder = SortSpec.comparators(settings.sort)
    }

    // MARK: - 启动

    /// 退出前落盘用。只暴露 actor 而不是整个 model：`applicationWillTerminate` 会阻塞主线程
    /// 等落盘完成，若把 @MainActor 的 self 捕获进 Task，那个 Task 永远排不上主线程，直接死锁到超时。
    public nonisolated var syncEngine: SyncEngine { engine }

    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        await engine.setIntervals(full: settings.fullInterval, lite: liteInterval)
        await engine.setSort(SortSpec.specs(sortOrder))
        await engine.setQuery(query)
        // 先读缓存立即出画面（0 网络），再决定档位去联网。
        await engine.restoreFromCache()
        await engine.setMode(resolvedMode())

        watcher.start { [weak self] expensive, constrained in
            Task { @MainActor in self?.pathChanged(expensive: expensive, constrained: constrained) }
        }
        // NWPathMonitor 首个回调是异步的，等一下再读，否则恒为 false 会把计费网络误判成完整档。
        try? await Task.sleep(for: .milliseconds(300))
        let path = watcher.current
        pathChanged(expensive: path.isExpensive, constrained: path.isConstrained)

        let stream = await engine.snapshots()
        consumeTask = Task { [weak self] in
            for await snapshot in stream {
                self?.snapshot = snapshot
            }
        }
        await engine.start()
    }

    // MARK: - 档位

    private func resolvedMode() -> SyncMode {
        DataUsagePolicy.effectiveMode(
            usage: dataUsage, isExpensive: isExpensive, isConstrained: isConstrained,
            canUseIncrementalSync: canUseIncrementalSync
        )
    }

    private func pathChanged(expensive: Bool, constrained: Bool) {
        isExpensive = expensive
        isConstrained = constrained
        let mode = resolvedMode()
        Task { await engine.setMode(mode) }
    }

    public func applyDataUsage() {
        settings.dataUsage = dataUsage
        let mode = resolvedMode()
        Task { await engine.setMode(mode) }
    }

    public func applyIntervals() {
        settings.liteInterval = liteInterval
        liteInterval = settings.liteInterval
        Task { await engine.setIntervals(full: settings.fullInterval, lite: liteInterval) }
    }

    /// 省流量档下唯一的升级入口。**不自动升级**，且必须先让用户知道要下载多少。
    public func loadAll() {
        dataUsage = .full
        applyDataUsage()
        Task {
            await engine.refresh()
            await engine.start()
        }
    }

    /// 只有 API key 时增量为假，UI 要说明为什么档位选不动。
    public var isModeForcedLite: Bool { !canUseIncrementalSync }

    public var isMeteredPath: Bool { isExpensive || isConstrained }

    // MARK: - 筛选与排序

    public func applyQuery() {
        Task { await engine.setQuery(query) }
    }

    public func applySort() {
        let specs = SortSpec.specs(sortOrder)
        settings.sort = specs
        Task { await engine.setSort(specs) }
    }

    public func applyInspectorVisible() {
        settings.inspectorVisible = inspectorVisible
    }

    public func clearFilters() {
        query = TorrentQuery()
        applyQuery()
    }

    // MARK: - 刷新

    public func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await engine.refresh()
            // 引擎遇到「服务端恒回全量」会自己停轮询，手动刷新是重试信号，要把它重新起来。
            await engine.start()
            isRefreshing = false
        }
    }

    // MARK: - 凭据

    public func loadCredentials() -> Credentials {
        credentialStore.load()
    }

    public func saveCredentials(_ credentials: Credentials) {
        do {
            try credentialStore.save(credentials)
        } catch {
            actionError = "保存到钥匙串失败：\(error.localizedDescription)"
            return
        }
        canUseIncrementalSync = credentials.canUseIncrementalSync
        actionError = nil
        Task {
            await engine.applyCredentials(credentials)
            await engine.setMode(resolvedMode())
            await engine.refresh()
        }
    }

    // MARK: - 写操作

    public enum WriteAction {
        case stop, start, recheck
        case category(String)
        case tags([String])
        case uploadLimit(Int64)
        case delete(deleteFiles: Bool)
    }

    public var selectedTorrents: [Torrent] {
        snapshot.rows.filter { selection.contains($0.hash) }
    }

    public func perform(_ action: WriteAction, hashes: [String]) {
        let targets = hashes.filter { !busyHashes.contains($0) }
        guard !targets.isEmpty else { return }
        busyHashes.formUnion(targets)
        actionError = nil
        Task {
            defer { busyHashes.subtract(targets) }
            do {
                try await send(action, targets)
            } catch {
                actionError = (error as? QBError)?.displayMessage ?? error.localizedDescription
            }
            // 无论成败都拉一轮：成功要确认服务端结果，失败要把乐观更新纠正回来。
            await engine.refresh()
        }
    }

    private func send(_ action: WriteAction, _ targets: [String]) async throws {
        switch action {
        case .stop:
            await engine.optimisticStop(targets)
            try await client.stop(targets)
        case .start:
            await engine.optimisticStart(targets)
            try await client.start(targets)
        case .recheck:
            try await client.recheck(targets)
        case .category(let name):
            await engine.optimisticCategory(targets, category: name)
            try await client.setCategory(targets, category: name)
        case .tags(let desired):
            // 差集必须用**乐观更新之前**的现状算，否则第二次点会把刚加的当成已有。
            let loaded = await engine.loadedTorrents()
            let diff = TagDiff.compute(torrents: targets.compactMap { loaded[$0] }, desired: desired)
            await engine.optimisticTags(targets, tags: desired)
            if !diff.add.isEmpty { try await client.addTags(targets, tags: diff.add) }
            if !diff.remove.isEmpty { try await client.removeTags(targets, tags: diff.remove) }
        case .uploadLimit(let limit):
            await engine.optimisticUploadLimit(targets, bytesPerSecond: limit)
            try await client.setUploadLimit(targets, bytesPerSecond: limit)
        case .delete(let deleteFiles):
            try await client.delete(targets, deleteFiles: deleteFiles)
            await engine.removeLocally(targets)
            selection.subtract(targets)
        }
    }
}