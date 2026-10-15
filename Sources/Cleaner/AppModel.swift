import AppKit
import CleanCore
import Foundation
import Observation

/// `sheet(item:)` 需要 Identifiable
struct IdentifiedReport: Identifiable {
    let id = UUID()
    let value: CleanReport
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle, scanning, scanned, cleaning
    }

    let settings: AppSettings
    private(set) var rules: [Rule]
    private(set) var ruleLoadErrors: [String]

    var phase: Phase = .idle
    var scanProgress = ScanProgress(phase: "", completed: 0, total: 0)
    private(set) var results: [RuleResult] = []
    var selection: Set<String> = []
    private(set) var disk: DiskSpace? = DiskSpace.current()
    private(set) var lastScanDate: Date?
    private(set) var hasFullDiskAccess = Permissions.hasFullDiskAccess()

    var cleanProgress: (done: Int, total: Int, title: String) = (0, 0, "")
    /// 清理完成后的报告，非 nil 时显示结果页
    var lastReport: IdentifiedReport?

    private var scanTask: Task<Void, Never>?

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        let loaded = RuleStore.loadAll()
        rules = loaded.rules
        ruleLoadErrors = loaded.errors
    }

    // MARK: - 扫描

    func startScan() {
        guard phase != .scanning, phase != .cleaning else { return }
        let loaded = RuleStore.loadAll()
        rules = loaded.rules
        ruleLoadErrors = loaded.errors
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        disk = DiskSpace.current()

        phase = .scanning
        scanProgress = ScanProgress(phase: "准备扫描…", completed: 0, total: 1)
        let context = ScanContext(
            running: RunningAppsSnapshot.current(),
            projectRoots: settings.projectRoots,
            activeProjectDays: settings.activeProjectDays
        )
        let scanner = Scanner(rules: rules)
        scanTask = Task {
            let results = await scanner.scan(context: context) { progress in
                Task { @MainActor [weak self] in self?.scanProgress = progress }
            }
            guard !Task.isCancelled else { return }
            self.apply(results)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = results.isEmpty ? .idle : .scanned
    }

    private func apply(_ results: [RuleResult]) {
        let protected = protectedChecker
        self.results = results.map { result in
            var result = result
            result.items.removeAll { item in item.urls.contains { protected.check($0) == .rejected("在保护清单中") } }
            return result
        }
        selection = Set(self.results.flatMap { $0.items.filter(\.preselected).map(\.id) })
        lastScanDate = Date()
        phase = .scanned
    }

    private var protectedChecker: SafetyGuard {
        SafetyGuard(protectedPaths: settings.protectedPaths)
    }

    // MARK: - 汇总

    func results(in category: CleanCategory) -> [RuleResult] {
        results.filter { $0.rule.category == category }
    }

    /// 预计可释放的空间（不含只展示的项）
    func totalSize(in category: CleanCategory? = nil) -> Int64 {
        results.filter { category == nil || $0.rule.category == category }
            .filter { $0.rule.action != .reveal }
            .reduce(0) { $0 + $1.reclaimableTotal }
    }

    func selectedSize(in category: CleanCategory? = nil) -> Int64 {
        var total: Int64 = 0
        for result in results where category == nil || result.rule.category == category {
            for item in result.items where selection.contains(item.id) {
                total += item.reclaimable
            }
        }
        return total
    }

    var selectedCount: Int { selection.count }

    // MARK: - 勾选

    func isSelected(_ item: ScanItem) -> Bool { selection.contains(item.id) }

    func setSelected(_ item: ScanItem, _ selected: Bool) {
        if selected { selection.insert(item.id) } else { selection.remove(item.id) }
    }

    func setSelected(_ result: RuleResult, _ selected: Bool) {
        for item in result.items {
            setSelected(item, selected)
        }
    }

    // MARK: - 清理

    func pendingTasks() -> [CleanTask] {
        var tasks: [CleanTask] = []
        for result in results {
            let action = result.rule.effectiveAction(alwaysTrash: settings.alwaysTrash)
            guard action != .reveal else { continue }
            for item in result.items where selection.contains(item.id) {
                tasks.append(CleanTask(item: item, rule: result.rule, action: action))
            }
        }
        return tasks
    }

    func clean() {
        let tasks = pendingTasks()
        guard !tasks.isEmpty, phase == .scanned else { return }
        phase = .cleaning
        cleanProgress = (0, tasks.count, "")
        let cleaner = Cleaner(guardrail: SafetyGuard(protectedPaths: settings.protectedPaths))
        Task {
            let report = await cleaner.clean(tasks) { done, total, title in
                Task { @MainActor [weak self] in self?.cleanProgress = (done, total, title) }
            }
            self.finishCleaning(report)
        }
    }

    private func finishCleaning(_ report: CleanReport) {
        // 去掉已经不存在的项
        let fm = FileManager.default
        results = results.compactMap { result in
            var result = result
            result.items.removeAll { item in !item.urls.contains { fm.fileExists(atPath: $0.path) } }
            return result.items.isEmpty && !result.accessDenied ? nil : result
        }
        let remaining = Set(results.flatMap { $0.items.map(\.id) })
        selection.formIntersection(remaining)
        disk = DiskSpace.current()
        phase = .scanned
        lastReport = IdentifiedReport(value: report)
    }

    // MARK: - 其他操作

    func protect(_ item: ScanItem) {
        for url in item.urls where !settings.protectedPaths.contains(url.path) {
            settings.protectedPaths.append(url.path)
        }
        selection.remove(item.id)
        results = results.map { result in
            var result = result
            result.items.removeAll { $0.id == item.id }
            return result
        }
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls.prefix(20)))
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL)
    }

    func refreshPermissions() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
    }

    func refreshDisk() {
        disk = DiskSpace.current()
    }
}
