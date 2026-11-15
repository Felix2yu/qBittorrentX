import AppKit
import QBKit
import SwiftUI

/// 零尺寸 AppKit 桥接：让 SwiftUI `Table` 的列宽可读、可写、可持久化。
///
/// 三条职责：
/// 1. 启动时按 customizationID 应用保存的宽度，并给每列设 min/max；
/// 2. 只对**用户交互**产生的列宽变化做 debounce 写回（系统布局分配不算）；
/// 3. 表头列边界双击时按当前内容测宽（Excel 式自适应），结果走同一条保存路径。
///
/// 明确的边界：**不替换 `NSTableView.delegate`**（SwiftUI 自己持有，替换会破坏选择、
/// 排序与行视图），**不启用 `autosaveTableColumns`**（列顺序已经由 columnCustomization
/// 独占，两个真源会互相打架）。找不到底层 tableView 时静默降级，一切既有交互照常。
struct ColumnWidthBridge: NSViewRepresentable {
    @Binding var widths: [String: Double]
    let rows: [Torrent]
    let onCommit: @MainActor ([String: Double]) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func makeCoordinator() -> ColumnWidthCoordinator {
        ColumnWidthCoordinator(widths: widths, rows: rows, onCommit: onCommit)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.widths = widths
        coordinator.rows = rows
        coordinator.onCommit = onCommit
        // 首次布局时 window 可能还没挂上；snapshot 每轮刷新都会走到这里，幂等重试即可。
        coordinator.attachIfNeeded(from: nsView)
        coordinator.synchronize()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ColumnWidthCoordinator) {
        MainActor.assumeIsolated { coordinator.detach() }
    }
}

@MainActor
final class ColumnWidthCoordinator: NSObject {
    var widths: [String: Double]
    var rows: [Torrent]
    var onCommit: @MainActor ([String: Double]) -> Void

    private weak var tableView: NSTableView?
    private weak var headerView: NSView?
    private var doubleClickGesture: NSClickGestureRecognizer?
    private var mouseMonitor: Any?
    private var saveWorkItem: DispatchWorkItem?
    /// 已经反映到 NSTableColumn 的快照，避免 2s 一次的 body 重算反复覆盖列宽。
    private var appliedWidths: [String: Double]?
    private var lastUserMouseDownAt = Date.distantPast
    /// NSTableView 自己也会响应双击分隔线；抑制这段窗口内的自动保存，
    /// 避免原生 fit 的结果在 0.4s 后覆盖我们按内容测量并钳制过的值。
    private var suppressAutoSaveUntil = Date.distantPast
    private var isApplyingWidths = false
    private var isAttached = false

    init(
        widths: [String: Double],
        rows: [Torrent],
        onCommit: @escaping @MainActor ([String: Double]) -> Void
    ) {
        self.widths = widths
        self.rows = rows
        self.onCommit = onCommit
        super.init()
    }

    // MARK: - 定位宿主表格

    func attachIfNeeded(from view: NSView) {
        guard !isAttached, let window = view.window, let root = window.contentView else { return }
        guard let table = Self.findTorrentTable(in: root) else { return }
        isAttached = true
        tableView = table

        for column in table.tableColumns {
            guard let spec = Self.spec(for: column) else { continue }
            column.minWidth = spec.minWidth
            column.maxWidth = spec.maxWidth
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: table
        )
        installDoubleClick(on: table)
        installMouseMonitor()
    }

    /// 按表头标题集合识别主表格：侧边栏等其它 NSTableView 不会命中 8 个以上任务列表头。
    private static func findTorrentTable(in root: NSView) -> NSTableView? {
        let titles = Set(TorrentColumn.allCases.map(\.title))
        func walk(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView {
                let matched = table.tableColumns.filter {
                    titles.contains($0.headerCell.stringValue)
                }.count
                if matched >= 8 { return table }
            }
            for subview in view.subviews {
                if let found = walk(subview) { return found }
            }
            return nil
        }
        return walk(root)
    }

    /// 真机实测：SwiftUI 给 NSTableColumn 的 identifier 是随机 UUID（每次启动都变），
    /// 所以 identifier 匹配基本命中不了，实际靠表头中文标题匹配（14 个标题唯一）。
    /// 绝不按数组下标——列顺序可由用户拖动，验收环境里首列就是「大小」而不是「名称」。
    static func spec(for column: NSTableColumn) -> TorrentColumn? {
        if let match = TorrentColumn(rawValue: column.identifier.rawValue) { return match }
        return TorrentColumn.allCases.first { $0.title == column.headerCell.stringValue }
    }

