import Foundation

public struct CleanFailure: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let reason: String
}

public struct CleanReport: Sendable {
    public var date = Date()
    /// 扫描时估算的可释放大小
    public var estimatedBytes: Int64 = 0
    public var deletedBytes: Int64 = 0
    public var trashedBytes: Int64 = 0
    /// 清理前后磁盘可用空间的差值（APFS 克隆、快照会让它和估算值不同）
    public var measuredFreedBytes: Int64?
    public var cleanedItems = 0
    public var failures: [CleanFailure] = []
    public var dryRun = false
}

/// 一个待清理项：扫描结果 + 实际删除方式
public struct CleanTask: Sendable {
    public let item: ScanItem
    public let rule: Rule
    public let action: CleanAction

    public init(item: ScanItem, rule: Rule, action: CleanAction) {
        self.item = item
        self.rule = rule
        self.action = action
    }
}

public struct Cleaner: Sendable {
    public let guardrail: SafetyGuard
    public let journal: Journal?

    public init(guardrail: SafetyGuard, journal: Journal? = .shared) {
        self.guardrail = guardrail
        self.journal = journal
    }

    public func clean(
        _ tasks: [CleanTask],
        dryRun: Bool = false,
        progress: @escaping @Sendable (Int, Int, String) -> Void = { _, _, _ in }
    ) async -> CleanReport {
        var report = CleanReport(dryRun: dryRun)
        let before = DiskSpace.current()
        let total = tasks.reduce(0) { $0 + $1.item.urls.count }
        var done = 0

        for task in tasks {
            guard task.action != .reveal else { continue }
            if task.item.blockedCount > 0 {
                let reason = "包含 \(task.item.blockedCount) 个无法删除的文件（属于其他用户或受系统保护），为避免只删一半已跳过"
                for url in task.item.urls {
                    report.failures.append(CleanFailure(path: url.path, reason: reason))
                    if !dryRun {
                        journal?.append(.init(rule: task.rule, path: url.path, action: task.action, result: "skipped", message: reason))
                    }
                }
                done += task.item.urls.count
                continue
            }
            var itemOK = true
            for url in task.item.urls {
                if Task.isCancelled { break }
                done += 1
                progress(done, total, task.item.title)

                let entry: Journal.Entry
                switch guardrail.check(url) {
                case .rejected(let reason):
                    report.failures.append(CleanFailure(path: url.path, reason: reason))
                    entry = .init(rule: task.rule, path: url.path, action: task.action, result: "skipped", message: reason)
                    itemOK = false
                case .allowed:
                    if dryRun {
                        entry = .init(rule: task.rule, path: url.path, action: task.action, result: "dry-run", message: nil)
                    } else {
                        do {
                            try perform(task.action, on: url)
                            entry = .init(rule: task.rule, path: url.path, action: task.action, result: "ok", message: nil)
                        } catch {
                            report.failures.append(CleanFailure(path: url.path, reason: error.localizedDescription))
                            entry = .init(rule: task.rule, path: url.path, action: task.action, result: "failed", message: error.localizedDescription)
                            itemOK = false
                        }
                    }
                }
                if !dryRun { journal?.append(entry) }
            }
            report.estimatedBytes += task.item.reclaimable
            if itemOK {
                report.cleanedItems += 1
                if task.action == .trash {
                    report.trashedBytes += task.item.reclaimable
                } else {
                    report.deletedBytes += task.item.reclaimable
                }
            }
        }

        if !dryRun, let before {
            // APFS 释放空间有时会延迟一点
            try? await Task.sleep(for: .seconds(1))
            if let after = DiskSpace.current() {
                report.measuredFreedBytes = after.available - before.available
            }
            journal?.recordSession(report)
        }
        return report
    }

    private func perform(_ action: CleanAction, on url: URL) throws {
        let fm = FileManager.default
        switch action {
        case .trash:
            try fm.trashItem(at: url, resultingItemURL: nil)
        case .delete:
            do {
                try fm.removeItem(at: url)
            } catch {
                // Go 模块缓存等只读目录：先恢复写权限再删
                guard FileInfo.exists(url.path) else { return }
                Self.makeWritable(url)
                try fm.removeItem(at: url)
            }
        case .reveal:
            break
        }
    }

    static func makeWritable(_ url: URL) {
        let fm = FileManager.default
        func fix(_ path: String) {
            if let attrs = try? fm.attributesOfItem(atPath: path),
               attrs[.type] as? FileAttributeType == .typeDirectory,
               let perms = attrs[.posixPermissions] as? Int {
                try? fm.setAttributes([.posixPermissions: perms | 0o700], ofItemAtPath: path)
            }
        }
        fix(url.path)
        guard let enumerator = fm.enumerator(atPath: url.path) else { return }
        while let relative = enumerator.nextObject() as? String {
            fix(url.path + "/" + relative)
        }
    }
}

public struct DiskSpace: Sendable, Equatable {
    public let total: Int64
    /// 和 `df` 一致的可用空间
    public let available: Int64
    /// 包含系统可回收空间（purgeable）的可用空间，和“关于本机”里显示的一致
    public let availableForImportantUsage: Int64

    public var used: Int64 { total - available }

    public static func current(for path: String = PathExpander.home) -> DiskSpace? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacity
        else { return nil }
        return DiskSpace(
            total: Int64(total),
            available: Int64(available),
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        )
    }
}
