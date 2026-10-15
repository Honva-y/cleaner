import CleanCore
import Foundation

/// `Cleaner --scan [--all]`：不打开界面，只扫描并打印结果（不会删除任何文件）。`--all` 打印每条规则的全部项目。
enum HeadlessScan {
    @MainActor
    static func run() async {
        let (rules, errors) = RuleStore.loadAll()
        errors.forEach { print("规则加载失败：\($0)") }
        let settings = AppSettings()
        let context = ScanContext(
            running: RunningAppsSnapshot.current(),
            projectRoots: settings.projectRoots,
            activeProjectDays: settings.activeProjectDays
        )
        let start = Date()
        let results = await Scanner(rules: rules).scan(context: context)
        let elapsed = Date().timeIntervalSince(start)

        var total: Int64 = 0
        var selected: Int64 = 0
        for category in CleanCategory.allCases {
            let inCategory = results.filter { $0.rule.category == category }
            guard !inCategory.isEmpty else { continue }
            print("\n== \(category.title) ==")
            for result in inCategory {
                let size = result.reclaimableTotal
                let picked = result.items.filter(\.preselected).reduce(0) { $0 + $1.reclaimable }
                total += size
                selected += picked
                let flag = result.accessDenied ? " [无权限]" : ""
                let occupied = result.totalSize > size ? "，占用 \(format(result.totalSize))" : ""
                print("  [\(result.rule.risk.title)] \(result.rule.name)：预计释放 \(format(size))\(occupied)（默认勾选 \(format(picked))）\(flag)")
                for note in result.notes { print("      · \(note)") }
                let limit = CommandLine.arguments.contains("--all") ? Int.max : 5
                for item in result.items.prefix(limit) {
                    let mark = item.preselected ? "☑" : "☐"
                    print("      \(mark) \(item.title)  \(format(item.size))\(item.note.map { "  — \($0)" } ?? "")")
                }
                if result.items.count > limit { print("      … 共 \(result.items.count) 项") }
            }
        }
        print("\n合计 \(format(total))，默认勾选 \(format(selected))，耗时 \(String(format: "%.1f", elapsed)) 秒")
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