    // MARK: - 恢复

    /// 只在持久化字典变化时应用一次；用户正按住鼠标拖列宽时不覆盖。
    func synchronize() {
        guard let table = tableView, appliedWidths != widths else { return }
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        appliedWidths = widths
        isApplyingWidths = true
        defer { isApplyingWidths = false }
        for column in table.tableColumns {
            guard let spec = Self.spec(for: column) else { continue }
            column.minWidth = spec.minWidth
            column.maxWidth = spec.maxWidth
            let target = widths[spec.id].map { spec.clamped($0) } ?? spec.idealWidth
            if abs(column.width - target) > 0.5 { column.width = target }
        }
    }

    // MARK: - 保存

    /// 只记录用户按下鼠标，不拦截事件：表头拖拽、单击排序等系统行为完全不受影响。
    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.lastUserMouseDownAt = Date() }
            return event
        }
    }

    private var isUserResizing: Bool {
        NSEvent.pressedMouseButtons & 1 != 0
            || Date().timeIntervalSince(lastUserMouseDownAt) < 0.8
    }

    @objc private func columnDidResize(_ notification: Notification) {
        MainActor.assumeIsolated {
            // 自身恢复 / 双击自适应写 width，以及 SwiftUI 按窗口自动分配宽度，都不该落盘：
            // 否则启动时的布局结果会把用户从未调整过的宽度写进偏好。
            guard !isApplyingWidths, isUserResizing, Date() > suppressAutoSaveUntil else { return }
            scheduleSave()
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 合并而不是覆盖：隐藏列可能不在 tableColumns 里，重新显示时仍要恢复它原来的宽度。
    private func flush() {
        guard let table = tableView else { return }
        var merged = widths
        for column in table.tableColumns {
            guard let spec = Self.spec(for: column), !column.isHidden else { continue }
            merged[spec.id] = Double(spec.clamped(Double(column.width)))
        }
        guard merged != widths else { return }
        appliedWidths = merged
        onCommit(merged)
    }

    // MARK: - 双击列边界按内容自适应

    private func installDoubleClick(on table: NSTableView) {
        guard let header = table.headerView else { return }
        let gesture = NSClickGestureRecognizer(
            target: self,
            action: #selector(headerDoubleClicked(_:))
        )
        gesture.numberOfClicksRequired = 2
        // 不延迟原生鼠标事件：表头拖拽列宽与单击排序保持系统行为。
        gesture.delaysPrimaryMouseButtonEvents = false
        header.addGestureRecognizer(gesture)
        doubleClickGesture = gesture
        headerView = header
    }

    @objc private func headerDoubleClicked(_ gesture: NSClickGestureRecognizer) {
        MainActor.assumeIsolated {
            guard let table = tableView, let header = table.headerView else { return }
            let point = gesture.location(in: header)
            guard header.bounds.contains(point) else { return }
            let windowPoint = header.convert(point, to: nil)
            let tablePoint = table.convert(windowPoint, from: nil)

            for (index, column) in table.tableColumns.enumerated() {
                let frame = table.rect(ofColumn: index)
                // 只认右边界 ±5 pt；表头中部双击仍然是排序，不误触发自适应。
                guard abs(tablePoint.x - frame.maxX) <= 5 else { continue }
                guard let spec = Self.spec(for: column) else { return }
                let fitted = spec.fittedWidth(rows: rows)
                suppressAutoSaveUntil = Date().addingTimeInterval(0.8)

                isApplyingWidths = true
                column.width = fitted
                isApplyingWidths = false

                var merged = widths
                merged[spec.id] = Double(fitted)
                guard merged != widths else { return }
                appliedWidths = merged
                onCommit(merged)
                return
            }
        }
    }

    // MARK: - 清理

    func detach() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        NotificationCenter.default.removeObserver(self)
        if let gesture = doubleClickGesture {
            headerView?.removeGestureRecognizer(gesture)
        }
        doubleClickGesture = nil
        headerView = nil
        tableView = nil
        isAttached = false
    }
}
