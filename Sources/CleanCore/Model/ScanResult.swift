import Foundation

/// 扫描出的一个可清理项。一项可以包含多个路径（例如“微信图片 2024-10”分散在多个会话目录里）。
public struct ScanItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let ruleID: String
    public let title: String
    public let detail: String?
    public let urls: [URL]
    /// 占用空间（和访达一致）
    public var size: Int64
    /// 删除后一定能释放的空间（不和其他文件共用数据块的部分）
    public var exclusiveSize: Int64
    /// 预计释放：多份 APFS 克隆共用的数据只算一次，按占用比例分摊到每一项
    public var reclaimable: Int64
    public var fileCount: Int
    public var modified: Date?
    public var note: String?
    /// 是否默认勾选（已综合风险等级、App 运行状态、项目活跃度）
    public var preselected: Bool
    /// 部分文件因权限读不到，大小可能偏小
    public var partiallyUnreadable: Bool
    /// 当前用户删不掉的条目数；大于 0 时清理会整项跳过，避免只删一半
    public var blockedCount: Int

    public init(
        ruleID: String,
        title: String,
        detail: String?,
        urls: [URL],
        size: Int64 = 0,
        exclusiveSize: Int64? = nil,
        reclaimable: Int64? = nil,
        fileCount: Int = 0,
        modified: Date? = nil,
        note: String? = nil,
        preselected: Bool,
        partiallyUnreadable: Bool = false,
        blockedCount: Int = 0
    ) {
        self.id = ruleID + "|" + (urls.first?.path ?? title)
        self.ruleID = ruleID
        self.title = title
        self.detail = detail
        self.urls = urls
        self.size = size
        self.exclusiveSize = exclusiveSize ?? size
        self.reclaimable = reclaimable ?? size
        self.fileCount = fileCount
        self.modified = modified
        self.note = note
        self.preselected = preselected
        self.partiallyUnreadable = partiallyUnreadable
        self.blockedCount = blockedCount
    }
}

public struct RuleResult: Identifiable, Sendable {
    public let rule: Rule
    public var items: [ScanItem]
    public var notes: [String]
    /// 没有权限读取（通常需要“完全磁盘访问”）
    public var accessDenied: Bool

    public var id: String { rule.id }
    /// 占用合计
    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    /// 预计释放合计
    public var reclaimableTotal: Int64 { items.reduce(0) { $0 + $1.reclaimable } }

    public init(rule: Rule, items: [ScanItem], notes: [String] = [], accessDenied: Bool = false) {
        self.rule = rule
        self.items = items
        self.notes = notes
        self.accessDenied = accessDenied
    }
}

public struct ScanProgress: Sendable {
    public var phase: String
    public var completed: Int
    public var total: Int

    public var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    public init(phase: String, completed: Int, total: Int) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }
}
