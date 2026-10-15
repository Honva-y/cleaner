import Foundation

/// 扫描分两步：
/// 1. 匹配：逐条规则找出候选路径，并去掉与前面规则重叠的路径（规则越靠前优先级越高）
/// 2. 计算大小：并发统计每一项的实际占用
public struct Scanner: Sendable {
    public var rules: [Rule]
    public var maxConcurrentMeasurements: Int

    public init(rules: [Rule], maxConcurrentMeasurements: Int = 6) {
        self.rules = rules
        self.maxConcurrentMeasurements = maxConcurrentMeasurements
    }

    public func scan(
        context: ScanContext,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async -> [RuleResult] {
        // 1. 匹配
        var matched: [(rule: Rule, output: MatchOutput)] = []
        var claimed = ClaimedPaths()
        for (index, rule) in rules.enumerated() {
            if Task.isCancelled { return [] }
            progress(ScanProgress(phase: "查找：\(rule.name)", completed: index, total: rules.count))
            var output = Matchers.run(rule, context: context)
            output.candidates = output.candidates.compactMap { candidate in
                var candidate = candidate
                candidate.urls = candidate.urls.filter { claimed.claim($0.path) }
                return candidate.urls.isEmpty ? nil : candidate
            }
            matched.append((rule, output))
        }

        // 2. 计算大小
        struct Job: Sendable {
            let ruleIndex: Int
            let itemIndex: Int
            let urls: [URL]
        }
        var jobs: [Job] = []
        for (ruleIndex, entry) in matched.enumerated() {
            for (itemIndex, candidate) in entry.output.candidates.enumerated() {
                jobs.append(Job(ruleIndex: ruleIndex, itemIndex: itemIndex, urls: candidate.urls))
            }
        }

        let total = jobs.count
        let trackers = matched.map { _ in SharingTracker() }
        var sizes: [Int: [Int: SizeInfo]] = [:]
        await withTaskGroup(of: (Int, Int, SizeInfo).self) { group in
            var next = 0
            var done = 0
            func enqueue() {
                guard next < jobs.count else { return }
                let job = jobs[next]
                let tracker = trackers[job.ruleIndex]
                next += 1
                group.addTask {
                    var info = SizeInfo()
                    for url in job.urls {
                        info.merge(SizeCalculator.measure(url, tracker: tracker))
                    }
                    return (job.ruleIndex, job.itemIndex, info)
                }
            }
            for _ in 0..<maxConcurrentMeasurements { enqueue() }
            while let (ruleIndex, itemIndex, info) = await group.next() {
                sizes[ruleIndex, default: [:]][itemIndex] = info
                done += 1
                let ruleName = matched[ruleIndex].rule.name
                progress(ScanProgress(phase: "计算大小：\(ruleName)", completed: done, total: total))
                if Task.isCancelled {
                    group.cancelAll()
                } else {
                    enqueue()
                }
            }
        }
        if Task.isCancelled { return [] }

        // 3. 组装结果
        var results: [RuleResult] = []
        for (ruleIndex, entry) in matched.enumerated() {
            let rule = entry.rule
            var items: [ScanItem] = []
            let infos = sizes[ruleIndex] ?? [:]
            // 克隆去重后的“预计释放”是整条规则的总量，按占用比例分摊到每一项
            let ruleAllocated = infos.values.reduce(0) { $0 + $1.allocated }
            let ruleEstimated = infos.values.reduce(0) { $0 + $1.estimated }
            let ratio = ruleAllocated > 0 ? min(1, Double(ruleEstimated) / Double(ruleAllocated)) : 1
            for (itemIndex, candidate) in entry.output.candidates.enumerated() {
                let info = infos[itemIndex] ?? SizeInfo()
                guard info.allocated > 0 else { continue }
                let selectable = rule.action != .reveal
                let defaultSelected = selectable && (candidate.preselect ?? (rule.risk == .safe))
                var note = candidate.note
                var preselect = defaultSelected
                // 聚合项是许多独立路径，删不掉的会单独失败；其余项删一半会坏掉，所以不勾选
                if info.blocked > 0 && !rule.aggregate {
                    note = "有 \(info.blocked) 个文件属于其他用户（如 root）或受系统保护，无法完全删除，已跳过"
                    preselect = false
                }
                if note == nil && info.exclusive < info.allocated / 2 && info.allocated > 10_000_000 {
                    note = "与其他文件共用数据块（APFS 克隆），实际释放会少于占用"
                }
                if info.unreadable > 0 && note == nil {
                    note = "有 \(info.unreadable) 个文件没有权限读取，实际可能更大"
                }
                items.append(ScanItem(
                    ruleID: rule.id,
                    title: candidate.title,
                    detail: candidate.detail,
                    urls: candidate.urls,
                    size: info.allocated,
                    exclusiveSize: info.exclusive,
                    reclaimable: Int64(Double(info.allocated) * ratio),
                    fileCount: info.fileCount,
                    modified: info.newestModification,
                    note: note,
                    preselected: preselect,
                    partiallyUnreadable: info.unreadable > 0,
                    blockedCount: rule.aggregate ? 0 : info.blocked
                ))
            }
            // 月份、版本这类本身有顺序的保持原顺序，其余按大小降序
            if rule.matcher == .glob || rule.matcher == .buildArtifacts {
                items.sort { $0.size > $1.size }
            }
            guard !items.isEmpty || entry.output.accessDenied else { continue }
            results.append(RuleResult(rule: rule, items: items, notes: entry.output.notes, accessDenied: entry.output.accessDenied))
        }
        return results
    }
}

/// 已被前面规则认领的路径。一个路径如果和已认领的路径相同、在其内部或包含它，就不再重复统计。
struct ClaimedPaths {
    private var claimed = Set<String>()
    private var ancestors = Set<String>()

    mutating func claim(_ path: String) -> Bool {
        if claimed.contains(path) || ancestors.contains(path) { return false }
        var parent = (path as NSString).deletingLastPathComponent
        while parent != "/" && !parent.isEmpty {
            if claimed.contains(parent) { return false }
            parent = (parent as NSString).deletingLastPathComponent
        }
        claimed.insert(path)
        parent = (path as NSString).deletingLastPathComponent
        while parent != "/" && !parent.isEmpty {
            ancestors.insert(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        return true
    }
}
